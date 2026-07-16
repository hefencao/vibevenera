part of 'reader.dart';

class _ReaderTranslationLayer extends StatelessWidget {
  final int pageIndex;
  final Alignment alignment;
  final Widget child;

  const _ReaderTranslationLayer({
    required this.pageIndex,
    required this.child,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    final reader = context.reader;
    if (!reader.translationSession.enabled) return child;
    final identity = reader.translationIdentity(pageIndex);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
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
                    return const SizedBox();
                  }
                  return CustomPaint(
                    painter: _ComicTranslationPainter(
                      artifact: artifact,
                      fit: BoxFit.contain,
                      alignment: alignment,
                      background: context.colorScheme.surface.withValues(
                        alpha: 0.88,
                      ),
                      foreground: context.colorScheme.onSurface,
                    ),
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

  const _ComicTranslationPainter({
    required this.artifact,
    required this.fit,
    required this.alignment,
    required this.background,
    required this.foreground,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sourceSize = Size(
      artifact.imageWidth.toDouble(),
      artifact.imageHeight.toDouble(),
    );
    final fitted = applyBoxFit(fit, sourceSize, size);
    final imageRect = alignment.inscribe(fitted.destination, Offset.zero & size);
    for (final block in _layoutBlocks()) {
      final regionBounds = block.regions.map((region) => _displayBounds(
        region.bounds,
        imageRect,
      )).toList();
      final regionFontSizes = regionBounds
          .map((bounds) => block.orientation == ComicTextOrientation.vertical
              ? bounds.width
              : bounds.height)
          .toList();
      final sortedFontSizes = [...regionFontSizes]
        ..sort();
      final originalFontSize =
          sortedFontSizes[sortedFontSizes.length ~/ 2] * 0.82;
      final bounds = regionBounds
          .reduce((value, next) => value.expandToInclude(next))
          .inflate(math.max(2, originalFontSize * 0.22))
          .intersect(imageRect);
      if (bounds.width < 12 || bounds.height < 12) continue;
      final text = block.text;
      final blockBackground = _regionBackground(block.regions.first.region);
      canvas.save();
      canvas.clipRect(bounds);
      for (var i = 0; i < block.regions.length; i++) {
        _paintSourceMask(
          canvas,
          block.regions[i].region.sourceText,
          regionBounds.elementAt(i),
          block.orientation,
          regionFontSizes[i] * 0.82,
          _regionBackground(block.regions[i].region),
        );
      }
      if (block.orientation == ComicTextOrientation.vertical) {
        _paintVertical(canvas, text, bounds, originalFontSize, blockBackground);
      } else {
        _paintHorizontal(canvas, text, bounds, originalFontSize, blockBackground);
      }
      canvas.restore();
    }
  }

  void _paintSourceMask(
    Canvas canvas,
    String text,
    Rect bounds,
    ComicTextOrientation orientation,
    double maxFontSize,
    Color maskColor,
  ) {
    if (text.trim().isEmpty) return;
    if (orientation == ComicTextOrientation.vertical) {
      final glyphs = text.runes.map(String.fromCharCode).toList();
      var low = 2.0;
      var high = math.max(low, maxFontSize);
      for (var i = 0; i < 7; i++) {
        final size = (low + high) / 2;
        if (_verticalFits(glyphs.length, bounds, size)) {
          low = size;
        } else {
          high = size;
        }
      }
      final lineHeight = low * 1.08;
      final rows = math.max(1, (bounds.height / lineHeight).floor());
      for (var i = 0; i < glyphs.length; i++) {
        final column = i ~/ rows;
        final row = i % rows;
        final fill = _glyph(
          glyphs[i],
          low,
          mask: true,
          outline: maskColor,
          locale: _sourceLocale,
        );
        final center = Offset(
          bounds.right - (column + 0.5) * low * 1.12,
          bounds.top + (row + 0.5) * lineHeight,
        );
        final offset = center - Offset(fill.width / 2, fill.height / 2);
        _glyph(
          glyphs[i],
          low,
          stroke: true,
          mask: true,
          outline: maskColor,
          locale: _sourceLocale,
        ).paint(canvas, offset);
        fill.paint(canvas, offset);
      }
      return;
    }
    var low = 2.0;
    var high = math.max(low, maxFontSize);
    for (var i = 0; i < 7; i++) {
      final size = (low + high) / 2;
      final painter = _paragraph(
        text,
        size,
        bounds.width,
        mask: true,
        outline: maskColor,
        locale: _sourceLocale,
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
      mask: true,
      outline: maskColor,
      locale: _sourceLocale,
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
      mask: true,
      outline: maskColor,
      locale: _sourceLocale,
    )
        .paint(canvas, offset);
    fill.paint(canvas, offset);
  }

  void _paintHorizontal(
    Canvas canvas,
    String text,
    Rect bounds,
    double maxFontSize,
    Color outline,
  ) {
    var low = 2.0;
    var high = math.max(low, maxFontSize);
    for (var i = 0; i < 7; i++) {
      final size = (low + high) / 2;
      final painter = _paragraph(text, size, bounds.width, outline: outline);
      if (painter.height <= bounds.height) {
        low = size;
      } else {
        high = size;
      }
    }
    final fill = _paragraph(text, low, bounds.width, outline: outline);
    final offset = Offset(
      bounds.left + (bounds.width - fill.width) / 2,
      bounds.top + (bounds.height - fill.height) / 2,
    );
    _paragraph(text, low, bounds.width, stroke: true, outline: outline)
        .paint(canvas, offset);
    fill.paint(canvas, offset);
  }

  void _paintVertical(
    Canvas canvas,
    String text,
    Rect bounds,
    double maxFontSize,
    Color outline,
  ) {
    final glyphs = text.runes.map(String.fromCharCode).toList();
    if (glyphs.isEmpty) return;
    var low = 2.0;
    var high = math.max(low, maxFontSize);
    for (var i = 0; i < 7; i++) {
      final size = (low + high) / 2;
      if (_verticalFits(glyphs.length, bounds, size)) {
        low = size;
      } else {
        high = size;
      }
    }
    final lineHeight = low * 1.08;
    final columnWidth = low * 1.12;
    final rows = math.max(1, (bounds.height / lineHeight).floor());
    final columns = (glyphs.length / rows).ceil();
    final startX = bounds.center.dx + columns * columnWidth / 2;
    for (var i = 0; i < glyphs.length; i++) {
      final column = i ~/ rows;
      final row = i % rows;
      final center = Offset(
        startX - (column + 0.5) * columnWidth,
        bounds.top + (row + 0.5) * lineHeight,
      );
      final fill = _glyph(glyphs[i], low, outline: outline);
      final offset = center - Offset(fill.width / 2, fill.height / 2);
      _glyph(glyphs[i], low, stroke: true, outline: outline)
          .paint(canvas, offset);
      fill.paint(canvas, offset);
    }
  }

  bool _verticalFits(int glyphs, Rect bounds, double fontSize) {
    final rows = math.max(1, (bounds.height / (fontSize * 1.08)).floor());
    final columns = (glyphs / rows).ceil();
    return columns * fontSize * 1.12 <= bounds.width;
  }

  TextPainter _paragraph(
    String text,
    double fontSize,
    double width, {
    bool stroke = false,
    bool mask = false,
    required Color outline,
    Locale? locale,
  }) => TextPainter(
      text: TextSpan(
        text: text,
        style: _textStyle(fontSize, stroke, mask, outline),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      locale: locale ?? _targetLocale,
    )..layout(maxWidth: width);

  TextPainter _glyph(
    String text,
    double fontSize, {
    bool stroke = false,
    bool mask = false,
    required Color outline,
    Locale? locale,
  }) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: _textStyle(fontSize, stroke, mask, outline),
        ),
        textDirection: TextDirection.ltr,
        locale: locale ?? _targetLocale,
      )..layout();

  TextStyle _textStyle(
    double fontSize,
    bool stroke,
    bool mask,
    Color outline,
  ) => TextStyle(
    color: stroke ? null : (mask ? outline : foreground),
    foreground: stroke
        ? (Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = math.max(1.2, fontSize * (mask ? 0.28 : 0.14)))
        : null,
    fontSize: fontSize,
    height: 1.05,
    fontWeight: FontWeight.w500,
  );

  Color _regionBackground(ComicTranslatedRegion region) =>
      region.backgroundArgb == null ? background : Color(region.backgroundArgb!);

  Locale? get _sourceLocale => _languageLocale(artifact.sourceLanguage);

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
            region.translatedText.trim().isNotEmpty &&
            region.polygon.isNotEmpty)
        .map((region) => _TranslationLayoutRegion(region, _normalizedBounds(region)))
        .toList();
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
    return groups.values.map((regions) {
      final orientation = regions.first.region.orientation;
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
      final separator = orientation == ComicTextOrientation.vertical ? '' : ' ';
      return _TranslationLayoutBlock(
        regions: regions,
        orientation: orientation,
        text: regions
            .map((region) => region.region.translatedText.trim())
            .join(separator),
      );
    }).toList();
  }

  bool _sameTextBlock(
    _TranslationLayoutRegion a,
    _TranslationLayoutRegion b,
  ) {
    if (a.region.orientation != b.region.orientation) return false;
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

  @override
  bool shouldRepaint(covariant _ComicTranslationPainter oldDelegate) =>
      oldDelegate.artifact != artifact ||
      oldDelegate.fit != fit ||
      oldDelegate.alignment != alignment ||
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground;
}

class _TranslationLayoutRegion {
  final ComicTranslatedRegion region;
  final Rect bounds;

  const _TranslationLayoutRegion(this.region, this.bounds);
}

class _TranslationLayoutBlock {
  final List<_TranslationLayoutRegion> regions;
  final ComicTextOrientation orientation;
  final String text;

  const _TranslationLayoutBlock({
    required this.regions,
    required this.orientation,
    required this.text,
  });
}
