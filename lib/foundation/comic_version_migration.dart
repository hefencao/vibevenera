import 'package:html/parser.dart' as html;
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/download.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

final class ComicVersionLink {
  final String title;
  final String url;
  final String? date;
  final int generation;

  const ComicVersionLink(this.title, this.url, this.date, this.generation);

}

enum ComicVersionMigrationMode { incremental, redownload }

final class ComicVersionMigrationResult {
  final ComicDetails comic;
  final int pageOffset;
  final int reusedPages;

  const ComicVersionMigrationResult(this.comic, this.pageOffset, this.reusedPages);
}

final class ComicVersionMigrationPlan {
  final ComicDetails comic;
  final List<String> oldPages;
  final List<String> newPages;

  const ComicVersionMigrationPlan(this.comic, this.oldPages, this.newPages);
}

final class ComicVersionMigration {
  static Future<List<ComicVersionLink>> findVersions(ComicDetails comic) async {
    if (comic.sourceKey != 'ehentai') return const [];
    try {
      final response = await AppDio(BaseOptions(responseType: ResponseType.plain))
          .get<String>(comic.url ?? comic.id);
      final document = html.parse(response.data!);
      final container = document.getElementById('gnd');
      if (container == null) return const [];
      final base = Uri.parse(comic.url ?? comic.id);
      final anchors = container.querySelectorAll('a[href]');
      final dates = RegExp(
        r'</a>\s*,\s*added\s+(\d{4}-\d{2}-\d{2}(?:\s+\d{2}:\d{2})?)',
        caseSensitive: false,
      ).allMatches(container.innerHtml).map((match) => match.group(1)).toList();
      final versions = List.generate(anchors.length, (index) {
        final anchor = anchors[index];
        final url = base.resolve(anchor.attributes['href']!).toString();
        final date = dates.elementAtOrNull(index);
        return ComicVersionLink(anchor.text.trim(), url, date, index + 1);
      }).where((version) => version.url.contains('/g/')).toList();
      _recordRelations(comic, versions);
      return versions;
    } catch (error, stack) {
      Log.error('ComicVersion', error, stack);
      return const [];
    }
  }

  static String? downloadedPredecessor(ComicDetails comic) {
    final relations = appdata.implicitData['comicVersionRelations'];
    if (relations is! Map) return null;
    final predecessors = relations['${comic.sourceKey}:${_versionKey(comic.id)}'];
    if (predecessors is! List) return null;
    for (final id in predecessors.whereType<String>()) {
      if (LocalManager().find(id, comic.comicType) != null) return id;
    }
    return null;
  }

  static void _recordRelations(
    ComicDetails comic,
    List<ComicVersionLink> versions,
  ) {
    if (versions.isEmpty) return;
    final relations = Map<String, dynamic>.from(
      appdata.implicitData['comicVersionRelations'] as Map? ?? const {},
    );
    var changed = false;
    for (final version in versions) {
      final key = '${comic.sourceKey}:${_versionKey(version.url)}';
      final ids = List<String>.from(relations[key] as List? ?? const []);
      if (!ids.contains(comic.id)) {
        ids.add(comic.id);
        changed = true;
      }
      relations[key] = ids;
    }
    if (!changed) return;
    while (relations.length > 256) {
      relations.remove(relations.keys.first);
    }
    appdata.implicitData['comicVersionRelations'] = relations;
    appdata.writeImplicitData();
  }

  static String _versionKey(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    final match = RegExp(r'/g/\d+/[a-fA-F0-9]+').firstMatch(uri.path);
    return match?.group(0) ?? value;
  }

  static Future<Res<ComicVersionMigrationResult>> migrate({
    required ComicDetails oldComic,
    required String newUrl,
    required ComicVersionMigrationMode mode,
    int? forcedOffset,
    ComicVersionMigrationPlan? preparedPlan,
  }) async {
    final source = ComicSource.find(oldComic.sourceKey)!;
    if (LocalManager().isDownloading(oldComic.id, oldComic.comicType)) {
      return const Res.error('Finish or cancel the current download first');
    }
    ComicDetails newComic;
    List<String> oldPages;
    List<String> newPages;
    if (preparedPlan == null) {
      final detailsResult = await source.loadComicInfo!(newUrl);
      if (detailsResult.error) return Res.error(detailsResult.errorMessage!);
      newComic = detailsResult.data;
      final oldPagesResult = await source.loadComicPages!(oldComic.id, null);
      if (oldPagesResult.error) return Res.error(oldPagesResult.errorMessage!);
      final newPagesResult = await source.loadComicPages!(newComic.id, null);
      if (newPagesResult.error) return Res.error(newPagesResult.errorMessage!);
      oldPages = oldPagesResult.data;
      newPages = newPagesResult.data;
    } else {
      newComic = preparedPlan.comic;
      oldPages = preparedPlan.oldPages;
      newPages = preparedPlan.newPages;
    }
    if (LocalManager().isDownloading(newComic.id, newComic.comicType)) {
      return const Res.error('The new version is already downloading');
    }
    if (oldComic.chapters != null || newComic.chapters != null) {
      return const Res.error('Chaptered comic migration is not supported');
    }
    final mapping = forcedOffset == null
        ? await _matchPages(source, oldComic, newComic, oldPages, newPages)
        : {
            for (var i = 0; i < oldPages.length; i++) i: i + forcedOffset,
          };
    if (mode == ComicVersionMigrationMode.incremental && mapping.isEmpty) {
      return Res(
        null,
        errorMessage: 'No unchanged pages could be matched',
        subData: ComicVersionMigrationPlan(newComic, oldPages, newPages),
      );
    }
    final offset = _pageOffset(mapping);
    if (mode == ComicVersionMigrationMode.incremental) {
      _migrateCache(oldComic, newComic, oldPages, newPages, mapping);
    }
    final local = LocalManager().find(oldComic.id, oldComic.comicType);
    if (local != null) {
      if (mode == ComicVersionMigrationMode.incremental) {
        await LocalManager().migrateComicVersion(
          comic: local,
          details: newComic,
          pageMapping: mapping,
          newPages: newPages,
        );
      } else {
        await Directory(local.baseDir).deleteIgnoreError(recursive: true);
        LocalManager().removeComic(local);
      }
      LocalManager().addTask(ImagesDownloadTask(
        source: source,
        comicId: newComic.id,
        comic: newComic,
      ));
    }
    _migrateFavorites(oldComic, newComic);
    if (mapping.isNotEmpty) {
      ImageFavoriteManager().migrateComicVersion(
        details: newComic,
        oldId: oldComic.id,
        pageMapping: mapping,
        newPages: newPages,
      );
    }
    HistoryManager().migrateComicId(
      oldId: oldComic.id,
      newId: newComic.id,
      type: oldComic.comicType,
      pageOffset: offset,
      details: newComic,
      pages: newPages,
    );
    return Res(ComicVersionMigrationResult(newComic, offset, mapping.length));
  }

  static Future<Map<int, int>> _matchPages(
    ComicSource source,
    ComicDetails oldComic,
    ComicDetails newComic,
    List<String> oldPages,
    List<String> newPages,
  ) async {
    final oldIdentities = oldPages.map(_pageIdentity).toList();
    final newIdentities = newPages.map(_pageIdentity).toList();
    if (!oldIdentities.every((value) => value.startsWith('index:')) &&
        oldIdentities.toSet().length == oldPages.length) {
      return _matchIdentityLists(oldIdentities, newIdentities);
    }
    final resolver = source.getImageLoadingConfig;
    if (resolver == null || oldPages.isEmpty || newPages.length < oldPages.length) {
      return const {};
    }
    final delta = newPages.length - oldPages.length;
    final offsets = delta == 0 ? const [0] : [0, delta];
    final anchors = oldPages.length == 1
        ? const [0]
        : <int>{0, oldPages.length ~/ 2, oldPages.length - 1}.toList();
    final oldValues = await Future.wait(anchors.map((anchor) =>
        _resolvedImageIdentity(source, oldPages[anchor], oldComic.id)));
    final oldResolved = {
      for (var i = 0; i < anchors.length; i++) anchors[i]: oldValues[i],
    };
    for (final offset in offsets) {
      final newValues = await Future.wait(anchors.map((anchor) =>
          _resolvedImageIdentity(
            source,
            newPages[anchor + offset],
            newComic.id,
          )));
      var matches = 0;
      for (var i = 0; i < anchors.length; i++) {
        if (newValues[i] == oldResolved[anchors[i]]) matches++;
      }
      final required = anchors.length == 1 ? 1 : 2;
      if (matches >= required) {
        Log.warning(
          'ComicVersion',
          'page match old=${oldPages.length} new=${newPages.length} '
              'offset=$offset anchors=${anchors.length} matches=$matches',
        );
        return {for (var i = 0; i < oldPages.length; i++) i: i + offset};
      }
    }
    Log.warning(
      'ComicVersion',
      'page mismatch old=${oldPages.length} new=${newPages.length} '
          'offsets=$offsets anchors=${anchors.length}',
    );
    return const {};
  }

  static Map<int, int> _matchIdentityLists(
    List<String> oldIdentities,
    List<String> newIdentities,
  ) {
    final positions = <String, List<int>>{};
    for (var i = 0; i < newIdentities.length; i++) {
      positions.putIfAbsent(newIdentities[i], () => []).add(i);
    }
    final mapping = <int, int>{};
    for (var i = 0; i < oldIdentities.length; i++) {
      final matches = positions[oldIdentities[i]];
      if (matches?.length == 1) mapping[i] = matches!.single;
    }
    return mapping;
  }

  static String _pageIdentity(String page) {
    if (int.tryParse(page) != null) return 'index:$page';
    final uri = Uri.tryParse(page);
    final segments = uri?.pathSegments ?? const <String>[];
    final s = segments.indexOf('s');
    if (s >= 0 && s + 1 < segments.length) return 'eh:${segments[s + 1]}';
    final hash = RegExp(r'[a-fA-F0-9]{32,64}').firstMatch(page)?.group(0);
    return hash?.toLowerCase() ?? page;
  }

  static Future<String> _resolvedImageIdentity(
    ComicSource source,
    String imageKey,
    String comicId,
  ) async {
    final config = await source.getImageLoadingConfig!(imageKey, comicId, '0');
    final url = (config['url'] ?? imageKey) as String;
    final identity = _pageIdentity(url);
    return identity.startsWith('index:') ? '$comicId@$identity' : identity;
  }

  static int _pageOffset(Map<int, int> mapping) {
    if (mapping.isEmpty) return 0;
    final counts = <int, int>{};
    for (final entry in mapping.entries) {
      final offset = entry.value - entry.key;
      counts[offset] = (counts[offset] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  static void _migrateCache(
    ComicDetails oldComic,
    ComicDetails newComic,
    List<String> oldPages,
    List<String> newPages,
    Map<int, int> mapping,
  ) {
    for (final entry in mapping.entries) {
      for (final ep in const ['', '0']) {
        final oldKey = '${oldPages[entry.key]}@${oldComic.sourceKey}@${oldComic.id}@$ep';
        final newKey = '${newPages[entry.value]}@${newComic.sourceKey}@${newComic.id}@$ep';
        CacheManager().rekey(oldKey, newKey);
      }
    }
  }

  static void _migrateFavorites(ComicDetails oldComic, ComicDetails newComic) {
    final manager = LocalFavoritesManager();
    final folders = manager.find(oldComic.id, oldComic.comicType);
    final item = FavoriteItem(
      id: newComic.id,
      name: newComic.title,
      coverPath: newComic.cover,
      author: newComic.subTitle ?? newComic.uploader ?? '',
      type: newComic.comicType,
      tags: newComic.plainTags,
    );
    for (final folder in folders) {
      manager.deleteComicWithId(folder, oldComic.id, oldComic.comicType);
      manager.addComic(folder, item);
    }
  }
}
