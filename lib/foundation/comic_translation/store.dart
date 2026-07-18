import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

final class ComicTranslationStore {
  ComicTranslationStore._();

  static final instance = ComicTranslationStore._();

  SendPort? _worker;
  Future<void>? _initializing;
  Future<void>? _closing;

  Future<void> init(String dataPath) async {
    final closing = _closing;
    if (closing != null) await closing;
    if (_worker != null) return;
    await (_initializing ??= _start(dataPath).whenComplete(() {
      _initializing = null;
    }));
  }

  Future<void> _start(String dataPath) async {
    final ready = ReceivePort();
    final errors = ReceivePort();
    try {
      await Isolate.spawn(
        _storeWorker,
        ['$dataPath/comic_translation.db', ready.sendPort],
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
      _worker = await Future.any([
        ready.first.then((value) => value as SendPort),
        errors.first.then<SendPort>((value) {
          final error = value as List;
          throw StateError('${error[0]}\n${error[1]}');
        }),
      ]);
    } finally {
      ready.close();
      errors.close();
    }
  }

  Future<dynamic> _call(String operation, List<Object?> arguments) async {
    final worker = _worker;
    if (worker == null) {
      throw StateError('Comic translation store is not initialized');
    }
    if (_closing != null && operation != 'close') {
      throw StateError('Comic translation store is closing');
    }
    final reply = ReceivePort();
    try {
      worker.send([operation, arguments, reply.sendPort]);
      final response = await reply.first as List;
      if (response[0] == false) {
        throw StateError('${response[1]}\n${response[2]}');
      }
      return response[1];
    } finally {
      reply.close();
    }
  }

  Future<String?> findContentDigest({
    required ComicTranslationPageIdentity identity,
    required int fileSize,
    required int fileModified,
  }) async => await _call('findContentDigest', [
    identity.key,
    fileSize,
    fileModified,
  ]) as String?;

  Future<void> storeContentDigest({
    required ComicTranslationPageIdentity identity,
    required int fileSize,
    required int fileModified,
    required String contentDigest,
  }) => _call('storeContentDigest', [
    identity.key,
    identity.sourceKey,
    identity.comicId,
    identity.chapterId,
    identity.imageKey,
    identity.pageIndex,
    identity.mediaKind.name,
    fileSize,
    fileModified,
    contentDigest,
  ]);

  Future<ComicOcrArtifact?> findOcr({
    required String contentDigest,
    required String engineId,
    required String modelVersion,
    required String sourceLanguage,
  }) async {
    final payload = await _call('findOcr', [
      _ocrKey(contentDigest, engineId, modelVersion, sourceLanguage),
    ]) as String?;
    return payload == null
        ? null
        : ComicOcrArtifact.fromJson(
            Map<String, dynamic>.from(jsonDecode(payload) as Map),
          );
  }

  Future<void> storeOcr(ComicOcrArtifact artifact) => _call('storeOcr', [
    _ocrKey(
      artifact.contentDigest,
      artifact.engineId,
      artifact.modelVersion,
      artifact.sourceLanguage,
    ),
    artifact.contentDigest,
    artifact.engineId,
    artifact.modelVersion,
    artifact.sourceLanguage,
    jsonEncode(artifact.toJson()),
  ]);

  Future<ComicTranslationArtifact?> findTranslation({
    required String ocrDigest,
    required String engineId,
    required String modelVersion,
    required String targetLanguage,
    required String contextDigest,
  }) async {
    final payload = await _call('findTranslation', [
      _translationKey(
        ocrDigest,
        engineId,
        modelVersion,
        targetLanguage,
        contextDigest,
      ),
      ocrDigest,
      engineId,
      modelVersion,
      targetLanguage,
    ]) as String?;
    return payload == null
        ? null
        : ComicTranslationArtifact.fromJson(
            Map<String, dynamic>.from(jsonDecode(payload) as Map),
          );
  }

  Future<void> storeTranslation(ComicTranslationArtifact artifact) =>
      _call('storeTranslation', [
        _translationKey(
          artifact.ocrDigest,
          artifact.engineId,
          artifact.modelVersion,
          artifact.targetLanguage,
          artifact.contextDigest,
        ),
        artifact.contentDigest,
        artifact.ocrDigest,
        artifact.engineId,
        artifact.modelVersion,
        artifact.targetLanguage,
        artifact.contextDigest,
        jsonEncode(artifact.toJson()),
      ]);

  Future<void> clear() => _call('clear', const []);

  Future<void> close() async {
    final initializing = _initializing;
    if (initializing != null) await initializing;
    if (_worker == null) return;
    await (_closing ??= _close().whenComplete(() {
      _closing = null;
    }));
  }

  Future<void> _close() async {
    try {
      await _call('close', const []);
    } finally {
      _worker = null;
    }
  }

  static String _ocrKey(
    String contentDigest,
    String engineId,
    String modelVersion,
    String sourceLanguage,
  ) => jsonEncode([
    contentDigest,
    engineId,
    modelVersion,
    sourceLanguage,
  ]);

  static String _translationKey(
    String ocrDigest,
    String engineId,
    String modelVersion,
    String targetLanguage,
    String contextDigest,
  ) => jsonEncode([
    ocrDigest,
    engineId,
    modelVersion,
    targetLanguage,
    contextDigest,
  ]);
}

void _storeWorker(List<Object> init) async {
  final path = init[0] as String;
  final ready = init[1] as SendPort;
  final db = sqlite3.open(path);
  const schemaVersion = 1;
  final version = db.select('PRAGMA user_version;').first[0] as int;
  if (version != schemaVersion) {
    db.execute('''
      DROP TABLE IF EXISTS page_content;
      DROP TABLE IF EXISTS ocr_artifacts;
      DROP TABLE IF EXISTS translation_artifacts;
      PRAGMA user_version = $schemaVersion;
    ''');
  }
  db.execute('''
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA busy_timeout = 5000;
    CREATE TABLE IF NOT EXISTS page_content (
      page_key TEXT PRIMARY KEY NOT NULL,
      source_key TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      image_key TEXT NOT NULL,
      page_index INTEGER NOT NULL,
      media_kind TEXT NOT NULL,
      file_size INTEGER NOT NULL,
      file_modified INTEGER NOT NULL,
      content_digest TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS page_content_digest_idx
      ON page_content(content_digest);
    CREATE TABLE IF NOT EXISTS ocr_artifacts (
      cache_key TEXT PRIMARY KEY NOT NULL,
      content_digest TEXT NOT NULL,
      engine_id TEXT NOT NULL,
      model_version TEXT NOT NULL,
      source_language TEXT NOT NULL,
      payload TEXT NOT NULL,
      updated_at INTEGER NOT NULL,
      accessed_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS translation_artifacts (
      cache_key TEXT PRIMARY KEY NOT NULL,
      content_digest TEXT NOT NULL,
      ocr_digest TEXT NOT NULL,
      engine_id TEXT NOT NULL,
      model_version TEXT NOT NULL,
      target_language TEXT NOT NULL,
      context_digest TEXT NOT NULL,
      payload TEXT NOT NULL,
      updated_at INTEGER NOT NULL,
      accessed_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS translation_artifacts_compatible_idx
      ON translation_artifacts(
        ocr_digest, engine_id, model_version, target_language, accessed_at
      );
  ''');
  final commands = ReceivePort();
  ready.send(commands.sendPort);
  await for (final message in commands) {
    final request = message as List;
    final operation = request[0] as String;
    final arguments = request[1] as List;
    final reply = request[2] as SendPort;
    try {
      if (operation == 'close') {
        db.dispose();
        reply.send([true, null]);
        commands.close();
        continue;
      }
      reply.send([true, _executeStoreOperation(db, operation, arguments)]);
    } catch (error, stackTrace) {
      reply.send([false, error.toString(), stackTrace.toString()]);
    }
  }
}

Object? _executeStoreOperation(
  Database db,
  String operation,
  List arguments,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  switch (operation) {
    case 'findContentDigest':
      final rows = db.select('''
        SELECT content_digest FROM page_content
        WHERE page_key = ? AND file_size = ? AND file_modified = ?;
      ''', arguments);
      return rows.isEmpty ? null : rows.first[0] as String;
    case 'storeContentDigest':
      db.execute('''
        INSERT OR REPLACE INTO page_content
          (page_key, source_key, comic_id, chapter_id, image_key, page_index,
           media_kind, file_size, file_modified, content_digest, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''', [...arguments, now]);
      db.execute('''
        DELETE FROM page_content WHERE rowid IN (
          SELECT rowid FROM page_content ORDER BY updated_at DESC
          LIMIT -1 OFFSET 8192
        );
      ''');
      return null;
    case 'findOcr':
      final rows = db.select(
        'SELECT payload FROM ocr_artifacts WHERE cache_key = ?;',
        arguments,
      );
      if (rows.isEmpty) return null;
      db.execute(
        'UPDATE ocr_artifacts SET accessed_at = ? WHERE cache_key = ?;',
        [now, arguments[0]],
      );
      return rows.first[0] as String;
    case 'storeOcr':
      db.execute('''
        INSERT OR REPLACE INTO ocr_artifacts
          (cache_key, content_digest, engine_id, model_version,
           source_language, payload, updated_at, accessed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
      ''', [...arguments, now, now]);
      db.execute('''
        DELETE FROM ocr_artifacts WHERE rowid IN (
          SELECT rowid FROM ocr_artifacts ORDER BY accessed_at DESC
          LIMIT -1 OFFSET 2048
        );
      ''');
      return null;
    case 'findTranslation':
      var rows = db.select(
        'SELECT payload, cache_key FROM translation_artifacts '
        'WHERE cache_key = ?;',
        [arguments[0]],
      );
      if (rows.isEmpty) {
        rows = db.select('''
          SELECT payload, cache_key FROM translation_artifacts
          WHERE ocr_digest = ? AND engine_id = ? AND model_version = ?
            AND target_language = ?
          ORDER BY accessed_at DESC, updated_at DESC LIMIT 1;
        ''', arguments.sublist(1));
      }
      if (rows.isEmpty) return null;
      db.execute(
        'UPDATE translation_artifacts SET accessed_at = ? WHERE cache_key = ?;',
        [now, rows.first[1]],
      );
      return rows.first[0] as String;
    case 'storeTranslation':
      db.execute('''
        INSERT OR REPLACE INTO translation_artifacts
          (cache_key, content_digest, ocr_digest, engine_id, model_version,
           target_language, context_digest, payload, updated_at, accessed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''', [...arguments, now, now]);
      db.execute('''
        DELETE FROM translation_artifacts WHERE rowid IN (
          SELECT rowid FROM translation_artifacts ORDER BY accessed_at DESC
          LIMIT -1 OFFSET 4096
        );
      ''');
      return null;
    case 'clear':
      db.execute('''
        DELETE FROM page_content;
        DELETE FROM ocr_artifacts;
        DELETE FROM translation_artifacts;
      ''');
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
      db.execute('VACUUM;');
      return null;
  }
  throw ArgumentError.value(operation, 'operation');
}
