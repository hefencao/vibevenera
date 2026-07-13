part of 'reader.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    return Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: widget.initialEp ?? data.history.ep,
      initialPage: widget.initialPage ?? data.history.page,
      initialChapterGroup: data.history.group,
      author: data.author,
      tags: data.tags,
      prepareImages: data.prepareImages,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    final stopwatch = Stopwatch()..start();
    var comicSource = ComicSource.find(widget.sourceKey);
    var history = HistoryManager().find(
      widget.id,
      ComicType.fromKey(widget.sourceKey),
    );
    final type = ComicType.fromKey(widget.sourceKey);
    final cacheReuse = widget.sourceKey == 'ehentai' &&
            comicSource != null &&
            appdata.settings['reuseOldVersionCache'] == true
        ? ComicVersionMigration.restoreCacheReuseFor(
            sourceKey: widget.sourceKey,
            comicId: widget.id,
            type: type,
          )
        : null;
    if (comicSource == null) {
      var localComic = LocalManager().find(
        widget.id,
        ComicType.fromKey(widget.sourceKey),
      );
      if (localComic == null) {
        return Res.error("comic not found");
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: localComic.title,
          chapters: localComic.chapters,
          history: history ??
              History.fromModel(
                model: localComic,
                ep: 0,
                page: 0,
              ),
          author: localComic.subtitle,
          tags: localComic.tags,
        ),
      );
    } else {
      final cached = HistoryManager().findReaderMetadata(widget.id, type);
      if (cached != null) {
        Log.warning(
          'Reader.Load',
          'metadata cache hit: ${widget.sourceKey}/${widget.id} in ${stopwatch.elapsedMilliseconds}ms',
        );
        return Res(
          ReaderProps(
            type: type,
            cid: widget.id,
            name: cached.title,
            chapters: cached.chapters,
            history: history ?? History.fromModel(model: cached, ep: 0, page: 0),
            author: cached.subTitle ?? '',
            tags: cached.tags,
            prepareImages: cacheReuse,
          ),
        );
      }
      var comic = await comicSource.loadComicInfo!(widget.id);
      Log.warning(
        'Reader.Load',
        'loadComicInfo: ${widget.sourceKey}/${widget.id} in ${stopwatch.elapsedMilliseconds}ms',
      );
      if (comic.error) {
        return Res.fromErrorRes(comic);
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: comic.data.title,
          chapters: comic.data.chapters,
          history: history ??
              History.fromModel(
                model: comic.data,
                ep: 0,
                page: 0,
              ),
          author: comic.data.findAuthor() ?? "",
          tags: comic.data.plainTags,
          prepareImages: cacheReuse,
        ),
      );
    }
  }
}

class ReaderProps {
  final ComicType type;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  final Future<void>? prepareImages;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
    this.prepareImages,
  });
}
