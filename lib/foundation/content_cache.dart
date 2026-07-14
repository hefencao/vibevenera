import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

class CachedComicDetails {
  const CachedComicDetails(this.data, this.updatedAt);

  final ComicDetails data;
  final DateTime updatedAt;
}

class CachedSearchPage {
  const CachedSearchPage({
    required this.page,
    required this.comics,
    required this.subData,
    required this.inputCursor,
    required this.updatedAt,
  });

  final int page;
  final List<Comic> comics;
  final dynamic subData;
  final String? inputCursor;
  final DateTime updatedAt;
}

class ContentCache {
  ContentCache._();

  static final ContentCache instance = ContentCache._();
  static const _schemaVersion = 2;
  static const maxSearchPagesPerQuery = 5;

  late Database _db;
  late String _path;
  bool isInitialized = false;

  int get currentSize => isInitialized ? File(_path).lengthSync() : 0;

  Future<void> init(String dataPath) async {
    if (isInitialized) return;
    _path = '$dataPath/content_cache.db';
    _db = sqlite3.open(_path);
    final version = _db.select('PRAGMA user_version;').first[0] as int;
    if (version != _schemaVersion) {
      _db.execute('''
        DROP TABLE IF EXISTS comic_details;
        DROP TABLE IF EXISTS search_pages;
        PRAGMA user_version = $_schemaVersion;
      ''');
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS comic_details (
        source_key TEXT NOT NULL,
        source_version TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        accessed_at INTEGER NOT NULL,
        PRIMARY KEY (source_key, comic_id)
      );
      CREATE TABLE IF NOT EXISTS search_pages (
        cache_key TEXT NOT NULL,
        keyword TEXT NOT NULL,
        page INTEGER NOT NULL,
        input_cursor TEXT,
        sub_data TEXT,
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        accessed_at INTEGER NOT NULL,
        PRIMARY KEY (cache_key, page)
      );
    ''');
    isInitialized = true;
  }

  CachedComicDetails? findComicDetails(
    String sourceKey,
    String sourceVersion,
    String comicId,
  ) {
    final rows = _db.select(
      'SELECT payload, updated_at FROM comic_details WHERE source_key = ? AND source_version = ? AND comic_id = ?;',
      [sourceKey, sourceVersion, comicId],
    );
    if (rows.isEmpty) return null;
    return CachedComicDetails(
      ComicDetails.fromJson(jsonDecode(rows.first['payload'] as String)),
      DateTime.fromMillisecondsSinceEpoch(rows.first['updated_at'] as int),
    );
  }

  void cacheComicDetails(ComicDetails details, String sourceVersion) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      INSERT INTO comic_details
        (source_key, source_version, comic_id, payload, updated_at, accessed_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_key, comic_id) DO UPDATE SET
        source_version = excluded.source_version,
        payload = excluded.payload,
        updated_at = excluded.updated_at,
        accessed_at = excluded.accessed_at;
    ''', [details.sourceKey, sourceVersion, details.id,
      jsonEncode(details.toCacheJson()), now, now]);
    _db.execute('''
      DELETE FROM comic_details WHERE rowid IN (
        SELECT rowid FROM comic_details ORDER BY accessed_at DESC LIMIT -1 OFFSET 256
      );
    ''');
  }

  static String searchKey(
    String sourceKey,
    String sourceVersion,
    String keyword,
    List<String> options,
    bool cursorBased,
  ) => jsonEncode([sourceKey, sourceVersion, keyword, options, cursorBased]);

  List<CachedSearchPage> findSearchPages(String cacheKey) {
    final rows = _db.select('''
      SELECT page, input_cursor, sub_data, payload, updated_at
      FROM search_pages WHERE cache_key = ? ORDER BY page;
    ''', [cacheKey]);
    if (rows.isEmpty) return const [];
    return rows.map((row) {
      final data = jsonDecode(row['payload'] as String) as List;
      return CachedSearchPage(
        page: row['page'] as int,
        comics: data
            .map((item) => Comic.fromJson(
                  Map<String, dynamic>.from(item),
                  item['sourceKey'] as String,
                ))
            .toList(),
        subData: row['sub_data'] == null
            ? null
            : jsonDecode(row['sub_data'] as String),
        inputCursor: row['input_cursor'] as String?,
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      );
    }).toList();
  }

  void cacheSearchPage({
    required String cacheKey,
    required String keyword,
    required int page,
    required String? inputCursor,
    required dynamic subData,
    required List<Comic> comics,
  }) {
    if (page > maxSearchPagesPerQuery) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      INSERT INTO search_pages
        (cache_key, keyword, page, input_cursor, sub_data, payload, updated_at, accessed_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(cache_key, page) DO UPDATE SET
        keyword = excluded.keyword,
        input_cursor = excluded.input_cursor,
        sub_data = excluded.sub_data,
        payload = excluded.payload,
        updated_at = excluded.updated_at,
        accessed_at = excluded.accessed_at;
    ''', [
      cacheKey,
      keyword,
      page,
      inputCursor,
      jsonEncode(subData),
      jsonEncode(comics.map((comic) => comic.toCacheJson()).toList()),
      now,
      now,
    ]);
    _db.execute('''
      DELETE FROM search_pages WHERE rowid IN (
        SELECT rowid FROM search_pages ORDER BY accessed_at DESC LIMIT -1 OFFSET 256
      );
    ''');
  }

  void removeSearchKeyword(String keyword) {
    if (!isInitialized) return;
    _db.execute('DELETE FROM search_pages WHERE keyword = ?;', [keyword]);
  }

  void clearSearch() {
    if (isInitialized) _db.execute('DELETE FROM search_pages;');
  }

  void clear() {
    if (!isInitialized) return;
    _db.execute('DELETE FROM comic_details; DELETE FROM search_pages; VACUUM;');
  }
}
