part of 'reader.dart';

class _ReaderTranslationLayer extends StatefulWidget {
  final int pageIndex;
  final Alignment alignment;
  final Widget child;

  const _ReaderTranslationLayer({
    required this.pageIndex,
    required this.child,
    this.alignment = Alignment.center,
  });

  @override
  State<_ReaderTranslationLayer> createState() =>
      _ReaderTranslationLayerState();
}

class _ReaderTranslationLayerState extends State<_ReaderTranslationLayer> {
  static const _sourcePeekDuration = Duration(milliseconds: 1500);
  Timer? _sourcePeekTimer;
  String? _hiddenBlockKey;
  _ComicTranslationPainter? _painter;
  _ReaderState? _reader;
  Uint8List? _cleanOverlayBytes;
  bool _cleanOverlayReady = false;
  int _layoutGeneration = 0;
  bool _layoutScheduled = false;
  _ComicTranslationPainter? _layoutTaskPainter;
  Size? _layoutTaskSize;

  void _cancelLayoutPreparation() {
    if (!_layoutScheduled) return;
    _layoutGeneration++;
    _layoutScheduled = false;
    _layoutTaskPainter = null;
    _layoutTaskSize = null;
  }

  void _scheduleLayoutPreparation(
    _ComicTranslationPainter painter,
    Size size,
  ) {
    if (_layoutScheduled && identical(_layoutTaskPainter, painter) &&
        _layoutTaskSize == size) {
      return;
    }
    final generation = ++_layoutGeneration;
    _layoutScheduled = true;
    _layoutTaskPainter = painter;
    _layoutTaskSize = size;
    void scheduleNext() {
      unawaited(SchedulerBinding.instance.scheduleTask<void>(() {
        if (!mounted || generation != _layoutGeneration) return;
        late final bool completed;
        try {
          completed = painter.prepareNext(size);
        } catch (error, stack) {
          if (mounted && generation == _layoutGeneration) {
            _layoutScheduled = false;
            _layoutTaskPainter = null;
            _layoutTaskSize = null;
          }
          Log.error(
            'Translation.Overlay',
            'prepare failed page=${widget.pageIndex} '
                'digest=${painter.artifact.contentDigest.substring(0, 10)} '
                'prepared=${painter.layoutCache.prepared.length}: $error',
            stack,
          );
          rethrow;
        }
        if (!mounted || generation != _layoutGeneration) return;
        _layoutScheduled = !completed;
        if (completed) {
          setState(() {});
        }
        if (!completed) scheduleNext();
      }, Priority.idle));
    }
    scheduleNext();
  }

  void _markCleanOverlayReady(Uint8List bytes) {
    if (_cleanOverlayReady || !identical(_cleanOverlayBytes, bytes)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _cleanOverlayReady ||
          !identical(_cleanOverlayBytes, bytes)) {
        return;
      }
      setState(() => _cleanOverlayReady = true);
    });
  }

  void _peekSource(String blockKey) {
    _sourcePeekTimer?.cancel();
    setState(() => _hiddenBlockKey = blockKey);
    _sourcePeekTimer = Timer(_sourcePeekDuration, () {
      if (mounted) setState(() => _hiddenBlockKey = null);
    });
  }

  bool peekSourceAt(Offset globalPosition) {
    final painter = _painter;
    final box = context.findRenderObject();
    if (painter == null || box is! RenderBox || !box.attached) return false;
    final position = box.globalToLocal(globalPosition);
    if (!(Offset.zero & box.size).contains(position)) return false;
    final blockKey = painter.blockAt(position);
    if (blockKey == null) return false;
    _peekSource(blockKey);
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reader = context.reader;
    if (identical(_reader, reader)) return;
    _reader?._translationLayers.remove(this);
    _reader = reader.._translationLayers.add(this);
  }

  @override
  void didUpdateWidget(covariant _ReaderTranslationLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageIndex == widget.pageIndex) return;
    _sourcePeekTimer?.cancel();
    _hiddenBlockKey = null;
    _painter = null;
    _layoutGeneration++;
    _layoutScheduled = false;
    _layoutTaskPainter = null;
    _layoutTaskSize = null;
    _cleanOverlayBytes = null;
    _cleanOverlayReady = false;
  }

  @override
  void dispose() {
    _sourcePeekTimer?.cancel();
    _layoutGeneration++;
    _reader?._translationLayers.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reader = context.reader;
    if (!reader.translationSession.enabled) {
      _cancelLayoutPreparation();
      _painter = null;
      return widget.child;
    }
    final identity = reader.translationIdentity(widget.pageIndex);
    final pageState = reader.translationSession.listenable(identity);
    final fontScaleState = reader.translationSession.fontScaleListenable;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge([pageState, fontScaleState]),
                builder: (context, _) {
                  final state = pageState.value;
                  final fontScale = fontScaleState.value;
                  final artifact = state.artifact;
                  if (state.phase != ComicTranslationPhase.ready ||
                      artifact == null) {
                    _cancelLayoutPreparation();
                    _painter = null;
                    return const SizedBox();
                  }
                  final background = context.colorScheme.surface.withValues(
                    alpha: 0.88,
                  );
                  final foreground = context.colorScheme.onSurface;
                  final cleanOverlayPng = state.cleanOverlayPng;
                  if (!identical(_cleanOverlayBytes, cleanOverlayPng)) {
                    _cleanOverlayBytes = cleanOverlayPng;
                    _cleanOverlayReady = false;
                  }
                  final showCleanOverlay =
                      cleanOverlayPng != null &&
                      _cleanOverlayReady &&
                      _hiddenBlockKey == null;
                   final current = _painter;
                   final layoutCompatible = current != null &&
                       current.artifact == artifact &&
                       current.alignment == widget.alignment &&
                       current.fontScale == fontScale;
                  final painter = layoutCompatible &&
                          current.background == background &&
                          current.foreground == foreground &&
                          current.hasCleanOverlay == showCleanOverlay &&
                          current.hiddenBlockKey == _hiddenBlockKey
                      ? current
                      : _ComicTranslationPainter(
                          artifact: artifact,
                          fit: BoxFit.contain,
                          alignment: widget.alignment,
                          background: background,
                          foreground: foreground,
                          fontScale: fontScale,
                          hasCleanOverlay: showCleanOverlay,
                          hiddenBlockKey: _hiddenBlockKey,
                          layoutCache: layoutCompatible
                              ? current.layoutCache
                              : _TranslationLayoutCache(),
                        );
                  _painter = painter;
                  return LayoutBuilder(builder: (context, constraints) {
                    final size = constraints.biggest;
                    if (!painter.isPreparedFor(size)) {
                      _scheduleLayoutPreparation(painter, size);
                    }
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        if (cleanOverlayPng != null &&
                            _hiddenBlockKey == null)
                          ClipPath(
                            clipper: _TranslationMaskClipper(
                              artifact: artifact,
                              alignment: widget.alignment,
                              layoutCache: painter.layoutCache,
                            ),
                            child: Image.memory(
                              cleanOverlayPng,
                              fit: BoxFit.contain,
                              alignment: widget.alignment,
                              filterQuality: FilterQuality.medium,
                              frameBuilder: (context, child, frame, _) {
                                if (frame != null) {
                                  _markCleanOverlayReady(cleanOverlayPng);
                                }
                                return child;
                              },
                            ),
                          ),
                        CustomPaint(painter: painter),
                      ],
                    );
                  });
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TranslationMaskClipper extends CustomClipper<Path> {
  final ComicTranslationArtifact artifact;
  final Alignment alignment;
  final _TranslationLayoutCache layoutCache;

  _TranslationMaskClipper({
    required this.artifact,
    required this.alignment,
    required this.layoutCache,
  }) : super(reclip: layoutCache.repaint);

  @override
  Path getClip(Size size) {
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(artifact.imageWidth.toDouble(), artifact.imageHeight.toDouble()),
      size,
    );
    final imageRect = alignment.inscribe(fitted.destination, Offset.zero & size);
    final path = Path();
    for (final region in artifact.regions) {
      if (region.translatedText.trim().isEmpty ||
          !layoutCache.preparedRegionIds.contains(region.ocrRegionId)) {
        continue;
      }
      final masks = region.sourceMaskPolygons.isEmpty
          ? [region.polygon]
          : region.sourceMaskPolygons;
      for (final polygon in masks) {
        if (polygon.length < 3) continue;
        path.addPolygon(polygon.map((point) => Offset(
          imageRect.left + point.x * imageRect.width,
          imageRect.top + point.y * imageRect.height,
        )).toList(), true);
      }
    }
    return path;
  }

  @override
  bool shouldReclip(_TranslationMaskClipper oldClipper) =>
      oldClipper.artifact != artifact ||
      oldClipper.alignment != alignment ||
      !identical(oldClipper.layoutCache, layoutCache);
}
