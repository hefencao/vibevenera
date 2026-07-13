import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';
import 'log.dart';

enum CacheLookupState { hit, missing, expired, fileMissing }

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;
  late final Future<void> _startupScan;

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  static Future<int> _scanDir(Set<String> managedPaths, String dir) async {
    var res = await Isolate.run(() async {
      int totalSize = 0;
      List<String> unmanagedFiles = [];
      await for (var file in Directory(dir).list(recursive: true)) {
        if (file is File) {
          var size = await file.length();
          var segments = file.uri.pathSegments;
          var name = segments.last;
          var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
          if (!managedPaths.contains('$dir/$name')) {
            unmanagedFiles.add(file.path);
          } else {
            totalSize += size;
          }
        }
      }
      return {
        'totalSize': totalSize,
        'unmanagedFiles': unmanagedFiles,
      };
    });
    var totalSize = res['totalSize'] as int;
    var processed = 0;
    for (var filePath in res['unmanagedFiles'] as List<String>) {
      if (++processed % 32 == 0) await Future<void>.delayed(Duration.zero);
      var file = File(filePath);
      if (!await file.exists()) continue;
      var segments = file.uri.pathSegments;
      var name = segments.last;
      var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
      var owner = CacheManager()._db.select(
        'SELECT key, dir FROM cache WHERE name = ?;',
        [name],
      );
      if (owner.isNotEmpty) {
        final exactOwner = owner.where((row) => row[1] == dir).firstOrNull;
        if (exactOwner != null) {
          totalSize += await file.length();
          continue;
        }
        var ownerFileExists = false;
        for (final row in owner) {
          if (await File('$cachePath/${row[1]}/$name').exists()) {
            ownerFileExists = true;
            break;
          }
        }
        if (!ownerFileExists && owner.length == 1) {
          final ownerDir = owner.first[1] as String;
          final ownerFile = File('$cachePath/$ownerDir/$name');
          CacheManager()._db.execute(
            'UPDATE cache SET dir = ? WHERE key = ?;',
            [dir, owner.first[0]],
          );
          totalSize += await file.length();
          Log.warning(
            'Cache.Trace',
            'repair: key=${owner.first[0]} from=${ownerFile.path} to=${file.path}',
          );
          continue;
        }
        if (!ownerFileExists) {
          totalSize += await file.length();
          Log.warning(
            'Cache.Trace',
            'retain: reason=ambiguous-missing-owner path=${file.path} owners=${owner.length}',
          );
          continue;
        }
      }
      Log.warning('Cache.Trace', 'delete: reason=startup-unmanaged path=${file.path}');
      await file.delete();
    }
    return totalSize;
  }

  CacheManager._create() {
    Directory(cachePath).createSync(recursive: true);
    _db = sqlite3.open('${App.dataPath}/cache.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    final managedPaths = _db
        .select('SELECT dir, name FROM cache;')
        .map((row) => '${row[0]}/${row[1]}')
        .toSet();
    _startupScan = _scanDir(managedPaths, cachePath).then((value) async {
      _currentSize = value;
      await checkCache();
    });
  }

  /// Get the singleton instance of CacheManager.
  factory CacheManager() => instance ??= CacheManager._create();

  /// set cache size limit in MB
  void setLimitSize(int size) {
    _limitSize = size * 1024 * 1024;
  }

  /// Write cache to disk.
  Future<void> writeCache(String key, List<int> data,
      [int duration = 7 * 24 * 60 * 60 * 1000]) async {
    await _startupScan;
    await delete(key, reason: 'replace-before-write');
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(key.codeUnits).toString();
    var file = File('$cachePath/$dir/$name');
    await file.create(recursive: true);
    await file.writeAsBytes(data);
    var expires = DateTime.now().millisecondsSinceEpoch + duration;
    _db.execute('''
      INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''', [key, dir.toString(), name, expires]);
    if (_currentSize != null) {
      _currentSize = _currentSize! + data.length;
    }
    checkCacheIfRequired();
  }

  Future<File> promoteFile(String key, File source,
      [int duration = 7 * 24 * 60 * 60 * 1000]) async {
    await _startupScan;
    await delete(key, reason: 'replace-before-promote');
    dir = (dir + 1) % 100;
    final name = md5.convert(key.codeUnits).toString();
    final target = File('$cachePath/$dir/$name');
    await target.parent.create(recursive: true);
    final size = await source.length();
    final promoted = await source.rename(target.path);
    final expires = DateTime.now().millisecondsSinceEpoch + duration;
    _db.execute('''
      INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''', [key, dir.toString(), name, expires]);
    Log.warning('Cache.Trace', 'promote: key=$key path=${promoted.path} size=$size');
    if (_currentSize != null) _currentSize = _currentSize! + size;
    checkCacheIfRequired();
    return promoted;
  }

  /// Find cache by key.
  /// If cache is expired, it will be deleted and return null.
  /// If cache is not found, it will return null.
  /// If cache is found, it will return the file, and update the expires time.
  Future<File?> findCache(
    String key, {
    void Function(CacheLookupState state)? onLookup,
  }) async {
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      onLookup?.call(CacheLookupState.missing);
      return null;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var expires = row[3] as int;
    var file = File('$cachePath/$dir/$name');
    var now = DateTime.now().millisecondsSinceEpoch;
    if (expires < now) {
      // expired
      _db.execute('''
        DELETE FROM cache
        WHERE key = ?
      ''', [key]);
      if (await file.exists()) {
        await file.delete();
      }
      onLookup?.call(CacheLookupState.expired);
      return null;
    }
    if (await file.exists()) {
      // update time
      var expires = now + 7 * 24 * 60 * 60 * 1000;
      _db.execute('''
        UPDATE cache
        SET expires = ?
        WHERE key = ?
      ''', [expires, key]);
      onLookup?.call(CacheLookupState.hit);
      return file;
    } else {
      final repaired = await _findAndRepairCacheFile(key, name, dir);
      if (repaired != null) {
        _db.execute('''
          UPDATE cache SET expires = ? WHERE key = ?
        ''', [now + 7 * 24 * 60 * 60 * 1000, key]);
        onLookup?.call(CacheLookupState.hit);
        return repaired;
      }
      _db.execute('DELETE FROM cache WHERE key = ?;', [key]);
      onLookup?.call(CacheLookupState.fileMissing);
    }
    return null;
  }

  Future<File?> _findAndRepairCacheFile(
    String key,
    String name,
    String missingDir,
  ) async {
    for (var i = 0; i < 100; i++) {
      final dir = i.toString();
      if (dir == missingDir) continue;
      final file = File('$cachePath/$dir/$name');
      if (!await file.exists()) continue;
      _db.execute('UPDATE cache SET dir = ? WHERE key = ?;', [dir, key]);
      Log.warning(
        'Cache.Trace',
        'repair-on-read: key=$key from=$missingDir to=$dir path=${file.path}',
      );
      return file;
    }
    return null;
  }

  bool _isChecking = false;

  /// Check cache size and delete expired cache.
  /// Only check cache if current size is greater than limit size.
  void checkCacheIfRequired() {
    if (_currentSize != null && _currentSize! > _limitSize) {
      checkCache();
    }
  }

  /// Check cache size and delete expired cache.
  /// If current size is greater than limit size,
  /// delete cache until current size is less than limit size.
  Future<void> checkCache() async {
    if (_isChecking) {
      return;
    }
    _isChecking = true;
    var res = _db.select('''
      SELECT * FROM cache
      WHERE expires < ?
    ''', [DateTime.now().millisecondsSinceEpoch]);
    for (var row in res) {
      var key = row[0] as String;
      var dir = row[1] as String;
      var name = row[2] as String;
      var file = File('$cachePath/$dir/$name');
      if (await file.exists()) {
        var size = await file.length();
        _currentSize = _currentSize! - size;
        Log.warning('Cache.Trace', 'delete: reason=expired key=$key path=${file.path}');
        await file.delete();
      }
    }
    if (res.isNotEmpty) {
      _db.execute('''
      DELETE FROM cache
      WHERE expires < ?
    ''', [DateTime.now().millisecondsSinceEpoch]);
    }

    while (_currentSize != null && _currentSize! > _limitSize) {
      var res = _db.select('''
        SELECT * FROM cache
        ORDER BY expires ASC
        limit 10
      ''');
      if (res.isEmpty) {
        // There are many files unmanaged by the cache manager.
        // Clear all cache.
        Log.warning('Cache.Trace', 'delete: reason=limit-unmanaged-clear-all');
        await Directory(cachePath).delete(recursive: true);
        Directory(cachePath).createSync(recursive: true);
        break;
      }
      for (var row in res) {
        var key = row[0] as String;
        var dir = row[1] as String;
        var name = row[2] as String;
        var file = File('$cachePath/$dir/$name');
        if (await file.exists()) {
          var size = await file.length();
          Log.warning('Cache.Trace', 'delete: reason=limit key=$key path=${file.path}');
          await file.delete();
          _db.execute('''
            DELETE FROM cache
            WHERE key = ?
          ''', [key]);
          _currentSize = _currentSize! - size;
          if (_currentSize! <= _limitSize) {
            break;
          }
        } else {
          _db.execute('''
            DELETE FROM cache
            WHERE key = ?
          ''', [key]);
        }
      }
    }
    _isChecking = false;
  }

  /// Delete cache by key.
  Future<void> delete(String key, {String reason = 'explicit'}) async {
    await _startupScan;
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var file = File('$cachePath/$dir/$name');
    var fileSize = 0;
    final exists = await file.exists();
    Log.warning(
      'Cache.Trace',
      'delete: reason=$reason key=$key path=${file.path} exists=$exists',
    );
    if (exists) {
      fileSize = await file.length();
      await file.delete();
    }
    _db.execute('''
      DELETE FROM cache
      WHERE key = ?
    ''', [key]);
    if (_currentSize != null) {
      _currentSize = _currentSize! - fileSize;
    }
  }

  /// Delete all cache.
  Future<void> clear() async {
    await _startupScan;
    Log.warning('Cache.Trace', 'delete: reason=clear-all');
    await Directory(cachePath).delete(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }
}
