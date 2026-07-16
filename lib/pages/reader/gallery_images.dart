part of 'reader.dart';

class _GalleryMode extends StatefulWidget {
  const _GalleryMode({super.key});

  @override
  State<_GalleryMode> createState() => _GalleryModeState();
}

class _GalleryModeState extends State<_GalleryMode>
    with _ImageViewControllerMixin
    implements _ImageViewController {
  late PageController controller;
  int get preCacheCount => appdata.settings.getReaderSetting(
    reader.cid,
    reader.type.sourceKey,
    'preloadImageCount',
  );
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
  double? _lastViewportPage;
  int _viewportDirection = 0;
  bool _galleryRebuildPending = false;
  bool _galleryRebuildScheduled = false;

  /// WebP 三级缓存（生命周期绑定本 State）
  @override
  final DecodedImageCache streamingCache = DecodedImageCache();

  // 某源被确认为流式动图时重建：当前页 provider 从 ReaderImageProvider 翻成
  // StreamingImageProvider（挂到管道正在解码的 session）→ 首次浏览即流式。仅首张动图页
  // 触发一次，之后同源页 build 时已在 registry → 直接使用流式 provider、不再翻转。
  void _onStreamingSourceLearned() {
    _requestGalleryRebuild();
  }

  void _requestGalleryRebuild() {
    if (!mounted) return;
    _galleryRebuildPending = true;
    if (PipelineController.instance.viewportTransition.phase ==
        ViewportTransitionPhase.idle) {
      _scheduleGalleryRebuild();
    }
  }

  void _scheduleGalleryRebuild() {
    if (_galleryRebuildScheduled || !_galleryRebuildPending) return;
    _galleryRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _galleryRebuildScheduled = false;
      if (!mounted || !_galleryRebuildPending) return;
      if (PipelineController.instance.viewportTransition.phase !=
          ViewportTransitionPhase.idle) {
        return;
      }
      _galleryRebuildPending = false;
      setState(() {});
    });
  }

  void _finishViewportTransition() {
    _lastViewportPage = null;
    _viewportDirection = 0;
    PipelineController.instance.endViewportTransition(reader);
    _scheduleGalleryRebuild();
  }

  void _restoreBoundaryPage(int page) {
    controller.jumpToPage(page);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reportReaderPage(context, page);
      _finishViewportTransition();
    });
  }

  void _beginViewportTransition(ScrollMetrics metrics) {
    _lastViewportPage = metrics is PageMetrics ? metrics.page : null;
    _viewportDirection = 0;
    PipelineController.instance.beginViewportTransition();
  }

  void _updateViewportTransition(ScrollMetrics metrics) {
    if (metrics is! PageMetrics || metrics.page == null) return;
    final position = metrics.page!;
    final previous = _lastViewportPage;
    final delta = previous == null ? 0 : position - previous;
    if (delta.abs() > 0.0001) _viewportDirection = delta > 0 ? 1 : -1;
    _lastViewportPage = position;

    final dominantPage = position.round();
    final coverage = 1 - (position - dominantPage).abs();
    final targetPage = switch (_viewportDirection) {
      1 => position.ceil(),
      -1 => position.floor(),
      _ => dominantPage,
    };
    final targetKeys = <String>{};
    if (_viewportDirection != 0 &&
        targetPage >= 1 &&
        targetPage <= totalImagePages) {
      final (start, end) = getPageImagesRange(targetPage);
      targetKeys.addAll(reader.images!.getRange(start, end));
    }
    PipelineController.instance.updateViewportTransition(
      currentCoverage: coverage,
      targetKeys: targetKeys,
    );
  }

  @override
  void initState() {
    reader = context.reader;
    controller = PageController(initialPage: reader.page);
    reader._imageViewController = this;
    StreamingSourceRegistry.revision.addListener(_onStreamingSourceLearned);
    Future.microtask(() {
      context.readerScaffold.setFloatingButton(0);
    });
    Future.microtask(() {
      if (mounted) {
        _attachReaderPipeline(context);
        _reportReaderPage(context, reader.page);
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    _settlingTimer?.cancel();
    StreamingSourceRegistry.revision.removeListener(_onStreamingSourceLearned);
    streamingCache.dispose();
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
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth != 0) return false;
        if (notification is ScrollStartNotification) {
          _beginViewportTransition(notification.metrics);
          reader.setTranslationInteraction(
            notification.dragDetails == null
                ? ComicTranslationInteraction.settling
                : ComicTranslationInteraction.dragging,
          );
          StreamingImageProvider.setInteractionState(
            notification.dragDetails == null
                ? InteractionState.settling
                : InteractionState.dragging,
          );
        } else if (notification is ScrollUpdateNotification) {
          _updateViewportTransition(notification.metrics);
        } else if (notification is ScrollEndNotification) {
          _finishViewportTransition();
          reader.setTranslationInteraction(ComicTranslationInteraction.idle);
        }
        return false;
      },
      child: Listener(
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
                child: _ReaderTranslationLayer(
                  pageIndex: startIndex,
                  child: ComicImage(
                    image: imageProvider,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.low,
                    onInit: (state) => imageStates.add(state),
                    onDispose: (state) => imageStates.remove(state),
                    onImageInfo: (w, h) {
                      reader.observeAdaptivePage(
                        pageImages[0],
                        startIndex,
                        w,
                        h,
                      );
                      final newSize = Size(w.toDouble(), h.toDouble());
                      final old = _ComicImageState._getCache(
                        imageProvider.hashCode,
                      );
                      if (old != newSize) {
                        _ComicImageState._putCache(
                          imageProvider.hashCode,
                          newSize,
                        );
                        _requestGalleryRebuild();
                      }
                    },
                    errorBuilder: (errorContext, error, s, retry) {
                      return _buildReaderImageError(
                        errorContext,
                        error,
                        s,
                        retry,
                      );
                    },
                  ),
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
          var visiblePage = i;
          if (i == 0) {
            if (reader.isFirstChapterOfGroup ||
                !reader.toPrevChapter(toLastPage: true)) {
              visiblePage = 1;
              _restoreBoundaryPage(1);
            }
          } else if (i == totalPages + 1) {
            if (reader.isLastChapterOfGroup || !reader.toNextChapter()) {
              visiblePage = totalPages;
              _restoreBoundaryPage(totalPages);
            }
          } else {
            reader.setPage(i);
            _reportReaderPage(context, i);
            context.readerScaffold.updatePage();
            if (isChapterCommentsPage(i) && context.readerScaffold.isOpen) {
              context.readerScaffold.openOrClose();
            }
          }
          var keys = photoViewControllers.keys.toList();
          for (var key in keys) {
            if (key != visiblePage) photoViewControllers.remove(key);
          }
        },
        ),
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
          child: _ReaderTranslationLayer(
            pageIndex: reader.images!.indexOf(images[0]),
            alignment: axis == Axis.vertical
                ? Alignment.bottomCenter
                : Alignment.centerRight,
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
              onImageInfo: (w, h) => reader.observeAdaptivePage(
                images[0],
                reader.images!.indexOf(images[0]),
                w,
                h,
              ),
              errorBuilder: (errorContext, error, s, retry) {
                return _buildReaderImageError(errorContext, error, s, retry);
              },
            ),
          ),
        ),
        Expanded(
          child: _ReaderTranslationLayer(
            pageIndex: reader.images!.indexOf(images[1]),
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
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
              onImageInfo: (w, h) => reader.observeAdaptivePage(
                images[1],
                reader.images!.indexOf(images[1]),
                w,
                h,
              ),
              errorBuilder: (errorContext, error, s, retry) {
                return _buildReaderImageError(errorContext, error, s, retry);
              },
            ),
          ),
        ),
      ];
    } else {
      imageWidgets = images.map((imageKey) {
        startIndex++;
        return Expanded(
          child: _ReaderTranslationLayer(
            pageIndex: reader.images!.indexOf(imageKey),
            child: ComicImage(
              image: _createImageProviderFromKey(imageKey, context),
              fit: BoxFit.contain,
              onInit: (state) => imageStates.add(state),
              onDispose: (state) => imageStates.remove(state),
              onImageInfo: (w, h) => reader.observeAdaptivePage(
                imageKey,
                reader.images!.indexOf(imageKey),
                w,
                h,
              ),
              errorBuilder: (errorContext, error, s, retry) {
                return _buildReaderImageError(errorContext, error, s, retry);
              },
            ),
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
    ).whenComplete(_finishViewportTransition);
  }

  @override
  bool turnViewport(bool forward) => false;

  @override
  void toPage(int page) {
    _finishViewportTransition();
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
    if (!appdata.settings.getReaderSetting(
          reader.cid,
          reader.type.sourceKey,
          'enableLongPressToZoom',
        ) ||
        fingers != 1) {
      return;
    }
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
    if (!appdata.settings.getReaderSetting(
          reader.cid,
          reader.type.sourceKey,
          'enableLongPressToZoom',
        ) ||
        !isLongPressing) {
      return;
    }
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
        } else if (provider is StreamingImageProvider) {
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
