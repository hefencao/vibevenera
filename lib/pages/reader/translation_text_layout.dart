part of 'reader.dart';

const _strongPunctuation = {
    '。', '！', '？', '!', '?', '…', '‼', '⁉', '‽',
  };
const _weakPunctuation = {'，', '、', ',', '；', ';', '：', ':'};
const _closingBrackets = {
    '）', ')', '】', '》', '」', '』', '”', '’',
  };
const _closingPunctuation = {
    ..._strongPunctuation,
    ..._weakPunctuation,
    ..._closingBrackets,
  };
const _openingPunctuation = {
    '（', '(', '【', '《', '「', '『', '“', '‘',
  };

extension _ComicTranslationTextLayout on _ComicTranslationPainter {
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
    final laneLayouts = <_VerticalTextLayout?>[];
    for (final lane in option.lanes) {
      if (block.orientation == ComicTextOrientation.vertical) {
        final glyphs = _verticalGlyphs(lane.text);
        final metrics = _verticalGlyphMetrics(glyphs);
        final layout = _verticalLayout(lane, fontSize, metrics);
        if (!layout.fits) {
          return const _MeasuredTranslationLayout(
            false, 0, 0, 0, 0, 0, Rect.zero, [],
          );
        }
        laneLayouts.add(layout);
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
        laneLayouts.add(null);
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
            false, 0, 0, 0, 0, 0, Rect.zero, [],
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
      laneLayouts,
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

}

class _TranslationRenderPreparation {
  final _ComicTranslationPainter painter;
  final _TranslationLayoutBlock block;
  final _TranslationLayoutPlan plan;
  final _TranslationBlockGeometry geometry;
  final Rect imageRect;
  final List<_TranslationBackgroundShape> _backgrounds = [];
  final List<_TranslationTextCommand> _text = [];
  int _regionIndex = 0;
  int _laneIndex = 0;
  int _glyphIndex = 0;
  int _column = 0;
  int _row = 0;
  List<String>? _glyphs;

  _TranslationRenderPreparation(
    this.painter,
    this.block,
    this.plan,
    this.geometry,
    this.imageRect,
  );

  bool step() {
    if (_regionIndex < block.regions.length) {
      final region = block.regions[_regionIndex].region;
      final masks = region.sourceMaskPolygons.isEmpty
          ? [region.polygon]
          : region.sourceMaskPolygons;
      final path = Path();
      var hasPolygon = false;
      for (final polygon in masks) {
        if (polygon.length < 3) continue;
        path.addPolygon(painter._displayPolygon(polygon, imageRect), true);
        hasPolygon = true;
      }
      if (hasPolygon) {
        _backgrounds.add(_TranslationBackgroundShape(
          path,
          Paint()..color = painter._regionBackground(region),
        ));
      }
      _regionIndex++;
      return false;
    }
    if (_laneIndex == plan.lanes.length) return true;
    final lane = plan.lanes[_laneIndex];
    final region = lane.regions.first.region;
    final fillColor = painter._regionForeground(region);
    final outline = painter._regionBackground(region);
    if (block.orientation == ComicTextOrientation.horizontal) {
      final fill = painter._paragraph(
        lane.text,
        plan.fontSize,
        lane.bounds.width,
        fillColor: fillColor,
        outline: outline,
      );
      final stroke = painter._paragraph(
        lane.text,
        plan.fontSize,
        lane.bounds.width,
        stroke: true,
        fillColor: fillColor,
        outline: outline,
      );
      _text.add(_TranslationTextCommand(
        fill,
        stroke,
        Offset(
          lane.bounds.left + (lane.bounds.width - fill.width) / 2,
          lane.bounds.top + (lane.bounds.height - fill.height) / 2,
        ),
      ));
      _laneIndex++;
      return _laneIndex == plan.lanes.length;
    }
    final glyphs = _glyphs ??= painter._verticalGlyphs(lane.text);
    final layout = plan.laneLayouts[_laneIndex]!;
    final columnLength = layout.columnLengths[_column];
    final center = Offset(
      lane.bounds.center.dx +
          layout.columnLengths.length * layout.cellWidth / 2 -
          (_column + .5) * layout.cellWidth,
      lane.bounds.center.dy - columnLength * layout.cellHeight / 2 +
          (_row + .5) * layout.cellHeight,
    );
    final glyph = glyphs[_glyphIndex++];
    final fill = painter._glyph(
      glyph,
      plan.fontSize,
      fillColor: fillColor,
      outline: outline,
    );
    _text.add(_TranslationTextCommand(
      fill,
      painter._glyph(
        glyph,
        plan.fontSize,
        stroke: true,
        fillColor: fillColor,
        outline: outline,
      ),
      painter._glyphOffset(fill, center),
    ));
    if (++_row == columnLength) {
      _column++;
      _row = 0;
    }
    if (_glyphIndex == glyphs.length) {
      _laneIndex++;
      _glyphIndex = 0;
      _column = 0;
      _row = 0;
      _glyphs = null;
    }
    return _laneIndex == plan.lanes.length;
  }

  _TranslationPreparedBlock get result => _TranslationPreparedBlock(
    geometry,
    List.unmodifiable(_backgrounds),
    List.unmodifiable(_text),
  );
}
