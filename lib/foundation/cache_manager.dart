import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';
import 'log.dart';

enum CacheLookupState { hit, missing, expired, fileMissing }

enum CacheClass { thumbnail, readerPage, derived }

final class CacheAliasTarget {
  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;

  const CacheAliasTarget(this.imageKey, this.sourceKey, this.cid, this.eid);
}

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;
  late final Future<void> _startupScan;
  final Map<String, CacheAliasTarget> _aliases = {};
  final Map<String, Future<void>> _mutations = {};

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  static const _defaultDuration = 7 * 24 * 60 * 60 * 1000;
  static const _touchInterval = 30 * 60 * 1000;
  static const _lowWatermark = 0.9;

  static Future<int> _scanDir(Map<String, int> managedPaths, String dir) async {
    final stopwatch = Stopwatch()..start();
    var res = await Isolate.run(() async {
      int totalSize = 0;
      List<String> unmanagedFiles = [];
      List<(String, int)> sizeChanges = [];
      await for (var file in Directory(dir).list(recursive: true)) {
        if (file is File) {
          var size = await file.length();
          var segments = file.uri.pathSegments;
          var name = segments.last;
          var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
          final path = '$dir/$name';
          if (!managedPaths.containsKey(path)) {
            unmanagedFiles.add(file.path);
          } else {
            totalSize += size;
            if (managedPaths[path] != size) sizeChanges.add((path, size));
          }
        }
      }
      return {
        'totalSize': totalSize,
        'unmanagedFiles': unmanagedFiles,
        'sizeChanges': sizeChanges,
      };
    });
    Log.info(
      'Cache.Scan',
      'filesystem ${stopwatch.elapsedMilliseconds}ms '
          'unmanaged=${(res['unmanagedFiles'] as List).length}',
    );
    var totalSize = res['totalSize'] as int;
    final sizeChanges = res['sizeChanges'] as List<(String, int)>;
    if (sizeChanges.isNotEmpty) {
      CacheManager()._db.execute('BEGIN;');
      try {
        for (final change in sizeChanges) {
          final split = change.$1.indexOf('/');
          CacheManager()._db.execute(
            'UPDATE cache SET size = ? WHERE dir = ? AND name = ?;',
            [
              change.$2,
              change.$1.substring(0, split),
              change.$1.substring(split + 1),
            ],
          );
        }
        CacheManager()._db.execute('COMMIT;');
      } catch (_) {
        CacheManager()._db.execute('ROLLBACK;');
        rethrow;
      }
    }
    var processed = 0;
    for (var filePath in res['unmanagedFiles'] as List<String>) {
      if (++processed % 32 == 0) await Future<void>.delayed(Duration.zero);
      var file = File(filePath);
      if (!await file.exists()) continue;
      var segments = file.uri.pathSegments;
      var name = segments.last;
      var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
      var owner = CacheManager()._db.select(
        'SELECT key, dir, size FROM cache WHERE name = ?;',
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
            'UPDATE cache SET dir = ?, size = ? WHERE key = ?;',
            [dir, await file.length(), owner.first[0]],
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
      Log.info('Cache.Trace', 'delete: reason=startup-unmanaged path=${file.path}');
      await file.delete();
    }
    Log.info(
      'Cache.Scan',
      'complete ${stopwatch.elapsedMilliseconds}ms unmanaged=$processed bytes=$totalSize',
    );
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
    final columns = _db
        .select('PRAGMA table_info(cache);')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains('size')) {
      _db.execute('ALTER TABLE cache ADD COLUMN size INTEGER NOT NULL DEFAULT 0;');
    }
    if (!columns.contains('last_access')) {
      _db.execute('ALTER TABLE cache ADD COLUMN last_access INTEGER NOT NULL DEFAULT 0;');
    }
    if (!columns.contains('created_at')) {
      _db.execute('ALTER TABLE cache ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;');
    }
    if (!columns.contains('ttl')) {
      _db.execute(
        'ALTER TABLE cache ADD COLUMN ttl INTEGER NOT NULL DEFAULT $_defaultDuration;',
      );
    }
    _db.execute('''
      UPDATE cache SET
        type = COALESCE(type, '${CacheClass.readerPage.name}'),
        last_access = CASE WHEN last_access = 0 THEN expires - ttl ELSE last_access END,
        created_at = CASE WHEN created_at = 0 THEN expires - ttl ELSE created_at END
      WHERE type IS NULL OR last_access = 0 OR created_at = 0;
      CREATE INDEX IF NOT EXISTS cache_expires_idx ON cache(expires);
      CREATE INDEX IF NOT EXISTS cache_type_access_idx ON cache(type, last_access);
      CREATE INDEX IF NOT EXISTS cache_name_idx ON cache(name);
    ''');
    final managedPaths = _db
        .select('SELECT dir, name, size FROM cache;')
        .fold(<String, int>{}, (paths, row) {
          paths['${row[0]}/${row[1]}'] = row[2] as int;
          return paths;
        });
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
    checkCacheIfRequired();
  }

  Future<T> _withKeyMutation<T>(String key, Future<T> Function() action) {
    final previous = _mutations[key] ?? Future<void>.value();
    final release = Completer<void>();
    final queued = release.future;
    _mutations[key] = queued;
    return previous.then((_) => action()).whenComplete(() {
      release.complete();
      if (identical(_mutations[key], queued)) _mutations.remove(key);
    });
  }

  (String, File?, int) _replacementTarget(String key) {
    final rows = _db.select(
      'SELECT dir, name FROM cache WHERE key = ?;',
      [key],
    );
    final oldFile = rows.isEmpty
        ? null
        : File('$cachePath/${rows.first[0]}/${rows.first[1]}');
    final oldDir = rows.isEmpty ? null : rows.first[0] as String;
    do {
      dir = (dir + 1) % 100;
    } while (dir.toString() == oldDir);
    return (md5.convert(key.codeUnits).toString(), oldFile, dir);
  }

  void _replaceRow(
    String key,
    int targetDir,
    String name,
    int size,
    int duration,
    CacheClass cacheClass,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('BEGIN;');
    try {
      _db.execute('''
        INSERT OR REPLACE INTO cache
          (key, dir, name, expires, type, size, last_access, created_at, ttl)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''', [
        key,
        targetDir.toString(),
        name,
        now + duration,
        cacheClass.name,
        size,
        now,
        now,
        duration,
      ]);
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  Future<int> _removeReplacedFile(File? file, File replacement) async {
    if (file == null || file.path == replacement.path || !await file.exists()) {
      return 0;
    }
    final size = await file.length();
    try {
      await file.delete();
      return size;
    } on FileSystemException catch (e) {
      Log.warning('Cache.Trace', 'old file retained: path=${file.path} error=$e');
      return 0;
    }
  }

  /// Write cache to disk without discarding the previous valid entry first.
  Future<void> writeCache(
    String key,
    List<int> data, {
    int duration = _defaultDuration,
    CacheClass cacheClass = CacheClass.readerPage,
  }) async {
    await _startupScan;
    return _withKeyMutation(key, () async {
        final (name, oldFile, targetDir) = _replacementTarget(key);
        final target = File('$cachePath/$targetDir/$name');
        final temp = File('${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
        await temp.parent.create(recursive: true);
        try {
          await temp.writeAsBytes(data);
          final replacement = await temp.rename(target.path);
          try {
            _replaceRow(key, targetDir, name, data.length, duration, cacheClass);
          } catch (_) {
            await replacement.delete();
            rethrow;
          }
          final removed = await _removeReplacedFile(oldFile, replacement);
          _aliases.remove(key);
          if (_currentSize != null) {
            _currentSize = _currentSize! + data.length - removed;
          }
          checkCacheIfRequired();
        } catch (_) {
          if (await temp.exists()) await temp.delete();
          rethrow;
        }
      });
  }

  Future<File> promoteFile(
    String key,
    File source, {
    int duration = _defaultDuration,
    CacheClass cacheClass = CacheClass.readerPage,
  }) async {
    await _startupScan;
    return _withKeyMutation(key, () async {
        final (name, oldFile, targetDir) = _replacementTarget(key);
        final target = File('$cachePath/$targetDir/$name');
        await target.parent.create(recursive: true);
        final size = await source.length();
        final promoted = await source.rename(target.path);
        try {
          _replaceRow(key, targetDir, name, size, duration, cacheClass);
        } catch (_) {
          await promoted.rename(source.path);
          rethrow;
        }
        final removed = await _removeReplacedFile(oldFile, promoted);
        _aliases.remove(key);
        Log.info('Cache.Trace', 'promote: key=$key path=${promoted.path} size=$size');
        if (_currentSize != null) _currentSize = _currentSize! + size - removed;
        checkCacheIfRequired();
        return promoted;
      });
  }

  /// Find cache by key.
  /// If cache is expired, it will be deleted and return null.
  /// If cache is not found, it will return null.
  /// If cache is found, it will return the file, and update the expires time.
  Future<File?> findCache(
    String key, {
    CacheClass? cacheClass,
    void Function(CacheLookupState state)? onLookup,
  }) async {
    var res = _db.select('''
      SELECT dir, name, expires, type, size, last_access, ttl FROM cache
      WHERE key = ?;
    ''', [key]);
    if (res.isEmpty) {
      onLookup?.call(CacheLookupState.missing);
      return null;
    }
    var row = res.first;
    var dir = row[0] as String;
    var name = row[1] as String;
    var expires = row[2] as int;
    var file = File('$cachePath/$dir/$name');
    var now = DateTime.now().millisecondsSinceEpoch;
    if (expires < now) {
      final deleted = await _deleteSelectedCacheFile(
        key,
        dir,
        name,
        reason: 'expired-lookup',
      );
      if (!deleted.$1) {
        return findCache(key, cacheClass: cacheClass, onLookup: onLookup);
      }
      onLookup?.call(CacheLookupState.expired);
      return null;
    }
    if (await file.exists()) {
      final type = row[3] as String?;
      final lastAccess = row[5] as int;
      if (now - lastAccess >= _touchInterval ||
          cacheClass != null && type != cacheClass.name) {
        _db.execute('''
          UPDATE cache SET expires = ? + ttl, last_access = ?,
            type = COALESCE(?, type)
          WHERE key = ?;
        ''', [now, now, cacheClass?.name, key]);
      }
      onLookup?.call(CacheLookupState.hit);
      return file;
    } else {
      final repaired = await _findAndRepairCacheFile(key, name, dir);
      if (repaired != null) {
        _db.execute('''
          UPDATE cache SET expires = ? + ttl, last_access = ?,
            type = COALESCE(?, type) WHERE key = ?;
        ''', [now, now, cacheClass?.name, key]);
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
      _db.execute(
        'UPDATE cache SET dir = ?, size = ? WHERE key = ?;',
        [dir, await file.length(), key],
      );
      Log.warning(
        'Cache.Trace',
        'repair-on-read: key=$key from=$missingDir to=$dir path=${file.path}',
      );
      return file;
    }
    return null;
  }

  bool rekey(String oldKey, String newKey) {
    if (oldKey == newKey) return true;
    _aliases.remove(newKey);
    final oldRows = _db.select('SELECT key FROM cache WHERE key = ?;', [oldKey]);
    if (oldRows.isEmpty) return false;
    final newRows = _db.select('SELECT key FROM cache WHERE key = ?;', [newKey]);
    if (newRows.isNotEmpty) return true;
    _db.execute('UPDATE cache SET key = ? WHERE key = ?;', [newKey, oldKey]);
    return true;
  }

  void aliasImage({
    required String imageKey,
    required String? sourceKey,
    required String cid,
    required String eid,
    required CacheAliasTarget target,
  }) {
    _aliases['$imageKey@$sourceKey@$cid@$eid'] = target;
    if (_aliases.length > 8192) _aliases.remove(_aliases.keys.first);
  }

  CacheAliasTarget? resolveImageAlias(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    var key = '$imageKey@$sourceKey@$cid@$eid';
    var target = _aliases[key];
    if (target == null) return null;
    final visited = <String>{key};
    while (true) {
      key = '${target!.imageKey}@${target.sourceKey}@${target.cid}@${target.eid}';
      if (!visited.add(key)) throw StateError('Circular image cache alias: $key');
      final next = _aliases[key];
      if (next == null) return target;
      target = next;
    }
  }

  Future<int> countExisting(Iterable<String> keys) async {
    return (await findExistingKeys(keys)).length;
  }

  Future<Set<String>> findExistingKeys(
    Iterable<String> keys, {
    bool touch = false,
  }) async {
    final values = keys.toSet().toList();
    final existing = <String>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var start = 0; start < values.length; start += 400) {
      final chunk = values.sublist(start, math.min(start + 400, values.length));
      final rows = _db.select(
        'SELECT key, dir, name, expires FROM cache WHERE key IN '
        '(${List.filled(chunk.length, '?').join(',')});',
        chunk,
      );
      for (final row in rows) {
        if ((row[3] as int) < now) continue;
        final file = File('$cachePath/${row[1]}/${row[2]}');
        if (await file.exists() ||
            await _findAndRepairCacheFile(
                  row[0] as String,
                  row[2] as String,
                  row[1] as String,
                ) !=
                null) {
          existing.add(row[0] as String);
        }
      }
    }
    if (touch) {
      final values = existing.toList();
      for (var start = 0; start < values.length; start += 400) {
        final chunk = values.sublist(start, math.min(start + 400, values.length));
        _db.execute(
          'UPDATE cache SET expires = ? + ttl, last_access = ? WHERE key IN '
          '(${List.filled(chunk.length, '?').join(',')});',
          [now, now, ...chunk],
        );
      }
    }
    return existing;
  }

  Future<int> countComicEntries(String sourceKey, String comicId) async {
    String escape(String value) => value
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final rows = _db.select(
      "SELECT key, dir, name, expires FROM cache "
      "WHERE key LIKE ? ESCAPE '\\';",
      ['%@${escape(sourceKey)}@${escape(comicId)}@%'],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    var count = 0;
    for (final row in rows) {
      if ((row[3] as int) < now) continue;
      final file = File('$cachePath/${row[1]}/${row[2]}');
      if (await file.exists() ||
          await _findAndRepairCacheFile(
                row[0] as String,
                row[2] as String,
                row[1] as String,
              ) !=
              null) {
        count++;
      }
    }
    return count;
  }

  bool _isChecking = false;

  Future<(bool, int)> _deleteSelectedCacheFile(
    String key,
    String selectedDir,
    String selectedName, {
    required String reason,
  }) =>
      _withKeyMutation(key, () async {
        final rows = _db.select(
          'SELECT dir, name FROM cache WHERE key = ?;',
          [key],
        );
        if (rows.isEmpty ||
            rows.first[0] != selectedDir ||
            rows.first[1] != selectedName) {
          return (false, 0);
        }
        final file = File('$cachePath/$selectedDir/$selectedName');
        var size = 0;
        final exists = await file.exists();
        if (exists) {
          size = await file.length();
          Log.info(
            'Cache.Trace',
            'delete: reason=$reason key=$key bytes=$size path=${file.path}',
          );
          await file.delete();
        }
        _db.execute(
          'DELETE FROM cache WHERE key = ? AND dir = ? AND name = ?;',
          [key, selectedDir, selectedName],
        );
        if (_currentSize != null) {
          _currentSize = math.max(0, _currentSize! - size);
        }
        return (true, size);
      });

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
    if (_isChecking) return;
    _isChecking = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final expired = _db.select('''
        SELECT key, dir, name FROM cache WHERE expires < ?;
      ''', [now]);
      for (final row in expired) {
        final key = row[0] as String;
        await _deleteSelectedCacheFile(
          key,
          row[1] as String,
          row[2] as String,
          reason: 'expired',
        );
      }

      if (_currentSize! <= _limitSize) return;
      final targetSize = (_limitSize * _lowWatermark).floor();
      final thumbnailFloor = math.min(256 * 1024 * 1024, _limitSize ~/ 10);
      var thumbnailBytes = _db.select('''
        SELECT COALESCE(SUM(size), 0) FROM cache WHERE type = ?;
      ''', [CacheClass.thumbnail.name]).first[0] as int;

      while (_currentSize! > targetSize) {
        final protectThumbnails = thumbnailBytes <= thumbnailFloor;
        var rows = _evictionCandidates(excludeThumbnails: protectThumbnails);
        if (rows.isEmpty && protectThumbnails) {
          rows = _evictionCandidates(excludeThumbnails: false);
        }
        if (rows.isEmpty) {
          Log.warning('Cache.Trace', 'delete: reason=limit-unmanaged-clear-all');
          final cacheDir = Directory(cachePath);
          if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
          await cacheDir.create(recursive: true);
          _currentSize = 0;
          break;
        }
        for (final row in rows) {
          final key = row[0] as String;
          final type = row[3] as String;
          final deleted = await _deleteSelectedCacheFile(
            key,
            row[1] as String,
            row[2] as String,
            reason: 'limit type=$type',
          );
          if (deleted.$1 && type == CacheClass.thumbnail.name) {
            thumbnailBytes = math.max(0, thumbnailBytes - deleted.$2);
          }
          if (_currentSize! <= targetSize) break;
        }
      }
    } finally {
      _isChecking = false;
    }
  }

  ResultSet _evictionCandidates({required bool excludeThumbnails}) => _db.select('''
    SELECT key, dir, name, type, size FROM cache
    ${excludeThumbnails ? 'WHERE type != ?' : ''}
    ORDER BY (last_access / 3600000) ASC,
      CASE type WHEN '${CacheClass.derived.name}' THEN 0 ELSE 1 END,
      size DESC, last_access ASC
    LIMIT 32;
  ''', excludeThumbnails ? [CacheClass.thumbnail.name] : const []);

  /// Delete cache by key.
  Future<void> delete(String key, {String reason = 'explicit'}) async {
    await _startupScan;
    final rows = _db.select(
      'SELECT dir, name FROM cache WHERE key = ?;',
      [key],
    );
    if (rows.isEmpty) return;
    await _deleteSelectedCacheFile(
      key,
      rows.first[0] as String,
      rows.first[1] as String,
      reason: reason,
    );
  }

  /// Delete all cache.
  Future<void> clear() async {
    await _startupScan;
    Log.info('Cache.Trace', 'delete: reason=clear-all');
    await Directory(cachePath).delete(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }
}
