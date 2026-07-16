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
    _cleanOverlayBytes = null;
    _cleanOverlayReady = false;
  }

  @override
  void dispose() {
    _sourcePeekTimer?.cancel();
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
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: ValueListenableBuilder<ComicTranslationPageState>(
                valueListenable:
                    reader.translationSession.listenable(identity),
                builder: (context, state, _) {
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
                  final painter = current != null &&
                          current.artifact == artifact &&
                          current.alignment == widget.alignment &&
                          current.background == background &&
                          current.foreground == foreground &&
                          current.hasCleanOverlay ==
                              showCleanOverlay &&
                          current.hiddenBlockKey == _hiddenBlockKey
                      ? current
                      : _ComicTranslationPainter(
                          artifact: artifact,
                          fit: BoxFit.contain,
                          alignment: widget.alignment,
                          background: background,
                          foreground: foreground,
                          hasCleanOverlay: showCleanOverlay,
                          hiddenBlockKey: _hiddenBlockKey,
                        );
                  _painter = painter;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (cleanOverlayPng != null &&
                          _hiddenBlockKey == null)
                        Image.memory(
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
                      CustomPaint(painter: painter),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ComicTranslationPainter extends CustomPainter {
  final ComicTranslationArtifact artifact;
  final BoxFit fit;
  final Alignment alignment;
  final Color background;
  final Color foreground;
  final bool hasCleanOverlay;
  final String? hiddenBlockKey;
  final List<_TranslationHitRegion> _hitRegions = [];

  _ComicTranslationPainter({
    required this.artifact,
    required this.fit,
    required this.alignment,
    required this.background,
    required this.foreground,
    required this.hasCleanOverlay,
    required this.hiddenBlockKey,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _hitRegions.clear();
    final sourceSize = Size(
      artifact.imageWidth.toDouble(),
      artifact.imageHeight.toDouble(),
    );
    final fitted = applyBoxFit(fit, sourceSize, size);
    final imageRect = alignment.inscribe(fitted.destination, Offset.zero & size);
    for (final block in _layoutBlocks()) {
      if (block.key == hiddenBlockKey) continue;
      final regionBounds = block.regions
          .map((region) => _displayBounds(region.bounds, imageRect))
          .toList();
      final regionFontSizes = regionBounds
          .map((bounds) => block.orientation == ComicTextOrientation.vertical
              ? bounds.width
              : bounds.height)
          .toList();
      final sortedFontSizes = [...regionFontSizes]
        ..sort();
      final originalFontSize =
          sortedFontSizes[sortedFontSizes.length ~/ 2] * 0.82;
      final sourceBounds = regionBounds
          .reduce((value, next) => value.expandToInclude(next));
      final bubble = block.useBubbleBounds ? _blockBubble(block) : null;
      final bubblePoints = bubble == null
          ? null
          : _displayPolygon(bubble, imageRect);
      final bubblePath = bubblePoints == null
          ? null
          : (Path()..addPolygon(bubblePoints, true));
      final bounds = bubblePath == null
          ? (block.independent
                  ? sourceBounds
                  : sourceBounds.inflate(math.max(2, originalFontSize * 0.25)))
              .intersect(imageRect)
          : _safeBubbleBounds(
              bubblePath,
              _bounds(bubblePoints!),
              sourceBounds,
              originalFontSize,
            ).intersect(imageRect);
      final minSide = block.independent ? 3.0 : 12.0;
      if (bounds.width < minSide || bounds.height < minSide) continue;
      _hitRegions.add(_TranslationHitRegion(
        block.key,
        bubblePath ?? (Path()..addRect(bounds)),
      ));
      final text = block.text;
      final blockBackground = _blockBackground(block);
      final blockForeground = _blockForeground(block);
      final maxFontSize = _maxTranslationFont(
        block,
        bounds,
        originalFontSize,
        bubblePath != null,
      );
      if (!hasCleanOverlay) {
        for (final region in block.regions) {
          final paint = Paint()..color = _regionBackground(region.region);
          for (final polygon in region.region.sourceMaskPolygons) {
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
      if (block.orientation == ComicTextOrientation.vertical) {
        _paintVertical(
          canvas,
          text,
          bounds,
          maxFontSize,
          blockForeground,
          blockBackground,
        );
      } else {
        _paintHorizontal(
          canvas,
          text,
          bounds,
          maxFontSize,
          blockForeground,
          blockBackground,
        );
      }
      canvas.restore();
    }
  }

  double _maxTranslationFont(
    _TranslationLayoutBlock block,
    Rect bounds,
    double originalFontSize,
    bool segmented,
  ) {
    if (!segmented) return originalFontSize;
    final sourceLength = block.regions.fold(
      0,
      (sum, region) => sum + region.region.sourceText.runes.length,
    );
    final targetLength = math.max(1, block.text.runes.length);
    final densityScale = math.sqrt(sourceLength / targetLength).clamp(0.82, 1.25);
    final bubbleLimit = block.orientation == ComicTextOrientation.vertical
        ? math.min(bounds.width, bounds.height) * 0.52
        : bounds.height * 0.55;
    return math.min(
      bubbleLimit,
      originalFontSize * densityScale * 1.2,
    );
  }

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
          !_rectInside(bubble, candidate)) {
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

  bool _rectInside(Path path, Rect rect) => [
    rect.topLeft,
    rect.topCenter,
    rect.topRight,
    rect.centerLeft,
    rect.center,
    rect.centerRight,
    rect.bottomLeft,
    rect.bottomCenter,
    rect.bottomRight,
  ].every(path.contains);

  void _paintHorizontal(
    Canvas canvas,
    String text,
    Rect bounds,
    double maxFontSize,
    Color fillColor,
    Color outline,
  ) {
    var low = 2.0;
    var high = math.max(low, maxFontSize);
    for (var i = 0; i < 7; i++) {
      final size = (low + high) / 2;
      final painter = _paragraph(
        text,
        size,
        bounds.width,
        fillColor: fillColor,
        outline: outline,
      );
      if (painter.height <= bounds.height) {
        low = size;
      } else {
        high = size;
      }
    }
    final fill = _paragraph(
      text,
      low,
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
      low,
      bounds.width,
      stroke: true,
      fillColor: fillColor,
      outline: outline,
    ).paint(canvas, offset);
    fill.paint(canvas, offset);
  }

  void _paintVertical(
    Canvas canvas,
    String text,
    Rect bounds,
    double maxFontSize,
    Color fillColor,
    Color outline,
  ) {
    final glyphs = text.runes.map(String.fromCharCode).toList();
    if (glyphs.isEmpty) return;
    final glyphMetrics = _verticalGlyphMetrics(glyphs, fillColor, outline);
    var low = 2.0;
    var high = math.max(low, maxFontSize);
    for (var i = 0; i < 7; i++) {
      final size = (low + high) / 2;
      if (_verticalLayout(glyphs.length, bounds, size, glyphMetrics).fits) {
        low = size;
      } else {
        high = size;
      }
    }
    final layout = _verticalLayout(glyphs.length, bounds, low, glyphMetrics);
    final startX = bounds.center.dx + layout.columns * layout.cellWidth / 2;
    for (var i = 0; i < glyphs.length; i++) {
      final column = i ~/ layout.rows;
      final row = i % layout.rows;
      final columnLength = math.min(
        layout.rows,
        glyphs.length - column * layout.rows,
      );
      final startY = bounds.center.dy - columnLength * layout.cellHeight / 2;
      final center = Offset(
        startX - (column + 0.5) * layout.cellWidth,
        startY + (row + 0.5) * layout.cellHeight,
      );
      final fill = _glyph(
        glyphs[i],
        low,
        fillColor: fillColor,
        outline: outline,
      );
      final offset = center - Offset(fill.width / 2, fill.height / 2);
      _glyph(
        glyphs[i],
        low,
        stroke: true,
        fillColor: fillColor,
        outline: outline,
      ).paint(canvas, offset);
      fill.paint(canvas, offset);
    }
  }

  _VerticalGlyphMetrics _verticalGlyphMetrics(
    List<String> glyphs,
    Color fillColor,
    Color outline,
  ) {
    const sampleSize = 100.0;
    var width = 0.0;
    var height = 0.0;
    for (final glyph in glyphs) {
      final painter = _glyph(
        glyph,
        sampleSize,
        fillColor: fillColor,
        outline: outline,
      );
      width = math.max(width, painter.width);
      height = math.max(height, painter.height);
    }
    return _VerticalGlyphMetrics(width / sampleSize, height / sampleSize);
  }

  _VerticalTextLayout _verticalLayout(
    int glyphCount,
    Rect bounds,
    double fontSize,
    _VerticalGlyphMetrics glyphMetrics,
  ) {
    final cellWidth = fontSize * glyphMetrics.widthFactor * 1.08;
    final cellHeight = fontSize * glyphMetrics.heightFactor * 1.04;
    final rows = math.max(1, (bounds.height / cellHeight).floor());
    final columns = (glyphCount / rows).ceil();
    return _VerticalTextLayout(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      rows: rows,
      columns: columns,
      fits: cellHeight <= bounds.height &&
          columns * cellWidth <= bounds.width,
    );
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

  Color _blockBackground(_TranslationLayoutBlock block) {
    final colors = block.regions
        .map((region) => _regionBackground(region.region))
        .toList();
    return _medianColor(colors);
  }

  Color _blockForeground(_TranslationLayoutBlock block) {
    final colors = block.regions
        .where((region) => region.region.foregroundArgb != null)
        .map((region) => Color(region.region.foregroundArgb!))
        .toList();
    return colors.isEmpty ? foreground : _medianColor(colors);
  }

  Color _medianColor(List<Color> colors) {
    int median(int Function(Color color) channel) {
      final values = colors.map(channel).toList()..sort();
      return values[values.length ~/ 2];
    }
    return Color.fromARGB(
      255,
      median((color) => (color.r * 255).round()),
      median((color) => (color.g * 255).round()),
      median((color) => (color.b * 255).round()),
    );
  }

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
    final regions = artifact.regions
        .where((region) =>
            region.kind != ComicTextKind.soundEffect &&
            region.polygon.isNotEmpty)
        .map((region) => _TranslationLayoutRegion(region, _normalizedBounds(region)))
        .toList();
    if (!_usesBubbleLayout) {
      return regions
          .where((region) => region.region.translatedText.trim().isNotEmpty)
          .map((region) => _TranslationLayoutBlock(
                key: 'region:${region.region.ocrRegionId}',
                regions: [region],
                orientation: region.region.orientation,
                text: region.region.translatedText.trim(),
                independent: true,
                useBubbleBounds: false,
              ))
          .toList();
    }
    final parent = List.generate(regions.length, (index) => index);
    int root(int value) {
      while (parent[value] != value) {
        parent[value] = parent[parent[value]];
        value = parent[value];
      }
      return value;
    }
    for (var i = 0; i < regions.length; i++) {
      for (var j = i + 1; j < regions.length; j++) {
        if (!_sameTextBlock(regions[i], regions[j])) continue;
        parent[root(j)] = root(i);
      }
    }
    final groups = <int, List<_TranslationLayoutRegion>>{};
    for (var i = 0; i < regions.length; i++) {
      groups.putIfAbsent(root(i), () => []).add(regions[i]);
    }
    return groups.values
        .where((regions) => regions.any(
              (region) => region.region.translatedText.trim().isNotEmpty,
            ))
        .map((regions) {
      final vertical = regions
          .where((region) =>
              region.region.orientation == ComicTextOrientation.vertical)
          .length;
      final orientation = vertical * 2 == regions.length
          ? regions.first.region.orientation
          : vertical * 2 > regions.length
              ? ComicTextOrientation.vertical
              : ComicTextOrientation.horizontal;
      regions.sort(orientation == ComicTextOrientation.vertical
          ? (a, b) {
              final column = b.bounds.center.dx.compareTo(a.bounds.center.dx);
              return column != 0
                  ? column
                  : a.bounds.top.compareTo(b.bounds.top);
            }
          : (a, b) {
              final row = a.bounds.top.compareTo(b.bounds.top);
              return row != 0 ? row : a.bounds.left.compareTo(b.bounds.left);
            });
      final separator = orientation == ComicTextOrientation.vertical ||
              const {'zh', 'ja', 'ko'}.contains(
                artifact.targetLanguage.split(RegExp('[-_]')).first,
              )
          ? ''
          : ' ';
      final regionIds = regions.map((region) => region.region.ocrRegionId).toList()
        ..sort();
      final bubbleGroupId = regions.first.region.bubbleGroupId;
      return _TranslationLayoutBlock(
        key: bubbleGroupId == null
            ? 'regions:${regionIds.join(',')}'
            : 'bubble:$bubbleGroupId',
        regions: regions,
        orientation: orientation,
        text: regions
            .map((region) => region.region.translatedText.trim())
            .where((text) => text.isNotEmpty)
            .join(separator),
        independent: false,
        useBubbleBounds: true,
      );
    }).toList();
  }

  bool get _usesBubbleLayout =>
      artifact.sourceLanguage.split(RegExp('[-_]')).first.toLowerCase() == 'ko';

  bool _sameTextBlock(
    _TranslationLayoutRegion a,
    _TranslationLayoutRegion b,
  ) {
    final aGroup = a.region.bubbleGroupId;
    final bGroup = b.region.bubbleGroupId;
    if (aGroup != null || bGroup != null) {
      return aGroup != null && aGroup == bGroup;
    }
    if (a.region.orientation != b.region.orientation) return false;
    final aBubble = a.region.bubblePolygon;
    final bBubble = b.region.bubblePolygon;
    if (aBubble != null || bBubble != null) {
      return aBubble != null && bBubble != null &&
          _samePolygon(aBubble, bBubble);
    }
    if (a.region.orientation == ComicTextOrientation.vertical) {
      final overlap = math.max(
        0.0,
        math.min(a.bounds.bottom, b.bounds.bottom) -
            math.max(a.bounds.top, b.bounds.top),
      );
      final gap = math.max(
        0.0,
        math.max(a.bounds.left, b.bounds.left) -
            math.min(a.bounds.right, b.bounds.right),
      );
      return overlap / math.min(a.bounds.height, b.bounds.height) >= 0.55 &&
          gap <= math.max(a.bounds.width, b.bounds.width) * 1.6;
    }
    final overlap = math.max(
      0.0,
      math.min(a.bounds.right, b.bounds.right) -
          math.max(a.bounds.left, b.bounds.left),
    );
    final gap = math.max(
      0.0,
      math.max(a.bounds.top, b.bounds.top) -
          math.min(a.bounds.bottom, b.bounds.bottom),
    );
    return overlap / math.min(a.bounds.width, b.bounds.width) >= 0.55 &&
        gap <= math.max(a.bounds.height, b.bounds.height) * 1.25;
  }

  Rect _normalizedBounds(ComicTranslatedRegion region) => _bounds(
    region.polygon.map((point) => Offset(point.x, point.y)),
  );

  bool _samePolygon(
    List<NormalizedPoint> a,
    List<NormalizedPoint> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i].x - b[i].x).abs() > 0.000001 ||
          (a[i].y - b[i].y).abs() > 0.000001) {
        return false;
      }
    }
    return true;
  }

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
      oldDelegate.hasCleanOverlay != hasCleanOverlay ||
      oldDelegate.hiddenBlockKey != hiddenBlockKey;
}

class _TranslationLayoutRegion {
  final ComicTranslatedRegion region;
  final Rect bounds;

  const _TranslationLayoutRegion(this.region, this.bounds);
}

class _TranslationLayoutBlock {
  final String key;
  final List<_TranslationLayoutRegion> regions;
  final ComicTextOrientation orientation;
  final String text;
  final bool independent;
  final bool useBubbleBounds;

  const _TranslationLayoutBlock({
    required this.key,
    required this.regions,
    required this.orientation,
    required this.text,
    required this.independent,
    required this.useBubbleBounds,
  });
}

class _TranslationHitRegion {
  final String blockKey;
  final Path path;

  const _TranslationHitRegion(this.blockKey, this.path);
}

class _VerticalTextLayout {
  final double cellWidth;
  final double cellHeight;
  final int rows;
  final int columns;
  final bool fits;

  const _VerticalTextLayout({
    required this.cellWidth,
    required this.cellHeight,
    required this.rows,
    required this.columns,
    required this.fits,
  });
}

class _VerticalGlyphMetrics {
  final double widthFactor;
  final double heightFactor;

  const _VerticalGlyphMetrics(this.widthFactor, this.heightFactor);
}
