part of 'reader.dart';

class _TranslationLayoutSearch {
  final _ComicTranslationPainter painter;
  final _TranslationLayoutBlock block;
  final List<_TranslationLayoutOption> options;
  final int sourceCharacters;
  final double sourceArea;
  final Rect sourceBounds;
  final double preferredFont;
  final bool body;
  int _optionIndex = 0;
  int _binaryStep = 0;
  int _fontStep = -1;
  bool _optionInitialized = false;
  bool _lowerBoundFits = false;
  double _low = 2;
  double _high = 2;
  double _minimumFont = 2;
  _TranslationLayoutCandidate? _best;
  _TranslationLayoutCandidate? _bodyBest;
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
           painter.fontScale,
       body = block.regions.every((region) =>
               region.region.kind != ComicTextKind.soundEffect) &&
           (block.regions.any((region) =>
               region.region.bubbleGroupId != null ||
               region.region.bubblePolygon != null) ||
               block.regions.fold(0, (count, region) =>
                   count + painter._characters(region.region.sourceText)) >= 4);

  bool step() {
    if (_optionIndex >= options.length) {
      plan = (_bodyBest ?? _best)!.plan;
      return true;
    }
    final option = options[_optionIndex];
    if (!_optionInitialized) {
      final extent = option.lanes.map((lane) => block.orientation ==
          ComicTextOrientation.vertical
          ? math.min(lane.bounds.width, lane.bounds.height)
          : lane.bounds.height).reduce(math.min);
      _high = math.max(.01, extent * .95);
      _low = math.min(2, _high);
      _optionInitialized = true;
    }
    if (!_lowerBoundFits) {
      if (painter._measureLayout(block, option, _low).fits) {
        _lowerBoundFits = true;
      } else {
        _low /= 2;
      }
      return false;
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
        math.max(2, preferredFont * .58),
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
    _optionInitialized = false;
    _lowerBoundFits = false;
    if (_optionIndex < options.length) return false;
    plan = (_bodyBest ?? _best)!.plan;
    return true;
  }

  void _consider(
    _TranslationLayoutOption option,
    double fontSize,
    _MeasuredTranslationLayout measured,
  ) {
    final targetCharacters = math.max(
      1,
      option.lanes.fold(
        0,
        (count, lane) => count + painter._characters(lane.text),
      ),
    );
    final safeSourceCharacters = math.max(1, sourceCharacters);
    final targetArea = math.max(
      1e-6,
      sourceArea * targetCharacters / safeSourceCharacters,
    );
    final densityPenalty =
        (math.log(math.max(1e-6, measured.area) / targetArea)).abs();
    final fontPenalty =
        (math.log(fontSize / math.max(1e-6, preferredFont))).abs();
    final tinyFontPenalty = math.max(
      0.0,
      preferredFont * .58 / math.max(1e-6, fontSize) - 1,
    );
    final lengthRatio = targetCharacters / safeSourceCharacters;
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
    final score = densityPenalty * .55 +
        fontPenalty * .68 +
        tinyFontPenalty * 1.8 +
        topologyPenalty * 1.05 +
        unbrokenShrinkPenalty * 1.45 +
        measured.flowPenalty * .85 +
        measured.sentencePenalty * .8 +
        measured.orphanPenalty * 1.1 +
        extentPenalty * .8 +
        option.positionPenalty * 3.0;
    final candidate = _TranslationLayoutCandidate(
      _TranslationLayoutPlan(
        option.lanes,
        measured.laneLayouts,
        fontSize,
      ),
      score,
    );
    if (_best == null || score < _best!.score) _best = candidate;
    final ratio = fontSize / preferredFont;
    if (body && ratio >= .82 && ratio <= 1.18 &&
        (_bodyBest == null || score < _bodyBest!.score)) {
      _bodyBest = candidate;
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
  final List<_VerticalTextLayout?> laneLayouts;

  const _MeasuredTranslationLayout(
    this.fits,
    this.area,
    this.lineCount,
    this.sentencePenalty,
    this.orphanPenalty,
    this.flowPenalty,
    this.contentBounds,
    this.laneLayouts,
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
