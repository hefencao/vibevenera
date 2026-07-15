part of 'reader.dart';

class _ReaderImages extends StatefulWidget {
  const _ReaderImages({super.key});

  @override
  State<_ReaderImages> createState() => _ReaderImagesState();
}
class _ReaderImagesState extends State<_ReaderImages>
    with WidgetsBindingObserver {
  static final _pageListRefreshes = <String, Future<Res<List<String>>>>{};

  String? error;
  bool inProgress = false;
  bool _refreshedForImageError = false;
  late _ReaderState reader;
  bool _routeActive = false;

  @override
  void initState() {
    reader = context.reader;
    reader.isLoading = true;
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ImageDownloader.cancelAllLoadingImages();
    PipelineController.instance.detachReaderSession(reader);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    final changed = _routeActive != active;
    _routeActive = active;
    if (!active) {
      if (changed) PipelineController.instance.detachReaderSession(reader);
    } else if (reader.images != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !TickerMode.valuesOf(context).enabled) return;
        _attachReaderPipeline(context);
        _reportReaderPage(context, reader.page);
      });
    }
  }

  @override
  void didChangeMetrics() {
    if (!_routeActive || reader.images == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !TickerMode.valuesOf(context).enabled) return;
      _attachReaderPipeline(context);
      _reportReaderPage(context, reader.page);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.resumed && reader.images != null) {
      StreamingImageProvider.setInteractionState(InteractionState.idle);
      _attachReaderPipeline(context);
      _reportReaderPage(context, reader.page);
    }
  }

  void _handleJumpToLastPage() {
    if (reader._jumpToLastPageOnLoad) {
      reader._page = reader.maxPage;
      reader._jumpToLastPageOnLoad = false;
    }
  }

  void load() async {
    if (inProgress) return;
    inProgress = true;
    final stopwatch = Stopwatch()..start();
    final preparation = reader.widget.prepareImages;
    if (preparation != null) {
      final reuseStopwatch = Stopwatch()..start();
      Log.info(
        'Reader.Load',
        'waiting cache reuse: ${reader.type.sourceKey}/${reader.cid}',
      );
      await preparation;
      Log.info(
        'Reader.Load',
        'cache reuse ready: ${reader.type.sourceKey}/${reader.cid} '
            'wait=${reuseStopwatch.elapsedMilliseconds}ms '
            'total=${stopwatch.elapsedMilliseconds}ms',
      );
      if (!mounted) return;
    }
    if (reader.type == ComicType.local ||
        (LocalManager().isDownloaded(
          reader.cid,
          reader.type,
          reader.chapter,
          reader.widget.chapters,
        ))) {
      try {
        var images = await LocalManager().getImages(
          reader.cid,
          reader.type,
          reader.chapter,
        );
        Log.info(
          'Reader.Load',
          'local image list: ${reader.type.sourceKey}/${reader.cid} in ${stopwatch.elapsedMilliseconds}ms',
        );
        setState(() {
          reader.images = images;
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(() {
            reader.updateHistory();
          });
        });
        // Trigger initial pre-download after images are loaded; initState may
        // run before the image list is available.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _attachReaderPipeline(context);
            _reportReaderPage(context, reader.page);
          }
        });
      } catch (e) {
        setState(() {
          error = e.toString();
          reader.isLoading = false;
          inProgress = false;
        });
      }
    } else {
      var cp = reader.widget.chapters?.ids.elementAtOrNull(reader.chapter - 1);
      final pagesStopwatch = Stopwatch()..start();
      var cached = HistoryManager().findReaderPages(reader.cid, reader.type, cp);
      if (cached != null) {
        Log.info(
          'Reader.Load',
          'page cache hit: ${reader.type.sourceKey}/${reader.cid}/$cp '
              'lookup=${pagesStopwatch.elapsedMilliseconds}ms '
              'total=${stopwatch.elapsedMilliseconds}ms',
        );
        if (!await _waitForRouteTransition() || !mounted) return;
        setState(() {
          reader.images = cached;
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(reader.updateHistory);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _attachReaderPipeline(context);
            _reportReaderPage(context, reader.page);
          }
        });
        _refreshReaderPages(cp);
        context.readerScaffold.update();
        return;
      }
      var res = await reader.type.comicSource!.loadComicPages!(
        reader.widget.cid,
        cp,
      );
      Log.info(
        'Reader.Load',
        'loadComicPages: ${reader.type.sourceKey}/${reader.cid}/$cp '
            'request=${pagesStopwatch.elapsedMilliseconds}ms '
            'total=${stopwatch.elapsedMilliseconds}ms',
      );
      if (res.error) {
        setState(() {
          error = res.errorMessage;
          reader.isLoading = false;
          inProgress = false;
        });
      } else {
        HistoryManager().cacheReaderPages(reader.cid, reader.type, cp, res.data);
        if (!await _waitForRouteTransition() || !mounted) return;
        setState(() {
          reader.images = res.data;
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(() {
            reader.updateHistory();
          });
        });
        // Trigger initial pre-download after images are loaded.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _attachReaderPipeline(context);
            _reportReaderPage(context, reader.page);
          }
        });
      }
    }
    context.readerScaffold.update();
  }

  Future<bool> _waitForRouteTransition() async {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      return true;
    }
    final completer = Completer<bool>();
    late AnimationStatusListener listener;
    listener = (status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      animation.removeStatusListener(listener);
      completer.complete(status == AnimationStatus.completed);
    };
    animation.addStatusListener(listener);
    listener(animation.status);
    return completer.future;
  }

  Future<void> _refreshReaderPages(
    String? chapterId, {
    bool replaceAuthorityChanges = false,
  }) async {
    final currentImages = List<String>.of(reader.images!);
    final res = await _loadFreshReaderPages(chapterId);
    if (!res.error) {
      final sameContent = _samePagesIgnoringAuthority(currentImages, res.data);
      if (!replaceAuthorityChanges && sameContent) {
        HistoryManager().cacheReaderPages(
          reader.cid,
          reader.type,
          chapterId,
          currentImages,
        );
        if (!listEquals(currentImages, res.data)) {
          Log.info(
            'Reader.Cache',
            'page authority changes ignored: '
                '${reader.type.sourceKey}/${reader.cid}/$chapterId',
          );
        }
        return;
      }
      HistoryManager().cacheReaderPages(
        reader.cid,
        reader.type,
        chapterId,
        res.data,
      );
      if (mounted && !listEquals(reader.images, res.data)) {
        final oldImages = reader.images!;
        var changed = (oldImages.length - res.data.length).abs();
        for (var i = 0; i < math.min(oldImages.length, res.data.length); i++) {
          if (oldImages[i] != res.data[i]) changed++;
        }
        Log.warning(
          'Reader.Cache',
          'page urls refreshed: ${reader.type.sourceKey}/${reader.cid}/$chapterId changed=$changed/${res.data.length}',
        );
        setState(() {
          reader.images = res.data;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _attachReaderPipeline(context);
            _reportReaderPage(context, reader.page);
          }
        });
      }
    }
  }

  Future<Res<List<String>>> _loadFreshReaderPages(String? chapterId) {
    final key = '${reader.type.sourceKey}/${reader.cid}/$chapterId';
    final pending = _pageListRefreshes[key];
    if (pending != null) return pending;
    final stopwatch = Stopwatch()..start();
    final future = reader.type.comicSource!.loadComicPages!(
      reader.widget.cid,
      chapterId,
    );
    _pageListRefreshes[key] = future;
    unawaited(future.then(
      (res) {
        _pageListRefreshes.remove(key);
        Log.info(
          'Reader.Load',
          'refreshComicPages: ${reader.type.sourceKey}/${reader.cid}/$chapterId in ${stopwatch.elapsedMilliseconds}ms',
        );
      },
      onError: (Object _, StackTrace __) {
        _pageListRefreshes.remove(key);
      },
    ));
    return future;
  }

  void refreshPagesForImageError() {
    if (reader.type == ComicType.local ||
        LocalManager().isDownloaded(
          reader.cid,
          reader.type,
          reader.chapter,
          reader.widget.chapters,
        )) {
      return;
    }
    if (_refreshedForImageError) return;
    _refreshedForImageError = true;
    _refreshReaderPages(
      reader.widget.chapters?.ids.elementAtOrNull(reader.chapter - 1),
      replaceAuthorityChanges: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (reader.isLoading) {
      load();
      return const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      return GestureDetector(
        onTap: () {
          context.readerScaffold.openOrClose();
        },
        child: SizedBox.expand(
          child: NetworkError(
            message: error!,
            retry: () {
              setState(() {
                reader.isLoading = true;
                error = null;
              });
            },
          ),
        ),
      );
    } else {
      if (reader.mode.isGallery) {
        var showComments =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true;
        var showCommentsAtEnd =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
        return _GalleryMode(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${showComments}_$showCommentsAtEnd',
          ),
        );
      } else {
        return _ContinuousMode(key: Key(reader.mode.key));
      }
    }
  }
}

bool _samePagesIgnoringAuthority(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_sameImageIgnoringAuthority(a[i], b[i])) return false;
  }
  return true;
}

bool _sameImageIgnoringAuthority(String a, String b) {
  if (a == b) return true;
  final oldUri = Uri.parse(a), newUri = Uri.parse(b);
  if (!oldUri.hasAuthority || !newUri.hasAuthority) return false;
  if (!oldUri.isScheme('http') && !oldUri.isScheme('https')) return false;
  if (!newUri.isScheme('http') && !newUri.isScheme('https')) return false;
  return oldUri.path == newUri.path &&
      oldUri.query == newUri.query &&
      oldUri.fragment == newUri.fragment;
}
