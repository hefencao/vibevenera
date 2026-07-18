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
        if (!painter.prepareNext(size)) {
          scheduleNext();
          return;
        }
        _layoutScheduled = false;
        setState(() {});
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
                      return const SizedBox();
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

  const _TranslationMaskClipper({
    required this.artifact,
    required this.alignment,
  });

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
      if (region.translatedText.trim().isEmpty) continue;
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
      oldClipper.artifact != artifact || oldClipper.alignment != alignment;
}

class _TranslationLayoutCache {
  final Map<String, _TranslationLayoutPlan> plans = {};
  final Set<String> skipped = {};
  final Map<String, _VerticalGlyphMetrics> verticalMetrics = {};
  final Map<String, double> horizontalWidthFactors = {};
  List<_TranslationLayoutBlock>? blocks;
  Rect? imageRect;
  _TranslationLayoutSearch? search;
}

class _ComicTranslationPainter extends CustomPainter {
  final ComicTranslationArtifact artifact;
  final BoxFit fit;
  final Alignment alignment;
  final Color background;
  final Color foreground;
  final double fontScale;
  final bool hasCleanOverlay;
  final String? hiddenBlockKey;
  final _TranslationLayoutCache layoutCache;
  final List<_TranslationHitRegion> _hitRegions = [];
  Map<String, _TranslationLayoutPlan> get _layoutPlans => layoutCache.plans;
  Map<String, _VerticalGlyphMetrics> get _verticalMetrics =>
      layoutCache.verticalMetrics;
  List<_TranslationLayoutBlock>? get _blocks => layoutCache.blocks;
  set _blocks(List<_TranslationLayoutBlock>? value) => layoutCache.blocks = value;
  Rect? get _layoutImageRect => layoutCache.imageRect;
  set _layoutImageRect(Rect? value) => layoutCache.imageRect = value;

  _ComicTranslationPainter({
    required this.artifact,
    required this.fit,
    required this.alignment,
    required this.background,
    required this.foreground,
    required this.fontScale,
    required this.hasCleanOverlay,
    required this.hiddenBlockKey,
    required this.layoutCache,
  });

  Rect _imageRect(Size size) {
    final sourceSize = Size(
      artifact.imageWidth.toDouble(),
      artifact.imageHeight.toDouble(),
    );
    final fitted = applyBoxFit(fit, sourceSize, size);
    return alignment.inscribe(fitted.destination, Offset.zero & size);
  }

  void _syncLayoutSize(Size size) {
    final imageRect = _imageRect(size);
    if (_layoutImageRect == imageRect) return;
    _layoutImageRect = imageRect;
    _layoutPlans.clear();
    layoutCache.skipped.clear();
    layoutCache.search = null;
  }

  bool isPreparedFor(Size size) {
    if (_layoutImageRect != _imageRect(size)) return false;
    return _layoutPlans.length + layoutCache.skipped.length ==
        _layoutBlocks().length;
  }

  bool prepareNext(Size size) {
    _syncLayoutSize(size);
    final imageRect = _layoutImageRect!;
    final pending = layoutCache.search;
    if (pending != null) {
      if (!pending.step()) return false;
      _layoutPlans[pending.block.key] = pending.plan!;
      layoutCache.search = null;
      return isPreparedFor(size);
    }
    for (final block in _layoutBlocks()) {
      if (_layoutPlans.containsKey(block.key) ||
          layoutCache.skipped.contains(block.key)) {
        continue;
      }
      final geometry = _blockGeometry(block, imageRect);
      if (geometry == null) {
        layoutCache.skipped.add(block.key);
      } else {
        layoutCache.search = _TranslationLayoutSearch(
          this,
          block,
          geometry.bounds,
          geometry.regionBounds,
          imageRect,
          geometry.bubblePath != null,
        );
        return false;
      }
      return isPreparedFor(size);
    }
    return true;
  }

  _TranslationBlockGeometry? _blockGeometry(
    _TranslationLayoutBlock block,
    Rect imageRect,
  ) {
    final regionBounds = block.regions
        .map((region) => _displayBounds(region.bounds, imageRect))
        .toList();
    final sourceBounds = regionBounds
        .reduce((value, next) => value.expandToInclude(next));
    final bubble = _blockBubble(block);
    final bubblePoints = bubble == null
        ? null
        : _displayPolygon(bubble, imageRect);
    final bubblePath = bubblePoints == null
        ? null
        : (Path()..addPolygon(bubblePoints, true));
    final sourceFontSize = _sourceFontSize(block, regionBounds);
    final bounds = bubblePath == null
        ? _openBubbleBounds(sourceBounds, sourceFontSize, imageRect)
        : _safeBubbleBounds(
            bubblePath,
            _bounds(bubblePoints!),
            sourceBounds,
            sourceFontSize,
          ).intersect(imageRect);
    if (bounds.width < 3 || bounds.height < 3) return null;
    return _TranslationBlockGeometry(
      regionBounds,
      bounds,
      bubblePath,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    _hitRegions.clear();
    _syncLayoutSize(size);
    final imageRect = _layoutImageRect!;
    for (final block in _layoutBlocks()) {
      if (block.key == hiddenBlockKey) continue;
      final geometry = _blockGeometry(block, imageRect);
      final plan = _layoutPlans[block.key];
      if (geometry == null || plan == null) continue;
      final bounds = geometry.bounds;
      final bubblePath = geometry.bubblePath;
      _hitRegions.add(_TranslationHitRegion(
        block.key,
        bubblePath ?? (Path()..addRect(bounds)),
      ));
      if (!hasCleanOverlay) {
        for (final region in block.regions) {
          final paint = Paint()..color = _regionBackground(region.region);
          final masks = region.region.sourceMaskPolygons.isEmpty
              ? [region.region.polygon]
              : region.region.sourceMaskPolygons;
          for (final polygon in masks) {
            if (polygon.length < 3) continue;
            canvas.drawPath(
              Path()..addPolygon(_displayPolygon(polygon, imageRect), true),
              paint,
            );
          }
        }
      }
      canvas.save();
      if (bubblePath != null) canvas.clipPath(bubblePath);
      for (final lane in plan.lanes) {
        final region = lane.regions.first.region;
        final fill = _regionForeground(region);
        final outline = _regionBackground(region);
        if (block.orientation == ComicTextOrientation.vertical) {
          _paintVertical(
            canvas,
            lane,
            plan.fontSize,
            fill,
            outline,
          );
        } else {
          _paintHorizontal(
            canvas,
            lane.text,
            lane.bounds,
            plan.fontSize,
            fill,
            outline,
          );
        }
      }
      canvas.restore();
    }
  }

  String _bandText(List<_TranslationLayoutRegion> band) {
    final language = artifact.targetLanguage
        .split(RegExp('[-_]'))
        .first
        .toLowerCase();
    final separator = {'zh', 'ja', 'ko'}.contains(language) ? '' : ' ';
    return band
        .map((region) => _visibleTranslation(region.region.translatedText))
        .where((text) => text.isNotEmpty)
        .join(separator);
  }

  String _visibleTranslation(String text) =>
      text.replaceAll(comicTranslationBreakMarker, '').trim();

  double _dominantFontSize(List<double> sorted) {
    var bestStart = 0;
    var bestEnd = 1;
    final median = sorted[sorted.length ~/ 2];
    for (var start = 0; start < sorted.length; start++) {
      var end = start + 1;
      while (end < sorted.length && sorted[end] <= sorted[start] * 1.35) {
        end++;
      }
      final candidateMiddle = sorted[(start + end) ~/ 2];
      final bestMiddle = sorted[(bestStart + bestEnd) ~/ 2];
      if (end - start > bestEnd - bestStart ||
          end - start == bestEnd - bestStart &&
              (candidateMiddle - median).abs() < (bestMiddle - median).abs()) {
        bestStart = start;
        bestEnd = end;
      }
    }
    return sorted[(bestStart + bestEnd) ~/ 2];
  }

  double _sourceFontSize(
    _TranslationLayoutBlock block,
    List<Rect> regionBounds,
  ) {
    final values = List.generate(block.regions.length, (index) {
      final characters = _characters(block.regions[index].region.sourceText);
      final bounds = regionBounds[index];
      return math.sqrt(bounds.width * bounds.height / characters);
    })..sort();
    return _dominantFontSize(values);
  }

  List<_TranslationLayoutOption> _layoutOptions(
    _TranslationLayoutBlock block,
    Rect bounds,
    List<Rect> regionBounds,
    Rect imageRect,
    bool insideBubble,
  ) {
    final sourceBounds = regionBounds
        .reduce((value, next) => value.expandToInclude(next));
    final sourceCenter = _sourceCenter(block, imageRect, sourceBounds);
    final anchored = Rect.fromCenter(
      center: sourceCenter,
      width: sourceBounds.width,
      height: sourceBounds.height,
    ).intersect(bounds);
    final sourceFontSize = _sourceFontSize(block, regionBounds);
    final start = anchored
        .inflate(math.max(3, sourceFontSize * .35))
        .intersect(bounds);
    final text = _laneText(block.bands);
    final breakHints = _breakHints(block.bands, text);
    final sourceBandCharacters = block.bands.map((band) => band.fold(
      0,
      (count, region) => count + _characters(region.region.sourceText),
    )).toList();
    final targetBandCharacters = block.bands.map((band) =>
        _characters(_bandText(band))).toList();
    final factors = insideBubble
        ? const [0.0, .28, .55, .8, 1.0]
        : const [0.0];
    return factors.map((factor) {
      final laneBounds = Rect.lerp(start, bounds, factor)!;
      final diagonal = math.sqrt(bounds.width * bounds.width +
          bounds.height * bounds.height);
      final positionPenalty = (laneBounds.center - sourceCenter).distance;
      return _TranslationLayoutOption(
        [_TranslationTextLane(
          block.regions,
          text,
          laneBounds,
          breakHints,
          sourceBandCharacters,
          targetBandCharacters,
        )],
        positionPenalty / diagonal,
      );
    }).toList();
  }

  Offset _sourceCenter(
    _TranslationLayoutBlock block,
    Rect imageRect,
    Rect sourceBounds,
  ) {
    var x = 0.0;
    var y = 0.0;
    var total = 0.0;
    for (final layout in block.regions) {
      final polygon = _displayPolygon(layout.region.polygon, imageRect);
      final center = polygon.fold(Offset.zero, (sum, point) => sum + point) /
          polygon.length.toDouble();
      final weight = _characters(layout.region.sourceText).toDouble();
      x += center.dx * weight;
      y += center.dy * weight;
      total += weight;
    }
    final weighted = Offset(x / total, y / total);
    return Offset.lerp(sourceBounds.center, weighted, .35)!;
  }

  String _laneText(List<List<_TranslationLayoutRegion>> bands) => bands
      .map(_bandText)
      .where((text) => text.isNotEmpty)
      .join(_targetWordSeparator);

  List<_TranslationBreakHint> _breakHints(
    List<List<_TranslationLayoutRegion>> bands,
    String text,
  ) {
    var offset = 0;
    final weights = <int, double>{};
    void add(int position, double weight) {
      if (position > 0 && position < text.runes.length) {
        weights[position] = math.max(weights[position] ?? 0, weight);
      }
    }
    for (var i = 0; i < bands.length; i++) {
      final band = bands[i];
      for (var j = 0; j < band.length; j++) {
        final region = band[j].region;
        var visible = 0;
        for (final rune in region.translatedText.trim().runes) {
          final glyph = String.fromCharCode(rune);
          if (glyph == comicTranslationBreakMarker) {
            add(offset + visible, 1.55);
          } else {
            visible++;
          }
        }
        offset += visible;
        if (j < band.length - 1) {
          add(offset, _endsStrongPunctuation(region.sourceText) ? 1.35 : .35);
          offset += _targetWordSeparator.runes.length;
        }
      }
      if (i < bands.length - 1) {
        final source = band.map((region) => region.region.sourceText).join();
        final target = _bandText(band);
        add(offset, _endsStrongPunctuation(source) ||
            _endsStrongPunctuation(target) ? 1.5 : 1.1);
      }
      offset += _targetWordSeparator.runes.length;
    }
    final glyphs = text.runes.map(String.fromCharCode).toList();
    for (var i = 0; i < glyphs.length - 1; i++) {
      if (_strongPunctuation.contains(glyphs[i])) {
        var end = i + 1;
        while (end < glyphs.length &&
            (_strongPunctuation.contains(glyphs[end]) ||
                _closingBrackets.contains(glyphs[end]))) {
          end++;
        }
        add(end, 1.65);
        i = end - 1;
        continue;
      }
      if (_weakPunctuation.contains(glyphs[i])) add(i + 1, .65);
    }
    return weights.entries
        .map((entry) => _TranslationBreakHint(entry.key, entry.value))
        .toList();
  }

  bool _endsStrongPunctuation(String text) {
    final glyphs = text.trim().runes.map(String.fromCharCode).toList();
    for (final glyph in glyphs.reversed) {
      if (_closingBrackets.contains(glyph)) continue;
      return _strongPunctuation.contains(glyph);
    }
    return false;
  }

  static const _strongPunctuation = {
    '。', '！', '？', '!', '?', '…', '‼', '⁉', '‽',
  };
  static const _weakPunctuation = {'，', '、', ',', '；', ';', '：', ':'};
  static const _closingBrackets = {
    '）', ')', '】', '》', '」', '』', '”', '’',
  };
  static const _closingPunctuation = {
    ..._strongPunctuation,
    ..._weakPunctuation,
    ..._closingBrackets,
  };
  static const _openingPunctuation = {
    '（', '(', '【', '《', '「', '『', '“', '‘',
  };

  String get _targetWordSeparator {
    final language = artifact.targetLanguage
        .split(RegExp('[-_]'))
        .first
        .toLowerCase();
    return {'zh', 'ja', 'ko'}.contains(language) ? '' : ' ';
  }

  _MeasuredTranslationLayout _measureLayout(
    _TranslationLayoutBlock block,
    _TranslationLayoutOption option,
    double fontSize,
  ) {
    var area = 0.0;
    var lineCount = 0;
    var sentencePenalty = 0.0;
    var orphanPenalty = 0.0;
    var flowPenalty = 0.0;
    Rect? contentBounds;
    for (final lane in option.lanes) {
      if (block.orientation == ComicTextOrientation.vertical) {
        final glyphs = _verticalGlyphs(lane.text);
        final metrics = _verticalGlyphMetrics(glyphs);
        final layout = _verticalLayout(lane, fontSize, metrics);
        if (!layout.fits) {
          return const _MeasuredTranslationLayout(
            false, 0, 0, 0, 0, 0, Rect.zero,
          );
        }
        area += glyphs.length * layout.cellWidth * layout.cellHeight;
        final laneContent = Rect.fromCenter(
          center: lane.bounds.center,
          width: layout.columnLengths.length * layout.cellWidth,
          height: layout.columnLengths.reduce(math.max) * layout.cellHeight,
        );
        contentBounds = contentBounds?.expandToInclude(laneContent) ??
            laneContent;
        lineCount += layout.columnLengths.length;
        sentencePenalty += layout.breakPenalty;
        orphanPenalty += layout.orphanPenalty;
        flowPenalty += _flowPenalty(
          layout.columnLengths,
          _preferredFlowWeights(lane, layout.columnLengths.length),
        );
      } else {
        final paragraph = _paragraph(
          lane.text,
          fontSize,
          lane.bounds.width,
          fillColor: const Color(0xff000000),
          outline: const Color(0xffffffff),
        );
        if (paragraph.width > lane.bounds.width ||
            paragraph.height > lane.bounds.height) {
          return const _MeasuredTranslationLayout(
            false, 0, 0, 0, 0, 0, Rect.zero,
          );
        }
        final metrics = paragraph.computeLineMetrics();
        final contentWidth = metrics.map((line) => line.width).reduce(math.max);
        area += contentWidth * paragraph.height;
        final laneContent = Rect.fromCenter(
          center: lane.bounds.center,
          width: contentWidth,
          height: paragraph.height,
        );
        contentBounds = contentBounds?.expandToInclude(laneContent) ??
            laneContent;
        lineCount += metrics.length;
        flowPenalty += _flowPenalty(
          _horizontalFlowCounts(
            lane.text.runes.map(String.fromCharCode).toList(),
            metrics.map((line) => line.width).toList(),
            fontSize,
          ),
          _preferredFlowWeights(lane, metrics.length),
        );
      }
    }
    return _MeasuredTranslationLayout(
      true,
      area,
      lineCount,
      sentencePenalty,
      orphanPenalty,
      flowPenalty,
      contentBounds!,
    );
  }

  double _extentPenalty(
    ComicTextOrientation orientation,
    Rect sourceBounds,
    _TranslationTextLane lane,
    Rect targetBounds,
  ) {
    final sourceFlow = lane.sourceBandCharacters.reduce(math.max);
    final targetFlow = lane.targetBandCharacters.reduce(math.max);
    final flowRatio = targetFlow / sourceFlow;
    final expected = Rect.fromCenter(
      center: sourceBounds.center,
      width: orientation == ComicTextOrientation.vertical
          ? sourceBounds.width
          : sourceBounds.width * flowRatio,
      height: orientation == ComicTextOrientation.vertical
          ? sourceBounds.height * flowRatio
          : sourceBounds.height,
    );
    return ((targetBounds.left - expected.left).abs() +
        (targetBounds.top - expected.top).abs() +
        (targetBounds.right - expected.right).abs() +
        (targetBounds.bottom - expected.bottom).abs()) /
        (expected.width + expected.height);
  }

  List<double> _preferredFlowWeights(
    _TranslationTextLane lane,
    int count,
  ) {
    final source = _resampleWeights(lane.sourceBandCharacters, count);
    final target = _resampleWeights(lane.targetBandCharacters, count);
    return List.generate(count, (index) =>
        source[index] * .55 + target[index] * .45);
  }

  List<int> _horizontalFlowCounts(
    List<String> glyphs,
    List<double> lineWidths,
    double fontSize,
  ) {
    final key = glyphs.join();
    final widthFactor = layoutCache.horizontalWidthFactors.putIfAbsent(
      key,
      () => glyphs.fold(0.0, (width, glyph) => width +
          _glyph(
            glyph,
            100,
            fillColor: const Color(0xff000000),
            outline: const Color(0xffffffff),
          ).width) / glyphs.length / 100,
    );
    final averageWidth = widthFactor * fontSize;
    return lineWidths.map((width) =>
        math.max(1, (width / averageWidth).round())).toList();
  }

  List<double> _resampleWeights(List<int> source, int count) {
    final total = source.reduce((sum, value) => sum + value).toDouble();
    final sourceWidth = 1 / source.length;
    return List.generate(count, (index) {
      final start = index / count;
      final end = (index + 1) / count;
      var weight = 0.0;
      for (var sourceIndex = 0; sourceIndex < source.length; sourceIndex++) {
        final sourceStart = sourceIndex * sourceWidth;
        final sourceEnd = sourceStart + sourceWidth;
        final overlap = math.max(
          0,
          math.min(end, sourceEnd) - math.max(start, sourceStart),
        );
        weight += overlap * source[sourceIndex] / total / sourceWidth;
      }
      return weight;
    });
  }

  int _characters(String text) =>
      text
          .replaceAll(comicTranslationBreakMarker, '')
          .replaceAll(RegExp(r'\s'), '')
          .runes
          .length
          .clamp(1, 1000);

  Rect _openBubbleBounds(
    Rect sourceBounds,
    double sourceFontSize,
    Rect imageRect,
  ) => sourceBounds
      .inflate(math.max(3, sourceFontSize * 0.7))
      .intersect(imageRect);

  Rect _safeBubbleBounds(
    Path bubble,
    Rect bubbleBounds,
    Rect sourceBounds,
    double sourceFontSize,
  ) {
    Rect candidateAt(Offset center) {
      final width = 2.0 * math.min(
        center.dx - bubbleBounds.left,
        bubbleBounds.right - center.dx,
      );
      final height = 2.0 * math.min(
        center.dy - bubbleBounds.top,
        bubbleBounds.bottom - center.dy,
      );
      var candidate = Rect.fromCenter(
        center: center,
        width: math.max(0, width),
        height: math.max(0, height),
      );
      while (candidate.width >= 12 &&
          candidate.height >= 12 &&
          !_rectFitsBubble(bubble, candidate)) {
        candidate = Rect.fromCenter(
          center: center,
          width: candidate.width * 0.94,
          height: candidate.height * 0.94,
        );
      }
      return candidate;
    }
    final centers = [bubbleBounds.center, sourceBounds.center]
        .where(bubble.contains)
        .toList();
    if (centers.isEmpty) centers.add(sourceBounds.center);
    final candidates = centers.map(candidateAt).toList();
    final candidate = candidates.reduce((a, b) =>
        a.width * a.height >= b.width * b.height ? a : b);
    return candidate.deflate(math.max(2, sourceFontSize * 0.12));
  }

  bool _rectFitsBubble(Path path, Rect rect) => [
    rect.topCenter,
    rect.centerLeft,
    rect.center,
    rect.centerRight,
    rect.bottomCenter,
    Offset(rect.left + rect.width * 0.16, rect.top + rect.height * 0.16),
    Offset(rect.right - rect.width * 0.16, rect.top + rect.height * 0.16),
    Offset(rect.left + rect.width * 0.16, rect.bottom - rect.height * 0.16),
    Offset(rect.right - rect.width * 0.16, rect.bottom - rect.height * 0.16),
  ].every(path.contains);

  void _paintHorizontal(
    Canvas canvas,
    String text,
    Rect bounds,
    double fontSize,
    Color fillColor,
    Color outline,
  ) {
    final fill = _paragraph(
      text,
      fontSize,
      bounds.width,
      fillColor: fillColor,
      outline: outline,
    );
    final offset = Offset(
      bounds.left + (bounds.width - fill.width) / 2,
      bounds.top + (bounds.height - fill.height) / 2,
    );
    _paragraph(
      text,
      fontSize,
      bounds.width,
      stroke: true,
      fillColor: fillColor,
      outline: outline,
    ).paint(canvas, offset);
    fill.paint(canvas, offset);
  }

  void _paintVertical(
    Canvas canvas,
    _TranslationTextLane lane,
    double fontSize,
    Color fillColor,
    Color outline,
  ) {
    final glyphs = _verticalGlyphs(lane.text);
    if (glyphs.isEmpty) return;
    final glyphMetrics = _verticalGlyphMetrics(glyphs);
    final layout = _verticalLayout(lane, fontSize, glyphMetrics);
    final startX = lane.bounds.center.dx +
        layout.columnLengths.length * layout.cellWidth / 2;
    var glyphIndex = 0;
    for (var column = 0; column < layout.columnLengths.length; column++) {
      final columnLength = layout.columnLengths[column];
      final startY = lane.bounds.center.dy -
          columnLength * layout.cellHeight / 2;
      for (var row = 0; row < columnLength; row++) {
        final center = Offset(
          startX - (column + 0.5) * layout.cellWidth,
          startY + (row + 0.5) * layout.cellHeight,
        );
        final glyph = glyphs[glyphIndex++];
        final fill = _glyph(
          glyph,
          fontSize,
          fillColor: fillColor,
          outline: outline,
        );
        final offset = _glyphOffset(fill, center);
        _glyph(
          glyph,
          fontSize,
          stroke: true,
          fillColor: fillColor,
          outline: outline,
        ).paint(canvas, offset);
        fill.paint(canvas, offset);
      }
    }
  }

  Offset _glyphOffset(TextPainter painter, Offset center) {
    final metrics = painter.computeLineMetrics().first;
    final glyphCenter =
        metrics.baseline + (metrics.descent - metrics.ascent) / 2;
    return Offset(center.dx - painter.width / 2, center.dy - glyphCenter);
  }

  _VerticalGlyphMetrics _verticalGlyphMetrics(
    List<String> glyphs,
  ) => _verticalMetrics.putIfAbsent(glyphs.join(), () {
    const sampleSize = 100.0;
    var width = 0.0;
    var height = 0.0;
    for (final glyph in glyphs) {
      final painter = _glyph(
        glyph,
        sampleSize,
        fillColor: const Color(0xff000000),
        outline: const Color(0xffffffff),
      );
      width = math.max(width, painter.width);
      height = math.max(height, painter.height);
    }
    return _VerticalGlyphMetrics(width / sampleSize, height / sampleSize);
  });

  List<String> _verticalGlyphs(String text) => text
      .replaceAll(RegExp(r'(?:…+|⋯+|︙+|⋮+|・{2,}|\.{3,})'), '︙')
      .runes
      .map(String.fromCharCode)
      .toList();

  _VerticalTextLayout _verticalLayout(
    _TranslationTextLane lane,
    double fontSize,
    _VerticalGlyphMetrics glyphMetrics,
  ) {
    final glyphs = _verticalGlyphs(lane.text);
    final cellWidth = fontSize * glyphMetrics.widthFactor * 1.08;
    final cellHeight = fontSize * glyphMetrics.heightFactor * 1.04;
    final rows = math.max(1, (lane.bounds.height / cellHeight).floor());
    final columnCapacity = (lane.bounds.width / cellWidth).floor();
    final minimumColumns = (glyphs.length / rows).ceil();
    if (cellHeight > lane.bounds.height || minimumColumns > columnCapacity) {
      return _VerticalTextLayout(
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        rows: rows,
        columnLengths: const [],
        fits: false,
        breakPenalty: 0,
        orphanPenalty: 0,
      );
    }
    _VerticalTextLayout? best;
    var bestScore = double.infinity;
    final maximumColumns = math.min(columnCapacity, glyphs.length);
    for (var columns = minimumColumns; columns <= maximumColumns; columns++) {
      final lengths = _verticalPartition(glyphs, lane, rows, columns);
      final breakPenalty = _breakPenalty(
        _columnBoundaries(lengths),
        lane.breakHints,
        glyphs,
        glyphs.length / columns,
      );
      final orphanPenalty = _orphanPenalty(lengths, rows);
      final sourceCharacters = lane.sourceBandCharacters.reduce(
        (sum, value) => sum + value,
      );
      final lengthRatio = glyphs.length / sourceCharacters;
      final topologyPenalty =
          (columns - lane.sourceBandCharacters.length).abs() /
              (1 + math.max(0, lengthRatio - 1) * .25);
      final flowPenalty = _flowPenalty(
        lengths,
        _preferredFlowWeights(lane, columns),
      );
      final score = topologyPenalty * 1.3 + flowPenalty * .9 +
          breakPenalty * .8 + orphanPenalty * 1.1;
      if (score < bestScore) {
        bestScore = score;
        best = _VerticalTextLayout(
          cellWidth: cellWidth,
          cellHeight: cellHeight,
          rows: rows,
          columnLengths: lengths,
          fits: true,
          breakPenalty: breakPenalty,
          orphanPenalty: orphanPenalty,
        );
      }
    }
    return best!;
  }

  List<int> _verticalPartition(
    List<String> glyphs,
    _TranslationTextLane lane,
    int rows,
    int columns,
  ) {
    final expected = _preferredFlowWeights(lane, columns);
    var states = <int, _VerticalPartition>{
      0: const _VerticalPartition(0, []),
    };
    for (var column = 0; column < columns; column++) {
      final next = <int, _VerticalPartition>{};
      final remainingColumns = columns - column - 1;
      for (final entry in states.entries) {
        final maximumEnd = math.min(
          entry.key + rows,
          glyphs.length - remainingColumns,
        );
        for (var end = entry.key + 1; end <= maximumEnd; end++) {
          final length = end - entry.key;
          var cost = (length / glyphs.length - expected[column]).abs() *
              columns;
          if (end < glyphs.length) {
            cost += _boundaryChoicePenalty(
              end,
              lane.breakHints,
              glyphs,
              rows,
            );
          }
          if (length == 1) cost += .8;
          final candidate = _VerticalPartition(
            entry.value.cost + cost,
            [...entry.value.lengths, length],
          );
          final previous = next[end];
          if (previous == null || candidate.cost < previous.cost) {
            next[end] = candidate;
          }
        }
      }
      states = next;
    }
    return states[glyphs.length]!.lengths;
  }

  double _boundaryChoicePenalty(
    int position,
    List<_TranslationBreakHint> hints,
    List<String> glyphs,
    int rows,
  ) {
    var penalty = 0.0;
    if (hints.isNotEmpty) {
      penalty = hints.map((hint) =>
          (position - hint.offset).abs() / rows +
          (1 - hint.weight / 1.65) * .3).reduce(math.min);
    }
    if (_closingPunctuation.contains(glyphs[position]) ||
        _openingPunctuation.contains(glyphs[position - 1])) {
      penalty += 1.4;
    }
    return penalty;
  }

  List<int> _columnBoundaries(List<int> lengths) {
    var offset = 0;
    return lengths.take(lengths.length - 1).map((length) {
      offset += length;
      return offset;
    }).toList();
  }

  double _breakPenalty(
    List<int> boundaries,
    List<_TranslationBreakHint> hints,
    List<String> glyphs,
    double lineLength,
  ) {
    if (boundaries.isEmpty) return 0;
    var penalty = 0.0;
    var weight = 0.0;
    for (final hint in hints) {
      final distance = boundaries.map((boundary) =>
          (boundary - hint.offset).abs()).reduce(math.min);
      penalty += math.min(1, distance / lineLength) * hint.weight;
      weight += hint.weight;
    }
    for (final boundary in boundaries) {
      if (_closingPunctuation.contains(glyphs[boundary]) ||
          _openingPunctuation.contains(glyphs[boundary - 1])) {
        penalty += 1.4;
        weight += 1;
      }
    }
    return weight == 0 ? 0 : penalty / weight;
  }

  double _orphanPenalty(List<int> lengths, int rows) => lengths.fold(
    0.0,
    (penalty, length) => penalty +
        (length == 1 ? 1 : length == 2 && rows >= 5 ? .25 : 0),
  );

  double _flowPenalty(List<int> actual, List<double> expected) {
    final total = actual.reduce((sum, count) => sum + count).toDouble();
    return List.generate(actual.length, (index) =>
        (actual[index] / total - expected[index]).abs()).reduce(
          (sum, value) => sum + value,
        ) / actual.length;
  }

  TextPainter _paragraph(
    String text,
    double fontSize,
    double width, {
    bool stroke = false,
    required Color fillColor,
    required Color outline,
  }) => TextPainter(
      text: TextSpan(
        text: text,
        style: _textStyle(fontSize, stroke, fillColor, outline),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      locale: _targetLocale,
    )..layout(maxWidth: width);

  TextPainter _glyph(
    String text,
    double fontSize, {
    bool stroke = false,
    required Color fillColor,
    required Color outline,
  }) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: _textStyle(fontSize, stroke, fillColor, outline),
        ),
        textDirection: TextDirection.ltr,
        locale: _targetLocale,
      )..layout();

  TextStyle _textStyle(
    double fontSize,
    bool stroke,
    Color fillColor,
    Color outline,
  ) => TextStyle(
    color: stroke ? null : fillColor,
    foreground: stroke
        ? (Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = math.max(0.55, fontSize * 0.045))
        : null,
    fontSize: fontSize,
    height: 1.05,
    fontWeight: FontWeight.w500,
  );

  Color _regionBackground(ComicTranslatedRegion region) =>
      region.backgroundArgb == null
          ? background.withValues(alpha: 1)
          : Color(region.backgroundArgb!);

  Color _regionForeground(ComicTranslatedRegion region) =>
      region.foregroundArgb == null
          ? foreground
          : Color(region.foregroundArgb!);

  List<NormalizedPoint>? _blockBubble(_TranslationLayoutBlock block) {
    List<NormalizedPoint>? best;
    var bestArea = 0.0;
    for (final region in block.regions) {
      final polygon = region.region.bubblePolygon;
      if (polygon == null) continue;
      final bounds = _bounds(
        polygon.map((point) => Offset(point.x, point.y)),
      );
      final area = bounds.width * bounds.height;
      if (area > bestArea) {
        best = polygon;
        bestArea = area;
      }
    }
    return best;
  }

  Locale? get _targetLocale => _languageLocale(artifact.targetLanguage);

  Locale? _languageLocale(String language) {
    if (language == 'auto') return null;
    final parts = language.split(RegExp('[-_]'));
    return Locale.fromSubtags(
      languageCode: parts.first,
      countryCode: parts.elementAtOrNull(1),
    );
  }

  List<_TranslationLayoutBlock> _layoutBlocks() {
    final cached = _blocks;
    if (cached != null) return cached;
    final regions = artifact.regions
        .where((region) =>
            region.translatedText.trim().isNotEmpty &&
            region.polygon.isNotEmpty)
        .map((region) => _TranslationLayoutRegion(region, _normalizedBounds(region)))
        .toList();
    final groups = <String, List<_TranslationLayoutRegion>>{};
    for (final region in regions) {
      groups.putIfAbsent(region.region.translationUnitId!, () => []).add(region);
    }
    return _blocks = groups.entries.map((entry) {
      final regions = entry.value
        ..sort((a, b) => a.region.translationUnitOrder!
            .compareTo(b.region.translationUnitOrder!));
      final bandMap = <int, List<_TranslationLayoutRegion>>{};
      for (final region in regions) {
        bandMap.putIfAbsent(region.region.translationBandIndex!, () => [])
            .add(region);
      }
      final bands = bandMap.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return _TranslationLayoutBlock(
        key: entry.key,
        regions: regions,
        orientation: regions.first.region.translationOrientation!,
        bands: bands.map((entry) => entry.value).toList(),
      );
    }).toList();
  }

  Rect _normalizedBounds(ComicTranslatedRegion region) => _bounds(
    region.polygon.map((point) => Offset(point.x, point.y)),
  );

  List<Offset> _displayPolygon(
    List<NormalizedPoint> polygon,
    Rect imageRect,
  ) => polygon.map((point) => Offset(
    imageRect.left + point.x * imageRect.width,
    imageRect.top + point.y * imageRect.height,
  )).toList();

  Rect _displayBounds(Rect bounds, Rect imageRect) => Rect.fromLTRB(
    imageRect.left + bounds.left * imageRect.width,
    imageRect.top + bounds.top * imageRect.height,
    imageRect.left + bounds.right * imageRect.width,
    imageRect.top + bounds.bottom * imageRect.height,
  );

  Rect _bounds(Iterable<Offset> points) {
    final iterator = points.iterator;
    iterator.moveNext();
    var left = iterator.current.dx;
    var top = iterator.current.dy;
    var right = left;
    var bottom = top;
    while (iterator.moveNext()) {
      final point = iterator.current;
      left = math.min(left, point.dx);
      top = math.min(top, point.dy);
      right = math.max(right, point.dx);
      bottom = math.max(bottom, point.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  String? blockAt(Offset position) {
    for (final region in _hitRegions.reversed) {
      if (region.path.contains(position)) return region.blockKey;
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant _ComicTranslationPainter oldDelegate) =>
      oldDelegate.artifact != artifact ||
      oldDelegate.fit != fit ||
      oldDelegate.alignment != alignment ||
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground ||
      oldDelegate.fontScale != fontScale ||
      oldDelegate.hasCleanOverlay != hasCleanOverlay ||
      oldDelegate.hiddenBlockKey != hiddenBlockKey;
}

class _TranslationLayoutRegion {
  final ComicTranslatedRegion region;
  final Rect bounds;

  const _TranslationLayoutRegion(this.region, this.bounds);
}

class _TranslationBlockGeometry {
  final List<Rect> regionBounds;
  final Rect bounds;
  final Path? bubblePath;

  const _TranslationBlockGeometry(
    this.regionBounds,
    this.bounds,
    this.bubblePath,
  );
}

class _TranslationLayoutBlock {
  final String key;
  final List<_TranslationLayoutRegion> regions;
  final ComicTextOrientation orientation;
  final List<List<_TranslationLayoutRegion>> bands;

  const _TranslationLayoutBlock({
    required this.key,
    required this.regions,
    required this.orientation,
    required this.bands,
  });
}

class _TranslationHitRegion {
  final String blockKey;
  final Path path;

  const _TranslationHitRegion(this.blockKey, this.path);
}

class _TranslationTextLane {
  final List<_TranslationLayoutRegion> regions;
  final String text;
  final Rect bounds;
  final List<_TranslationBreakHint> breakHints;
  final List<int> sourceBandCharacters;
  final List<int> targetBandCharacters;

  const _TranslationTextLane(
    this.regions,
    this.text,
    this.bounds,
    this.breakHints,
    this.sourceBandCharacters,
    this.targetBandCharacters,
  );
}

class _TranslationBreakHint {
  final int offset;
  final double weight;

  const _TranslationBreakHint(this.offset, this.weight);
}

class _TranslationLayoutOption {
  final List<_TranslationTextLane> lanes;
  final double positionPenalty;

  const _TranslationLayoutOption(this.lanes, this.positionPenalty);
}

class _TranslationLayoutPlan {
  final List<_TranslationTextLane> lanes;
  final double fontSize;

  const _TranslationLayoutPlan(this.lanes, this.fontSize);
}

class _TranslationLayoutSearch {
  final _ComicTranslationPainter painter;
  final _TranslationLayoutBlock block;
  final List<_TranslationLayoutOption> options;
  final int sourceCharacters;
  final double sourceArea;
  final Rect sourceBounds;
  final double preferredFont;
  int _optionIndex = 0;
  int _binaryStep = 0;
  int _fontStep = -1;
  double _low = 2;
  double _high = 2;
  double _minimumFont = 2;
  _TranslationLayoutCandidate? _best;
  _TranslationLayoutPlan? plan;

  _TranslationLayoutSearch(
    this.painter,
    this.block,
    Rect bounds,
    List<Rect> regionBounds,
    Rect imageRect,
    bool insideBubble,
  ) : options = painter._layoutOptions(
         block,
         bounds,
         regionBounds,
         imageRect,
         insideBubble,
       ),
       sourceCharacters = block.regions.fold(
         0,
         (count, region) =>
             count + painter._characters(region.region.sourceText),
       ),
       sourceArea = regionBounds.fold(
         0,
         (area, region) => area + region.width * region.height,
       ),
       sourceBounds = regionBounds.reduce(
         (value, next) => value.expandToInclude(next),
       ),
       preferredFont = painter._sourceFontSize(block, regionBounds) *
           painter.fontScale;

  bool step() {
    if (_optionIndex >= options.length) {
      plan = _best!.plan;
      return true;
    }
    final option = options[_optionIndex];
    if (_binaryStep == 0 && _fontStep < 0) {
      final extent = option.lanes.map((lane) => block.orientation ==
          ComicTextOrientation.vertical
          ? math.min(lane.bounds.width, lane.bounds.height)
          : lane.bounds.height).reduce(math.min);
      _low = 2;
      _high = math.max(_low, extent * .95);
    }
    if (_binaryStep < 9) {
      final middle = (_low + _high) / 2;
      if (painter._measureLayout(block, option, middle).fits) {
        _low = middle;
      } else {
        _high = middle;
      }
      _binaryStep++;
      return false;
    }
    if (_fontStep < 0) {
      _minimumFont = math.min(
        _low,
        math.max(2, preferredFont * .45),
      );
      _fontStep = 0;
    }
    final fontSize = _minimumFont +
        (_low - _minimumFont) * _fontStep / 24;
    final measured = painter._measureLayout(block, option, fontSize);
    if (measured.fits) _consider(option, fontSize, measured);
    _fontStep++;
    if (_fontStep <= 24) return false;
    _optionIndex++;
    _binaryStep = 0;
    _fontStep = -1;
    if (_optionIndex < options.length) return false;
    plan = _best!.plan;
    return true;
  }

  void _consider(
    _TranslationLayoutOption option,
    double fontSize,
    _MeasuredTranslationLayout measured,
  ) {
    final targetCharacters = option.lanes.fold(
      0,
      (count, lane) => count + painter._characters(lane.text),
    );
    final targetArea = sourceArea * targetCharacters / sourceCharacters;
    final densityPenalty = (math.log(measured.area / targetArea)).abs();
    final fontPenalty = (math.log(fontSize / preferredFont)).abs();
    final lengthRatio = targetCharacters / sourceCharacters;
    final topologyPenalty =
        (measured.lineCount - block.bands.length).abs() /
            (1 + math.max(0, lengthRatio - 1) * .25);
    final missingBands = math.max(0, block.bands.length - measured.lineCount);
    final unbrokenShrinkPenalty = missingBands *
        math.max(0, math.log(preferredFont / fontSize));
    final extentPenalty = painter._extentPenalty(
      block.orientation,
      sourceBounds,
      option.lanes.single,
      measured.contentBounds,
    );
    final score = densityPenalty * .7 +
        fontPenalty * .2 +
        topologyPenalty * 1.3 +
        unbrokenShrinkPenalty * 1.6 +
        measured.flowPenalty * .9 +
        measured.sentencePenalty * .8 +
        measured.orphanPenalty * 1.1 +
        extentPenalty * .9 +
        option.positionPenalty * .35;
    if (_best == null || score < _best!.score) {
      _best = _TranslationLayoutCandidate(
        _TranslationLayoutPlan(option.lanes, fontSize),
        score,
      );
    }
  }
}

class _TranslationLayoutCandidate {
  final _TranslationLayoutPlan plan;
  final double score;

  const _TranslationLayoutCandidate(this.plan, this.score);
}

class _MeasuredTranslationLayout {
  final bool fits;
  final double area;
  final int lineCount;
  final double sentencePenalty;
  final double orphanPenalty;
  final double flowPenalty;
  final Rect contentBounds;

  const _MeasuredTranslationLayout(
    this.fits,
    this.area,
    this.lineCount,
    this.sentencePenalty,
    this.orphanPenalty,
    this.flowPenalty,
    this.contentBounds,
  );
}

class _VerticalTextLayout {
  final double cellWidth;
  final double cellHeight;
  final int rows;
  final List<int> columnLengths;
  final bool fits;
  final double breakPenalty;
  final double orphanPenalty;

  const _VerticalTextLayout({
    required this.cellWidth,
    required this.cellHeight,
    required this.rows,
    required this.columnLengths,
    required this.fits,
    required this.breakPenalty,
    required this.orphanPenalty,
  });
}

class _VerticalPartition {
  final double cost;
  final List<int> lengths;

  const _VerticalPartition(this.cost, this.lengths);
}

class _VerticalGlyphMetrics {
  final double widthFactor;
  final double heightFactor;

  const _VerticalGlyphMetrics(this.widthFactor, this.heightFactor);
}
