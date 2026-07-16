part of 'reader.dart';

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

  int get preCacheCount => appdata.settings.getReaderSetting(
    reader.cid,
    reader.type.sourceKey,
    'preloadImageCount',
  );
  bool delayedIsScrolling = false;
  var imageStates = <State<ComicImage>>{};

  /// Timer for the settling to idle transition.
  Timer? _settlingTimer;

  @override
  final DecodedImageCache streamingCache = DecodedImageCache();

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

  // 见 _GalleryModeState._onStreamingSourceLearned。
  void _onStreamingSourceLearned() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    reader = context.reader;
    reader._imageViewController = this;
    itemPositionsListener.itemPositions.addListener(onPositionChanged);
    StreamingSourceRegistry.revision.addListener(_onStreamingSourceLearned);
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
    _delayedScrollingTimer?.cancel();
    itemPositionsListener.itemPositions.removeListener(onPositionChanged);
    StreamingSourceRegistry.revision.removeListener(_onStreamingSourceLearned);
    streamingCache.dispose();
    _ComicImageState.clear();
    super.dispose();
  }

  void onPositionChanged() {
    final page = _visiblePage(_touchViewportPosition);
    if (page == null) return;
    if (page != reader.page) {
      reader.setPage(page);
      _reportReaderPage(context, page);
      context.readerScaffold.updatePage();
    }
  }

  double? _touchViewportPosition;

  void _updateTouchViewportPosition(Offset position) {
    _touchViewportPosition = reader.mode == ReaderMode.continuousTopToBottom
        ? position.dy / reader.size.height
        : position.dx / reader.size.width;
    onPositionChanged();
  }

  int? _visiblePage(double? viewportPosition) {
    final positions = itemPositionsListener.itemPositions.value
        .where(
          (position) => position.index >= 1 && position.index <= reader.maxPage,
        )
        .toList();
    if (positions.isEmpty) return null;

    final target = viewportPosition ?? 0.5;
    positions.sort((a, b) {
      final aContainsTarget =
          a.itemLeadingEdge <= target && a.itemTrailingEdge >= target;
      final bContainsTarget =
          b.itemLeadingEdge <= target && b.itemTrailingEdge >= target;
      if (aContainsTarget != bContainsTarget) {
        return aContainsTarget ? -1 : 1;
      }

      final aCenter = (a.itemLeadingEdge + a.itemTrailingEdge) / 2;
      final bCenter = (b.itemLeadingEdge + b.itemTrailingEdge) / 2;
      return (aCenter - target).abs().compareTo(
        (bCenter - target).abs(),
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
          child: _ReaderTranslationLayer(
            pageIndex: index - 1,
            child: ComicImage(
              filterQuality: FilterQuality.low,
              image: _createImageProvider(index, context),
              width: width,
              height: height,
              fit: BoxFit.contain,
              onInit: (state) => imageStates.add(state),
              onDispose: (state) => imageStates.remove(state),
              onImageInfo: (w, h) => reader.observeAdaptivePage(
                reader.images![index - 1],
                index - 1,
                w,
                h,
              ),
              errorBuilder: (errorContext, error, s, retry) {
                return _buildReaderImageError(errorContext, error, s, retry);
              },
            ),
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
        _updateTouchViewportPosition(event.localPosition);
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
        _updateTouchViewportPosition(event.localPosition);
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
          reader.setTranslationInteraction(
            ComicTranslationInteraction.scrolling,
          );
          StreamingImageProvider.setInteractionState(InteractionState.scroll);
        } else if (notification is ScrollEndNotification) {
          delayedSetIsScrolling(false);
          reader.setTranslationInteraction(ComicTranslationInteraction.idle);
          StreamingImageProvider.setInteractionState(InteractionState.idle);
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
  bool turnViewport(bool forward) {
    final position = scrollController.position;
    final target = (position.pixels +
            (forward ? 1 : -1) * position.viewportDimension * 0.8)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return false;
    _futurePosition = target;
    unawaited(scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    ).whenComplete(() {
      if (_futurePosition == target) _futurePosition = null;
    }));
    return true;
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
    if (!appdata.settings.getReaderSetting(
          reader.cid,
          reader.type.sourceKey,
          'enableLongPressToZoom',
        ) ||
        delayedIsScrolling) {
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
    if (!appdata.settings.getReaderSetting(
      reader.cid,
      reader.type.sourceKey,
      'enableLongPressToZoom',
    )) {
      return;
    }
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
        } else if (provider is StreamingImageProvider) {
          imageKey = provider.imageKey;
        }
      }
    }
    return imageKey;
  }
}


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
