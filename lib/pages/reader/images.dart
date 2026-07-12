part of 'reader.dart';

// ═══════════════════════════════════════════════════════════════
// _ImageViewControllerMixin — Gallery/Continuous 共享方法
// ═══════════════════════════════════════════════════════════════

/// 两种模式共享 [getImageByOffset]（实现完全相同）。
mixin _ImageViewControllerMixin implements _ImageViewController {
  /// 由混入此 mixin 的 State 子类提供。
  BuildContext get context;

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey).readAsBytes();
    } else {
      return (await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      ))!.readAsBytes();
    }
  }
}

class _ReaderImages extends StatefulWidget {
  const _ReaderImages({super.key});

  @override
  State<_ReaderImages> createState() => _ReaderImagesState();
}

class _ReaderImagesState extends State<_ReaderImages>
    with WidgetsBindingObserver {
  String? error;
  bool inProgress = false;
  late _ReaderState reader;

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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.resumed && reader.images != null) {
      WebPImageProvider.setInteractionState(InteractionState.idle);
      _attachReaderPipeline(context);
      _reportReaderPage(reader.page);
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
            _reportReaderPage(reader.page);
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
      var res = await reader.type.comicSource!.loadComicPages!(
        reader.widget.cid,
        cp,
      );
      if (res.error) {
        setState(() {
          error = res.errorMessage;
          reader.isLoading = false;
          inProgress = false;
        });
      } else {
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
            _reportReaderPage(reader.page);
          }
        });
      }
    }
    context.readerScaffold.update();
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

class _GalleryMode extends StatefulWidget {
  const _GalleryMode({super.key});

  @override
  State<_GalleryMode> createState() => _GalleryModeState();
}

class _GalleryModeState extends State<_GalleryMode>
    with _ImageViewControllerMixin
    implements _ImageViewController {
  late PageController controller;
  int get preCacheCount => appdata.settings["preloadImageCount"];
  final Map<int, PhotoViewController> photoViewControllers = {};
  late _ReaderState reader;

  bool get showChapterCommentsAtEnd {
    if (reader.mode != ReaderMode.galleryLeftToRight &&
        reader.mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (reader.widget.chapters == null) return false;
    var source = ComicSource.find(reader.type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  int get totalImagePages {
    return !reader.showSingleImageOnFirstPage()
        ? (reader.images!.length / reader.imagesPerPage).ceil()
        : 1 + ((reader.images!.length - 1) / reader.imagesPerPage).ceil();
  }

  int get totalPages => reader.totalPages;

  bool isChapterCommentsPage(int pageIndex) {
    return showChapterCommentsAtEnd && pageIndex == totalImagePages + 1;
  }

  var imageStates = <State<ComicImage>>{};
  bool isLongPressing = false;
  int fingers = 0;

  /// Timer to transition from settling to idle after page animation completes.
  Timer? _settlingTimer;

  /// WebP 三级缓存（生命周期绑定本 State）
  @override
  final DecodedImageCache webpCache = DecodedImageCache();

  // 某源被确认为动图 WebP 时重建：当前页 provider 从 ReaderImageProvider 翻成
  // WebPImageProvider（挂到管道正在解码的 session）→ 首次浏览即流式。仅首张动图页
  // 触发一次，之后同源页 build 时已在 registry → 直接 WebP、不再翻转。
  void _onWebPSourceLearned() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    reader = context.reader;
    controller = PageController(initialPage: reader.page);
    reader._imageViewController = this;
    WebPSourceRegistry.revision.addListener(_onWebPSourceLearned);
    Future.microtask(() {
      context.readerScaffold.setFloatingButton(0);
    });
    Future.microtask(() {
      if (mounted) {
        _attachReaderPipeline(context);
        _reportReaderPage(reader.page);
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    _settlingTimer?.cancel();
    WebPSourceRegistry.revision.removeListener(_onWebPSourceLearned);
    PipelineController.instance.detachReaderSession();
    webpCache.dispose();
    _ComicImageState.clear();
    super.dispose();
  }

  (int start, int end) getPageImagesRange(int page) {
    var imagesPerPage = reader.imagesPerPage;
    if (reader.showSingleImageOnFirstPage()) {
      if (page == 1) {
        return (0, 1);
      } else {
        int startIndex = (page - 2) * imagesPerPage + 1;
        int endIndex = math.min(
          startIndex + imagesPerPage,
          reader.images!.length,
        );
        return (startIndex, endIndex);
      }
    } else {
      int startIndex = (page - 1) * imagesPerPage;
      int endIndex = math.min(
        startIndex + imagesPerPage,
        reader.images!.length,
      );
      return (startIndex, endIndex);
    }
  }

  (int, int)? getCurrentPageImageRange() {
    if (reader.images == null || reader.images!.isEmpty) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(reader.page);
    return (startIndex, endIndex);
  }

  Widget _buildChapterCommentsPage() {
    var source = ComicSource.find(reader.type.sourceKey);
    var chapters = reader.widget.chapters;
    if (source == null || chapters == null) return const SizedBox();
    var chapterIndex = reader.chapter - 1;
    return _EmbeddedChapterCommentsPage(
      comicId: reader.cid,
      epId: chapters.ids.elementAt(chapterIndex),
      source: source,
      comicTitle: reader.widget.name,
      chapterTitle: chapters.titles.elementAt(chapterIndex),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        fingers++;
      },
      onPointerUp: (event) {
        fingers--;
      },
      onPointerCancel: (event) {
        fingers--;
      },
      onPointerMove: (event) {
        if (isLongPressing) {
          var controller = photoViewControllers[reader.page];
          if (controller == null) return;
          Offset value = event.delta;
          controller.updateMultiple(position: controller.position + value);
        }
      },
      child: PhotoViewGallery.builder(
        backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
        reverse: reader.mode == ReaderMode.galleryRightToLeft,
        scrollDirection: reader.mode == ReaderMode.galleryTopToBottom
            ? Axis.vertical
            : Axis.horizontal,
        itemCount: totalPages + 2,
        builder: (BuildContext context, int index) {
          if (index == 0 || index == totalPages + 1) {
            return PhotoViewGalleryPageOptions.customChild(
              child: const SizedBox(),
            );
          } else if (isChapterCommentsPage(index)) {
            return PhotoViewGalleryPageOptions.customChild(
              child: _buildChapterCommentsPage(),
            );
          } else {
            var (startIndex, endIndex) = getPageImagesRange(index);
            List<String> pageImages = reader.images!.sublist(
              startIndex,
              endIndex,
            );

            photoViewControllers[index] ??= PhotoViewController();

            if (reader.imagesPerPage == 1 || pageImages.length == 1) {
              final imageProvider = _createImageProviderFromKey(
                pageImages[0],
                context,
              );
              final cachedSize =
                  _ComicImageState._getCache(imageProvider.hashCode) ??
                  MediaQuery.of(context).size;
              return PhotoViewGalleryPageOptions.customChild(
                childSize: cachedSize,
                controller: photoViewControllers[index],
                child: ComicImage(
                  image: imageProvider,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  onInit: (state) => imageStates.add(state),
                  onDispose: (state) => imageStates.remove(state),
                  onImageInfo: (w, h) {
                    final newSize = Size(w.toDouble(), h.toDouble());
                    final old = _ComicImageState._getCache(
                      imageProvider.hashCode,
                    );
                    if (old != newSize) {
                      _ComicImageState._putCache(
                        imageProvider.hashCode,
                        newSize,
                      );
                      if (mounted) setState(() {});
                    }
                  },
                  errorBuilder: (_, error, s, retry) {
                    return NetworkError(
                      message: error.toString(),
                      retry: retry,
                    );
                  },
                ),
              );
            }

            final viewportSize = MediaQuery.of(context).size;
            return PhotoViewGalleryPageOptions.customChild(
              childSize: viewportSize,
              controller: photoViewControllers[index],
              minScale: PhotoViewComputedScale.contained * 1.0,
              maxScale: PhotoViewComputedScale.covered * 10.0,
              child: buildPageImages(pageImages, startIndex),
            );
          }
        },
        pageController: controller,
        loadingBuilder: (context, event) {
          return PhotoView.customChild(
            childSize: MediaQuery.of(context).size,
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained * 1.0,
            maxScale: PhotoViewComputedScale.covered * 10.0,
            backgroundDecoration: BoxDecoration(
              color: context.colorScheme.surface,
            ),
            child: Center(
              child: SizedBox(
                width: 20.0,
                height: 20.0,
                child: CircularProgressIndicator(
                  backgroundColor: context.colorScheme.surfaceContainerHigh,
                  value: event == null || event.expectedTotalBytes == null
                      ? null
                      : event.cumulativeBytesLoaded / event.expectedTotalBytes!,
                ),
              ),
            ),
          );
        },
        onPageChanged: (i) {
          if (i == 0) {
            if (reader.isFirstChapterOfGroup ||
                !reader.toPrevChapter(toLastPage: true)) {
              controller.jumpToPage(1);
            }
          } else if (i == totalPages + 1) {
            if (reader.isLastChapterOfGroup || !reader.toNextChapter()) {
              controller.jumpToPage(totalPages);
            }
          } else {
            reader.setPage(i);
            _reportReaderPage(i);
            context.readerScaffold.update();
            if (isChapterCommentsPage(i) && context.readerScaffold.isOpen) {
              context.readerScaffold.openOrClose();
            }
          }
          var keys = photoViewControllers.keys.toList();
          for (var key in keys) {
            if (key != i) photoViewControllers.remove(key);
          }
        },
      ),
    );
  }

  Widget buildPageImages(List<String> images, int startIndex) {
    Axis axis = (reader.mode == ReaderMode.galleryTopToBottom)
        ? Axis.vertical
        : Axis.horizontal;
    bool reverse = reader.mode == ReaderMode.galleryRightToLeft;
    if (reverse) images = images.reversed.toList();

    List<Widget> imageWidgets;
    if (images.length == 2) {
      imageWidgets = [
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(images[0], context),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.bottomCenter
                : Alignment.centerRight,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
            errorBuilder: (_, error, s, retry) {
              return NetworkError(message: error.toString(), retry: retry);
            },
          ),
        ),
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(images[1], context),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
            errorBuilder: (_, error, s, retry) {
              return NetworkError(message: error.toString(), retry: retry);
            },
          ),
        ),
      ];
    } else {
      imageWidgets = images.map((imageKey) {
        startIndex++;
        return Expanded(
          child: ComicImage(
            image: _createImageProviderFromKey(imageKey, context),
            fit: BoxFit.contain,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
            errorBuilder: (_, error, s, retry) {
              return NetworkError(message: error.toString(), retry: retry);
            },
          ),
        );
      }).toList();
    }

    return axis == Axis.vertical
        ? Column(children: imageWidgets)
        : Row(children: imageWidgets);
  }

  @override
  Future<void> animateToPage(int page) {
    if ((page - controller.page!.round()).abs() > 1) {
      return Future.value();
    }
    return controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void toPage(int page) {
    controller.jumpToPage(page);
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    var controller = photoViewControllers[reader.page];
    if (controller == null) return;
    controller.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || fingers != 1) return;
    var photoViewController = photoViewControllers[reader.page];
    if (photoViewController == null) return;
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition = appdata.settings['longPressZoomPosition'] != 'center'
        ? Offset(size.width / 2 - location.dx, size.height / 2 - location.dy)
        : Offset.zero;
    photoViewController.animateScale?.call(target, zoomPosition);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || !isLongPressing) return;
    var photoViewController = photoViewControllers[reader.page];
    if (photoViewController == null) return;
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    isLongPressing = false;
  }

  Timer? keyRepeatTimer;

  @override
  void handleKeyEvent(KeyEvent event) {
    bool? forward;
    if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (event is KeyDownEvent) {
      keyRepeatTimer?.cancel();
      keyRepeatTimer = null;
      if (forward == true) {
        reader.toPage(reader.page + 1);
      } else if (forward == false) {
        reader.toPage(reader.page - 1);
      }
    }
    if (event is KeyRepeatEvent && keyRepeatTimer == null) {
      keyRepeatTimer = Timer.periodic(
        reader.enablePageAnimation(reader.cid, reader.type)
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 50),
        (timer) {
          if (!mounted) {
            timer.cancel();
          } else if (forward == true) {
            reader.toPage(reader.page + 1);
          } else if (forward == false) {
            reader.toPage(reader.page - 1);
          }
        },
      );
    }
    if (event is KeyUpEvent) {
      keyRepeatTimer?.cancel();
      keyRepeatTimer = null;
    }
  }

  @override
  bool handleOnTap(Offset location) => false;

  @override
  String? getImageKeyByOffset(Offset offset) {
    var range = getCurrentPageImageRange();
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return reader.images![startIndex];
    }

    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        var provider = imageState.widget.image;
        String? imageKey;
        if (provider is ReaderImageProvider) {
          imageKey = provider.imageKey;
        } else if (provider is WebPImageProvider) {
          imageKey = provider.imageKey;
        }
        if (imageKey != null) {
          int index = reader.images!.indexOf(imageKey);
          if (index >= startIndex && index < endIndex) return imageKey;
        }
      }
    }
    return reader.images![startIndex];
  }
}

const Set<PointerDeviceKind> _kTouchLikeDeviceTypes = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

const double _kChangeChapterOffset = 160;

class _ContinuousMode extends StatefulWidget {
  const _ContinuousMode({super.key});

  @override
  State<_ContinuousMode> createState() => _ContinuousModeState();
}

class _ContinuousModeState extends State<_ContinuousMode>
    with _ImageViewControllerMixin
    implements _ImageViewController {
  late _ReaderState reader;

  var itemScrollController = ItemScrollController();
  var itemPositionsListener = ItemPositionsListener.create();
  var photoViewController = PhotoViewController();
  ScrollController? _scrollController;

  ScrollController get scrollController => _scrollController!;

  var isCTRLPressed = false;
  var fingers = 0;
  bool disableScroll = false;

  int get preCacheCount => appdata.settings["preloadImageCount"];
  bool delayedIsScrolling = false;
  var imageStates = <State<ComicImage>>{};

  /// Timer for the settling to idle transition.
  Timer? _settlingTimer;

  @override
  final DecodedImageCache webpCache = DecodedImageCache();

  /// Delayed scrolling state timer. Always cancel before replacing it.
  Timer? _delayedScrollingTimer;

  void delayedSetIsScrolling(bool value) {
    _delayedScrollingTimer?.cancel();
    delayedIsScrolling = value;
  }

  bool prepareToPrevChapter = false;
  bool prepareToNextChapter = false;
  bool jumpToNextChapter = false;
  bool jumpToPrevChapter = false;

  bool isZoomedIn = false;
  bool isLongPressing = false;

  // 见 _GalleryModeState._onWebPSourceLearned。
  void _onWebPSourceLearned() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    reader = context.reader;
    reader._imageViewController = this;
    itemPositionsListener.itemPositions.addListener(onPositionChanged);
    WebPSourceRegistry.revision.addListener(_onWebPSourceLearned);
    Future.microtask(() {
      if (mounted) {
        _attachReaderPipeline(context);
        _reportReaderPage(reader.page);
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    _settlingTimer?.cancel();
    _delayedScrollingTimer?.cancel();
    itemPositionsListener.itemPositions.removeListener(onPositionChanged);
    WebPSourceRegistry.revision.removeListener(_onWebPSourceLearned);
    PipelineController.instance.detachReaderSession();
    webpCache.dispose();
    _ComicImageState.clear();
    super.dispose();
  }

  void onPositionChanged() {
    final page = _centerVisiblePage();
    if (page == null) return;
    if (page != reader.page) {
      reader.setPage(page);
      _reportReaderPage(page);
      context.readerScaffold.update();
    }
  }

  int? _centerVisiblePage() {
    final positions = itemPositionsListener.itemPositions.value
        .where(
          (position) => position.index >= 1 && position.index <= reader.maxPage,
        )
        .toList();
    if (positions.isEmpty) return null;

    const viewportCenter = 0.5;
    positions.sort((a, b) {
      final aContainsCenter =
          a.itemLeadingEdge <= viewportCenter &&
          a.itemTrailingEdge >= viewportCenter;
      final bContainsCenter =
          b.itemLeadingEdge <= viewportCenter &&
          b.itemTrailingEdge >= viewportCenter;
      if (aContainsCenter != bContainsCenter) {
        return aContainsCenter ? -1 : 1;
      }

      final aCenter = (a.itemLeadingEdge + a.itemTrailingEdge) / 2;
      final bCenter = (b.itemLeadingEdge + b.itemTrailingEdge) / 2;
      return (aCenter - viewportCenter).abs().compareTo(
        (bCenter - viewportCenter).abs(),
      );
    });
    return positions.first.index;
  }

  double? _futurePosition;

  void smoothTo(double offset) {
    if (HardwareKeyboard.instance.isShiftPressed) return;
    var currentLocation = scrollController.position.pixels;
    var old = _futurePosition;
    _futurePosition = old ?? currentLocation;
    _futurePosition = _futurePosition! + offset;

    scrollController.animateTo(
      _futurePosition!,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
    );
  }

  void onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (isCTRLPressed) return;
      smoothTo(event.scrollDelta.dy);
    }
  }

  void onScroll() {
    if (prepareToPrevChapter) {
      jumpToNextChapter = false;
      jumpToPrevChapter =
          scrollController.offset <
          scrollController.position.minScrollExtent - _kChangeChapterOffset;
    } else if (prepareToNextChapter) {
      jumpToNextChapter =
          scrollController.offset >
          scrollController.position.maxScrollExtent + _kChangeChapterOffset;
      jumpToPrevChapter = false;
    }
  }

  bool onScaleUpdate([double? scale]) {
    if (prepareToNextChapter || prepareToPrevChapter) {
      setState(() {
        prepareToPrevChapter = false;
        prepareToNextChapter = false;
      });
      context.readerScaffold.setFloatingButton(0);
    }
    var isZoomedIn = (scale ?? photoViewController.scale) != 1.0;
    if (isZoomedIn != this.isZoomedIn) {
      setState(() {
        this.isZoomedIn = isZoomedIn;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    Widget widget = ScrollablePositionedList.builder(
      initialScrollIndex: reader.page,
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      scrollControllerCallback: (scrollController) {
        _scrollController?.removeListener(onScroll);
        _scrollController = scrollController;
        _scrollController!.addListener(onScroll);
      },
      itemCount: reader.maxPage + 2,
      addSemanticIndexes: false,
      scrollDirection: reader.mode == ReaderMode.continuousTopToBottom
          ? Axis.vertical
          : Axis.horizontal,
      reverse: reader.mode == ReaderMode.continuousRightToLeft,
      physics: isCTRLPressed || disableScroll
          ? const NeverScrollableScrollPhysics()
          : isZoomedIn
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      itemBuilder: (context, index) {
        if (index == 0 || index == reader.maxPage + 1) return const SizedBox();
        double? width, height;
        if (reader.mode == ReaderMode.continuousLeftToRight ||
            reader.mode == ReaderMode.continuousRightToLeft) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }

        return ColoredBox(
          color: context.colorScheme.surface,
          child: ComicImage(
            filterQuality: FilterQuality.medium,
            image: _createImageProvider(index, context),
            width: width,
            height: height,
            fit: BoxFit.contain,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
            errorBuilder: (_, error, s, retry) {
              return NetworkError(message: error.toString(), retry: retry);
            },
          ),
        );
      },
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: _kTouchLikeDeviceTypes,
      ),
    );

    widget = Stack(
      children: [
        Positioned.fill(child: buildBackground(context)),
        Positioned.fill(child: widget),
      ],
    );

    widget = Listener(
      onPointerDown: (event) {
        fingers++;
        if (fingers > 1 && !disableScroll) {
          setState(() {
            disableScroll = true;
          });
        }
        _futurePosition = null;
      },
      onPointerUp: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
        if (fingers == 0) {
          if (jumpToPrevChapter) {
            context.readerScaffold.setFloatingButton(0);
            reader.toPrevChapter(toLastPage: true);
          } else if (jumpToNextChapter) {
            context.readerScaffold.setFloatingButton(0);
            reader.toNextChapter();
          }
        }
      },
      onPointerCancel: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.scale == 1.0) smoothTo(0 - event.panDelta.dy);
      },
      onPointerMove: (event) {
        Offset value = event.delta;
        if (photoViewController.scale == 1 || fingers != 1) return;
        Offset offset;
        var sp = scrollController.position;
        if (sp.pixels <= sp.minScrollExtent ||
            sp.pixels >= sp.maxScrollExtent) {
          offset = Offset(value.dx, value.dy);
        } else {
          offset = (reader.mode == ReaderMode.continuousTopToBottom)
              ? Offset(value.dx, 0)
              : Offset(0, value.dy);
        }
        if (isLongPressing) offset += value;
        photoViewController.updateMultiple(
          position: photoViewController.position + offset,
        );
      },
      onPointerSignal: onPointerSignal,
      child: widget,
    );

    widget = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          delayedSetIsScrolling(true);
          WebPImageProvider.setInteractionState(InteractionState.dragging);
        } else if (notification is ScrollEndNotification) {
          delayedSetIsScrolling(false);
          WebPImageProvider.setInteractionState(InteractionState.idle);
        }

        var scale = photoViewController.scale ?? 1.0;
        if (notification is ScrollUpdateNotification &&
            (scale - 1).abs() < 0.05) {
          if (!scrollController.hasClients) return false;
          if (scrollController.position.pixels <=
                  scrollController.position.minScrollExtent &&
              !reader.isFirstChapterOfGroup) {
            if (!prepareToPrevChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(-1);
              setState(() {
                prepareToPrevChapter = true;
              });
            }
          } else if (scrollController.position.pixels >=
                  scrollController.position.maxScrollExtent &&
              !reader.isLastChapterOfGroup) {
            if (!prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(1);
              setState(() {
                prepareToNextChapter = true;
              });
            }
          } else {
            context.readerScaffold.setFloatingButton(0);
            if (prepareToPrevChapter || prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              setState(() {
                prepareToPrevChapter = false;
                prepareToNextChapter = false;
              });
            }
          }
        }
        return true;
      },
      child: widget,
    );

    var width = reader.size.width;
    var height = reader.size.height;
    if (appdata.settings['limitImageWidth'] &&
        width / height > 0.7 &&
        reader.mode == ReaderMode.continuousTopToBottom) {
      width = height * 0.7;
    }

    return PhotoView.customChild(
      backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
      childSize: Size(width, height),
      minScale: 1.0,
      maxScale: 2.5,
      strictScale: true,
      controller: photoViewController,
      onScaleUpdate: onScaleUpdate,
      child: SizedBox(width: width, height: height, child: widget),
    );
  }

  Widget buildBackground(BuildContext context) {
    return Column(
      children: [
        SizedBox(height: context.padding.top + 16),
        if (prepareToPrevChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: true,
          ),
        const Spacer(),
        if (prepareToNextChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: false,
          ),
        const SizedBox(height: 36),
      ],
    );
  }

  @override
  Future<void> animateToPage(int page) {
    return itemScrollController.scrollTo(
      index: page,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    double target =
        (photoViewController.scale !=
            photoViewController.getInitialScale?.call())
        ? photoViewController.getInitialScale!.call()!
        : photoViewController.getInitialScale!.call()! * 1.75;
    var size = MediaQuery.of(context).size;
    photoViewController.animateScale?.call(
      target,
      Offset(size.width / 2 - location.dx, size.height / 2 - location.dy),
    );
    onScaleUpdate(target);
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || delayedIsScrolling) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition = appdata.settings['longPressZoomPosition'] != 'center'
        ? Offset(size.width / 2 - location.dx, size.height / 2 - location.dy)
        : Offset.zero;
    photoViewController.animateScale?.call(target, zoomPosition);
    onScaleUpdate(target);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom']) return;
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    onScaleUpdate(target);
    isLongPressing = false;
  }

  @override
  void toPage(int page) {
    itemScrollController.jumpTo(index: page);
    _futurePosition = null;
  }

  @override
  void handleKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      setState(() {
        if (event is KeyDownEvent) {
          isCTRLPressed = true;
        } else if (event is KeyUpEvent) {
          isCTRLPressed = false;
        }
      });
    }
    if (event is KeyUpEvent) return;
    bool? forward;
    if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (forward == true) {
      scrollController.animateTo(
        scrollController.offset + context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else if (forward == false) {
      scrollController.animateTo(
        scrollController.offset - context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    }
  }

  @override
  bool handleOnTap(Offset location) => delayedIsScrolling;

  @override
  String? getImageKeyByOffset(Offset offset) {
    String? imageKey;
    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        var provider = imageState.widget.image;
        if (provider is ReaderImageProvider) {
          imageKey = provider.imageKey;
        } else if (provider is WebPImageProvider) {
          imageKey = provider.imageKey;
        }
      }
    }
    return imageKey;
  }
}

ImageProvider _createImageProviderFromKey(
  String imageKey,
  BuildContext context,
) {
  var reader = context.reader;

  // 非 webp（绝大多数漫画页是 jpg/png）走轻量 ReaderImageProvider 快路径：Flutter
  // 标准 fetch→codec，渐进加载、无 50ms 回退硬等。疑似/已知 webp（可能是动图）才进
  // WebPImageProvider 的流式/native texture 管线。
  //
  // 判据两条：①文件名含 .webp；②WebPSourceRegistry 记得该源上次会话确认过动图 WebP
  // ——因为有的源图片 key 是纯数字无扩展名（如 111），只靠文件名会误判为非 webp、被
  // 打回非流式老路（转圈转完才播）。registry 是会话稳定的（只读上次持久化快照），保证
  // 同一源本会话内所有页 provider 类型一致，翻页无 provider 翻转/无 setState churn。
  final sourceKey = reader.type.comicSource?.key;
  final treatAsWebP = WebPImageProvider.isLikelyWebP(imageKey) ||
      WebPSourceRegistry.isWebPSource(sourceKey);
  if (!treatAsWebP) {
    final page = reader.images?.indexOf(imageKey) ?? 0;
    return ReaderImageProvider(
      imageKey,
      sourceKey,
      reader.cid,
      reader.eid,
      page < 0 ? 0 : page,
    );
  }

  final (targetWidth, targetHeight) = WebPImageProvider.calculateTargetSize(
    context,
  );
  final double dpr = MediaQuery.of(context).devicePixelRatio;
  var imageCtrl = reader._imageViewController;
  final cache = imageCtrl?.webpCache;

  return WebPImageProvider(
    imageKey: imageKey,
    sourceKey: sourceKey,
    cid: reader.cid,
    eid: reader.eid,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
    scale: 1.0 / dpr,
    cache: cache,
  );
}

ImageProvider _createImageProvider(int page, BuildContext context) {
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  return _createImageProviderFromKey(imageKey, context);
}

void _attachReaderPipeline(BuildContext context) {
  final reader = context.reader;
  final images = reader.images;
  if (images == null) return;
  final (targetWidth, targetHeight) = WebPImageProvider.calculateTargetSize(
    context,
  );
  PipelineController.instance.attachReaderSession(ReaderPipelineSession(
    images: images,
    cid: reader.cid,
    eid: reader.eid,
    sourceKey: reader.type.comicSource?.key,
    cache: reader._imageViewController?.webpCache,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
    preloadCount: appdata.settings["preloadImageCount"] ?? 5,
  ));
}

void _reportReaderPage(int page) =>
    PipelineController.instance.onReaderPageChanged(page - 1);

class _SwipeChangeChapterProgress extends StatefulWidget {
  const _SwipeChangeChapterProgress({this.controller, required this.isPrev});

  final ScrollController? controller;
  final bool isPrev;

  @override
  State<_SwipeChangeChapterProgress> createState() =>
      _SwipeChangeChapterProgressState();
}

class _SwipeChangeChapterProgressState
    extends State<_SwipeChangeChapterProgress> {
  double value = 0;
  late final isPrev = widget.isPrev;
  ScrollController? controller;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      controller = widget.controller;
      controller!.addListener(onScroll);
    }
  }

  @override
  void didUpdateWidget(covariant _SwipeChangeChapterProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      controller?.removeListener(onScroll);
      controller = widget.controller;
      controller?.addListener(onScroll);
      if (value != 0) {
        setState(() {
          value = 0;
        });
      }
    }
  }

  @override
  void dispose() {
    controller?.removeListener(onScroll);
    super.dispose();
  }

  void onScroll() {
    var position = controller!.position.pixels;
    var offset = isPrev
        ? controller!.position.minScrollExtent - position
        : position - controller!.position.maxScrollExtent;
    var newValue = offset / _kChangeChapterOffset;
    newValue = newValue.clamp(0.0, 1.0);
    if (newValue != value) {
      setState(() {
        value = newValue;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.isPrev
        ? "Swipe down for previous chapter".tl
        : "Swipe up for next chapter".tl;

    return CustomPaint(
      painter: _ProgressPainter(
        value: value,
        backgroundColor: context.colorScheme.surfaceContainerLow,
        color: context.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.isPrev ? Icons.arrow_downward : Icons.arrow_upward,
            color: context.colorScheme.onSurface,
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(msg),
        ],
      ).paddingVertical(6).paddingHorizontal(16),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  final double value;
  final Color backgroundColor;
  final Color color;

  const _ProgressPainter({
    required this.value,
    required this.backgroundColor,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, size.width, size.height, Radius.circular(16)),
      paint,
    );

    paint.color = color;
    canvas.drawRRect( RRect.fromLTRBR( 0, 0, size.width * value, size.height, Radius.circular(16),), paint,); }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ProgressPainter ||
        oldDelegate.value != value ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.color != color;
  }
}
