part of 'reader.dart';

extension _ComicTranslationGeometry on _ComicTranslationPainter {
  _TranslationBlockGeometry? _blockGeometry(
    _TranslationLayoutBlock block,
    Rect imageRect,
  ) {
    final regionBounds = block.regions
        .map((region) => _displayBounds(region.inkBounds, imageRect))
        .toList(growable: false);
    final sourceBounds = regionBounds
        .reduce((value, next) => value.expandToInclude(next));
    final sourceCenter = _sourceCenter(block, imageRect, sourceBounds);
    final bubble = _blockBubble(block);
    final bubblePoints = bubble == null
        ? null
        : _displayPolygon(bubble, imageRect);
    var bubblePath = bubblePoints == null
        ? null
        : (Path()..addPolygon(bubblePoints, true));
    final sourceFontSize = _sourceFontSize(block, regionBounds);
    var bounds = bubblePath == null
        ? _openBubbleBounds(sourceBounds, sourceFontSize, imageRect)
        : _safeBubbleBounds(
            bubblePath,
            bubblePoints!,
            sourceBounds,
            sourceCenter,
            sourceFontSize,
          ).intersect(imageRect);
    // A segmented tail or a merged/partially open contour can leave no usable
    // inner rectangle although the OCR text geometry itself is valid. Such a
    // polygon is not a valid layout constraint; keep the source-anchored block
    // instead of silently dropping its translated text.
    if (bubblePath != null && (bounds.width < 3 || bounds.height < 3)) {
      bubblePath = null;
      bounds = _openBubbleBounds(sourceBounds, sourceFontSize, imageRect);
    }
    if (bounds.width < 3 || bounds.height < 3) return null;
    return _TranslationBlockGeometry(
      regionBounds,
      bounds,
      bubblePath,
    );
  }

  double _dominantFontSize(
    List<({double size, double weight})> samples,
  ) {
    samples.sort((a, b) => a.size.compareTo(b.size));
    if (samples.length == 1) return samples.single.size;
    var bestStart = 0;
    var bestEnd = 1;
    var bestScore = -1.0;
    for (var start = 0; start < samples.length; start++) {
      var end = start + 1;
      while (end < samples.length &&
          samples[end].size <= samples[start].size * 1.32) {
        end++;
      }
      final clusterWeight = samples
          .sublist(start, end)
          .fold(0.0, (sum, sample) => sum + sample.weight);
      final medianSize = samples[(start + end - 1) ~/ 2].size;
      final relativeSize = medianSize / math.max(1e-6, samples.last.size);
      final score = clusterWeight * math.pow(relativeSize, .28);
      if (score > bestScore) {
        bestStart = start;
        bestEnd = end;
        bestScore = score;
      }
    }
    final cluster = samples.sublist(bestStart, bestEnd);
    final total = cluster.fold(0.0, (sum, sample) => sum + sample.weight);
    var cumulative = 0.0;
    for (final sample in cluster) {
      cumulative += sample.weight;
      if (cumulative >= total / 2) return sample.size;
    }
    return cluster.last.size;
  }


  double _sourceFontSize(
    _TranslationLayoutBlock block,
    List<Rect> regionBounds,
  ) {
    final samples = List.generate(block.regions.length, (index) {
      final characters = math.max(
        1,
        _characters(block.regions[index].region.sourceText),
      );
      final bounds = regionBounds[index];
      final crossExtent = block.orientation == ComicTextOrientation.vertical
          ? bounds.width
          : bounds.height;
      final mainExtent = block.orientation == ComicTextOrientation.vertical
          ? bounds.height
          : bounds.width;
      final region = block.regions[index].region;
      final size = comicTextFontSize(
        crossExtent: crossExtent,
        mainExtent: mainExtent,
        characters: characters,
        bodyContext:
            region.bubbleGroupId != null || region.bubblePolygon != null,
      );
      final visualMass = math.max(1.0, bounds.width * bounds.height) *
          math.sqrt(characters);
      return (
        size: math.max(1.0, size).toDouble(),
        weight: visualMass,
      );
    });
    return _dominantFontSize(samples);
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
    final sourceFontSize = _sourceFontSize(block, regionBounds);
    final initialWidth = math.min(
      bounds.width,
      sourceBounds.width + math.max(6, sourceFontSize * .7),
    );
    final initialHeight = math.min(
      bounds.height,
      sourceBounds.height + math.max(6, sourceFontSize * .7),
    );
    final text = _laneText(block.bands);
    final breakHints = _breakHints(block.bands, text);
    final sourceBandCharacters = block.bands.map((band) => band.fold(
      0,
      (count, region) => count + _characters(region.region.sourceText),
    )).toList();
    final targetBandCharacters = block.bands.map((band) =>
        _characters(_bandText(band))).toList();
    final factors = insideBubble
        ? const [0.0, .22, .45, .68, .85, 1.0]
        : const [0.0];
    final diagonal = math.max(
      1.0,
      math.sqrt(bounds.width * bounds.width + bounds.height * bounds.height),
    );
    return factors.map((factor) {
      final width = initialWidth + (bounds.width - initialWidth) * factor;
      final height = initialHeight + (bounds.height - initialHeight) * factor;
      final laneBounds = _rectAroundAnchor(
        sourceCenter,
        width,
        height,
        bounds,
      );
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

  Rect _rectAroundAnchor(
    Offset anchor,
    double width,
    double height,
    Rect container,
  ) {
    final safeWidth = width.clamp(0.0, container.width).toDouble();
    final safeHeight = height.clamp(0.0, container.height).toDouble();
    final halfWidth = safeWidth / 2;
    final halfHeight = safeHeight / 2;
    final minCenterX = container.left + halfWidth;
    final minCenterY = container.top + halfHeight;
    // Clamp travel from one origin. At factor=1, calculating left+half and
    // right-half independently can invert the equal bounds by one ULP.
    final centerTravelX = container.width - safeWidth;
    final centerTravelY = container.height - safeHeight;
    final center = Offset(
      minCenterX +
          (anchor.dx - minCenterX).clamp(0.0, centerTravelX).toDouble(),
      minCenterY +
          (anchor.dy - minCenterY).clamp(0.0, centerTravelY).toDouble(),
    );
    return Rect.fromCenter(
      center: center,
      width: safeWidth,
      height: safeHeight,
    );
  }


  Offset _sourceCenter(
    _TranslationLayoutBlock block,
    Rect imageRect,
    Rect sourceBounds,
  ) {
    var totalWeight = 0.0;
    var x = 0.0;
    var y = 0.0;
    for (final layout in block.regions) {
      final bounds = _displayBounds(layout.inkBounds, imageRect);
      // Area-weighted text centres keep equal columns centred while making a
      // tiny ruby/annotation box unable to drag the whole translation away.
      final weight = math.max(1.0, bounds.width * bounds.height);
      totalWeight += weight;
      x += bounds.center.dx * weight;
      y += bounds.center.dy * weight;
    }
    if (totalWeight <= 0) return sourceBounds.center;
    return Offset(
      (x / totalWeight).clamp(sourceBounds.left, sourceBounds.right).toDouble(),
      (y / totalWeight).clamp(sourceBounds.top, sourceBounds.bottom).toDouble(),
    );
  }

  Rect _openBubbleBounds(
    Rect sourceBounds,
    double sourceFontSize,
    Rect imageRect,
  ) => sourceBounds
      .inflate(math.max(3, sourceFontSize * 0.7))
      .intersect(imageRect);

  Rect _safeBubbleBounds(
    Path bubble,
    List<Offset> bubblePoints,
    Rect sourceBounds,
    Offset sourceCenter,
    double sourceFontSize,
  ) {
    final bubbleBounds = _bounds(bubblePoints);
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

    // Preserve the OCR text centre. Bubble bounding-box and polygon
    // centroids are often pulled toward a speech tail, so using them to gain a
    // larger rectangle causes the visible translation to drift. Only fall back
    // when the source centre itself is outside a malformed bubble polygon.
    final center = bubble.contains(sourceCenter)
        ? sourceCenter
        : bubble.contains(sourceBounds.center)
            ? sourceBounds.center
            : bubble.contains(_polygonCentroid(bubblePoints))
                ? _polygonCentroid(bubblePoints)
                : bubbleBounds.center;
    return candidateAt(center).deflate(math.max(2, sourceFontSize * 0.12));
  }

  Offset _polygonCentroid(List<Offset> polygon) {
    if (polygon.length < 3) return _bounds(polygon).center;
    var crossSum = 0.0;
    var x = 0.0;
    var y = 0.0;
    for (var index = 0; index < polygon.length; index++) {
      final a = polygon[index];
      final b = polygon[(index + 1) % polygon.length];
      final cross = a.dx * b.dy - b.dx * a.dy;
      crossSum += cross;
      x += (a.dx + b.dx) * cross;
      y += (a.dy + b.dy) * cross;
    }
    if (crossSum.abs() < 1e-6) return _bounds(polygon).center;
    final factor = 1 / (3 * crossSum);
    return Offset(x * factor, y * factor);
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
      if (polygon == null ||
          polygon.length < 3 ||
          polygon.any((point) => !point.x.isFinite || !point.y.isFinite)) {
        continue;
      }
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
            region.polygon.length >= 3 &&
            region.polygon.every(
              (point) => point.x.isFinite && point.y.isFinite,
            ))
        .map((region) => _TranslationLayoutRegion(
              region,
              _normalizedBounds(region),
              _normalizedInkBounds(region),
            ))
        .toList();
    if (regions.isEmpty) {
      return _blocks = const [];
    }
    final incomplete = regions.where((region) {
      final value = region.region;
      return value.translationUnitId == null ||
          value.translationUnitOrder == null ||
          value.translationBandIndex == null ||
          value.translationOrientation == null;
    }).map((region) => region.region.ocrRegionId).toList();
    if (incomplete.isNotEmpty) {
      throw StateError('Translation artifact has incomplete layout metadata: '
          '${incomplete.join(',')}');
    }

    final groups = <String, List<_TranslationLayoutRegion>>{};
    for (final region in regions) {
      groups.putIfAbsent(region.region.translationUnitId!, () => [])
          .add(region);
    }
    final blocks = groups.entries.where((entry) => entry.value.any((region) =>
        _visibleTranslation(region.region.translatedText).isNotEmpty))
        .map((entry) {
      final values = entry.value
        ..sort((a, b) => a.region.translationUnitOrder!
            .compareTo(b.region.translationUnitOrder!));
      final bandMap = <int, List<_TranslationLayoutRegion>>{};
      for (final region in values) {
        bandMap.putIfAbsent(region.region.translationBandIndex!, () => [])
            .add(region);
      }
      final bands = bandMap.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return _TranslationLayoutBlock(
        key: 'layout:${entry.key}',
        regions: values,
        orientation: values.first.region.translationOrientation!,
        bands: bands.map((entry) => entry.value).toList(),
      );
    }).toList();
    blocks.sort((a, b) {
      double order(_TranslationLayoutBlock block) {
        final top = block.regions
            .map((region) => region.inkBounds.top)
            .reduce(math.min);
        final left = block.regions
            .map((region) => region.inkBounds.left)
            .reduce(math.min);
        return top * artifact.imageWidth + left;
      }
      return order(a).compareTo(order(b));
    });
    return _blocks = blocks;
  }


  Rect _normalizedBounds(ComicTranslatedRegion region) => _bounds(
    region.polygon.map((point) => Offset(point.x, point.y)),
  );

  Rect _normalizedInkBounds(ComicTranslatedRegion region) {
    final points = region.sourceMaskPolygons
        .expand((polygon) => polygon)
        .where((point) => point.x.isFinite && point.y.isFinite)
        .map((point) => Offset(point.x, point.y))
        .toList();
    return points.isEmpty ? _normalizedBounds(region) : _bounds(points);
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

}
