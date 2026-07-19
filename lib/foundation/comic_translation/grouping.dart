import 'dart:math' as math;

import 'models.dart';

double comicTextFontSize({
  required double crossExtent,
  required double mainExtent,
  required int characters,
  required bool bodyContext,
}) {
  final advance = mainExtent / characters.clamp(1, 1000);
  final areaSize = math.sqrt(math.max(1e-6, crossExtent * advance));
  final stableExtent = bodyContext ? math.max(crossExtent, advance) : crossExtent;
  return stableExtent * .72 + areaSize * .28;
}

double comicTextSourceFontSize({
  required double crossExtent,
  required double mainExtent,
  required int decodedCharacters,
  required bool bodyContext,
  required bool squareGlyphs,
}) {
  final geometricCharacters = bodyContext
      ? math.max(1, (mainExtent / math.max(1, crossExtent)).round())
      : decodedCharacters;
  final characters = math.max(decodedCharacters, geometricCharacters);
  final correctedMainExtent = squareGlyphs && characters > 1
      ? math.max(
          mainExtent,
          (mainExtent - crossExtent) / (characters - 1) * characters,
        )
      : mainExtent;
  return comicTextFontSize(
    crossExtent: crossExtent,
    mainExtent: correctedMainExtent,
    characters: characters,
    bodyContext: bodyContext,
  );
}

final class ComicTextRegion<T> {
  final T value;
  final String id;
  final String text;
  final List<NormalizedPoint> polygon;
  final List<List<NormalizedPoint>> sourceMaskPolygons;
  final ComicTextOrientation orientation;
  final int? backgroundArgb;
  final int? bubbleGroupId;
  final List<NormalizedPoint>? bubblePolygon;

  const ComicTextRegion({
    required this.value,
    required this.id,
    required this.text,
    required this.polygon,
    required this.sourceMaskPolygons,
    required this.orientation,
    required this.backgroundArgb,
    required this.bubbleGroupId,
    required this.bubblePolygon,
  });
}

final class ComicTextBand<T> {
  final List<ComicTextRegion<T>> regions;

  const ComicTextBand(this.regions);
}

final class ResolvedComicTextGroup<T> {
  final String key;
  final ComicTextOrientation orientation;
  final List<ComicTextBand<T>> bands;

  const ResolvedComicTextGroup({
    required this.key,
    required this.orientation,
    required this.bands,
  });

  List<ComicTextRegion<T>> get regions =>
      bands.expand((band) => band.regions).toList();
}

final class ComicTextGrouping {
  final int imageWidth;
  final int imageHeight;
  final String sourceLanguage;

  const ComicTextGrouping({
    required this.imageWidth,
    required this.imageHeight,
    required this.sourceLanguage,
  });

  List<ResolvedComicTextGroup<T>> resolve<T>(
    List<ComicTextRegion<T>> regions,
  ) {
    if (regions.isEmpty) return const [];
    final boxes = regions.map(_box).toList();
    final parent = List.generate(boxes.length, (index) => index);
    final members = <int, List<int>>{
      for (var i = 0; i < boxes.length; i++) i: [i],
    };
    int root(int value) {
      while (parent[value] != value) {
        parent[value] = parent[parent[value]];
        value = parent[value];
      }
      return value;
    }
    final edges = <_GroupingEdge>[];
    for (var i = 0; i < boxes.length; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        if (_related(boxes[i], boxes[j], boxes)) {
          edges.add(_GroupingEdge(
            i, j, _relationDistance(boxes[i], boxes[j], boxes),
          ));
        }
      }
    }
    edges.sort((a, b) => a.distance.compareTo(b.distance));
    for (final edge in edges) {
      final aRoot = root(edge.a);
      final bRoot = root(edge.b);
      if (aRoot == bRoot) continue;
      final aMembers = members[aRoot]!;
      final bMembers = members[bRoot]!;
      final conflicts = aMembers.any((a) => bMembers.any((b) =>
          _directionallySeparated(boxes[a], boxes[b], boxes)));
      if (conflicts) continue;
      parent[bRoot] = aRoot;
      aMembers.addAll(bMembers);
      members.remove(bRoot);
    }
    final components = <int, List<ComicTextRegion<T>>>{};
    for (var i = 0; i < boxes.length; i++) {
      components.putIfAbsent(root(i), () => []).add(boxes[i].region);
    }
    final groups = components.values.map((members) {
      final orientation = _orientation(members);
      final bands = _bands(members, orientation);
      final ids = members.map((region) => region.id).toList()..sort();
      return ResolvedComicTextGroup<T>(
        key: members.length == 1 ? members.single.id : 'regions:${ids.join(',')}',
        orientation: orientation,
        bands: bands,
      );
    }).toList();
    groups.sort((a, b) => _groupOrder(a).compareTo(_groupOrder(b)));
    return groups;
  }

  List<String> diagnoseRelations<T>(
    List<ComicTextRegion<T>> regions,
    Map<String, String?> unitIds,
    {
      bool? relatedFilter,
      Set<int> regionIndices = const {},
    }
  ) {
    final boxes = regions.map(_box).toList();
    final diagnostics = <String>[];
    for (var i = 0; i < boxes.length; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        if (regionIndices.isNotEmpty &&
            (regionIndices.length == 1
                ? !regionIndices.contains(i) && !regionIndices.contains(j)
                : !regionIndices.contains(i) || !regionIndices.contains(j))) {
          continue;
        }
        final a = boxes[i];
        final b = boxes[j];
        final relation = StringBuffer();
        final separation = StringBuffer();
        final related = _related(a, b, boxes, trace: relation);
        if (relatedFilter != null && related != relatedFilter) continue;
        final separated = _directionallySeparated(
          a, b, boxes, trace: separation,
        );
        diagnostics.add(
          '#${i + 1} ${a.region.id}(${a.region.text})/'
          '#${j + 1} ${b.region.id}(${b.region.text}) '
          'g${a.region.bubbleGroupId ?? '-'}/'
          '${b.region.bubbleGroupId ?? '-'} '
          'u${unitIds[a.region.id]}/u${unitIds[b.region.id]} '
          'ocr=${_boundsText(a)}/${_boundsText(b)} '
          'mask=${_boundsText(_positionBox(a.region))}/'
          '${_boundsText(_positionBox(b.region))} '
          'related=$related {$relation} separated=$separated {$separation}',
        );
      }
    }
    return diagnostics;
  }

  List<ComicTextBand<T>> _bands<T>(
    List<ComicTextRegion<T>> regions,
    ComicTextOrientation orientation,
  ) {
    final boxes = regions.map(_box).toList();
    final vertical = orientation == ComicTextOrientation.vertical;
    final dominantThickness = _dominantThickness(boxes, vertical);
    final parent = List.generate(boxes.length, (index) => index);
    int root(int value) {
      while (parent[value] != value) {
        parent[value] = parent[parent[value]];
        value = parent[value];
      }
      return value;
    }
    for (var i = 0; i < boxes.length; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        final a = _textBounds(boxes[i], vertical);
        final b = _textBounds(boxes[j], vertical);
        final overlap = vertical
            ? _overlap(a.left, a.right, b.left, b.right) /
                _min(a.width, b.width)
            : _overlap(a.top, a.bottom, b.top, b.bottom) /
                _min(a.height, b.height);
        final centerDistance = vertical
            ? ((a.left + a.right) - (b.left + b.right)).abs() / 2
            : ((a.top + a.bottom) - (b.top + b.bottom)).abs() / 2;
        if (overlap >= 0.45 ||
            centerDistance <= dominantThickness * 0.55) {
          parent[root(j)] = root(i);
        }
      }
    }
    final rawBands = <int, List<_RegionBox<T>>>{};
    for (var i = 0; i < boxes.length; i++) {
      rawBands.putIfAbsent(root(i), () => []).add(boxes[i]);
    }
    final ordered = rawBands.values.toList()
      ..sort((a, b) {
        final ac = _bandCenter(a, vertical);
        final bc = _bandCenter(b, vertical);
        return vertical ? bc.compareTo(ac) : ac.compareTo(bc);
      });
    return ordered.map((band) {
      band.sort(vertical
          ? (a, b) {
              final top = a.top.compareTo(b.top);
              return top != 0 ? top : b.centerX.compareTo(a.centerX);
            }
          : (a, b) {
              final left = a.left.compareTo(b.left);
              return left != 0 ? left : a.top.compareTo(b.top);
            });
      return ComicTextBand<T>(band.map((box) => box.region).toList());
    }).toList();
  }

  ComicTextOrientation _orientation<T>(List<ComicTextRegion<T>> regions) {
    var verticalWeight = 0;
    var horizontalWeight = 0;
    final hasMultiCharacter = regions.any(
      (region) => _characterCount(region.text) > 1,
    );
    for (final region in regions) {
      final box = _positionBox(region);
      final characters = _characterCount(region.text);
      final aspect = _max(box.width, box.height) /
          _min(box.width, box.height);
      if (characters == 1 && (hasMultiCharacter || aspect < 1.8)) continue;
      final orientation = box.height >= box.width * 1.15
          ? ComicTextOrientation.vertical
          : box.width >= box.height * 1.15
              ? ComicTextOrientation.horizontal
              : region.orientation;
      final weight = characters.clamp(1, 12);
      if (orientation == ComicTextOrientation.vertical) {
        verticalWeight += weight;
      } else {
        horizontalWeight += weight;
      }
    }
    if (verticalWeight == horizontalWeight) {
      return sourceLanguage.split(RegExp('[-_]')).first.toLowerCase() == 'ja'
          ? ComicTextOrientation.vertical
          : ComicTextOrientation.horizontal;
    }
    return verticalWeight > horizontalWeight
        ? ComicTextOrientation.vertical
        : ComicTextOrientation.horizontal;
  }

  bool _related<T>(
    _RegionBox<T> a,
    _RegionBox<T> b,
    List<_RegionBox<T>> all,
    {StringBuffer? trace,}
  ) {
    final aGroup = a.region.bubbleGroupId;
    final bGroup = b.region.bubbleGroupId;
    final sameId = aGroup != null && aGroup == bGroup;
    final differentId = aGroup != null && bGroup != null && !sameId;
    final nativeGroupWeight =
        sourceLanguage.split(RegExp('[-_]')).first.toLowerCase() == 'ko'
            ? .10
            : .45;
    final duplicateBubble = _sameBubbleGeometry(a.region, b.region);
    final hasBubbleGeometry =
        a.region.bubblePolygon != null && b.region.bubblePolygon != null;
    final contained = _containedByBubble(a, b);
    final sameContainer = duplicateBubble || contained;
    final strongContainer = duplicateBubble;
    final groupContext = sameContainer || sameId;
    final similarBackground = _similarBackground(a.region, b.region, 40);
    final concavityWeight = duplicateBubble
        ? _concavityWeight(a.region.bubblePolygon!)
        : 0.0;
    final aOrientation = _orientation([a.region]);
    final bOrientation = _orientation([b.region]);
    if (aOrientation != bOrientation && !sameContainer) {
      trace?.write('reject=orientation');
      return false;
    }
    final context = sameContainer
        ? all.where((box) => _sharesVisualContainer(a, b, box)).toList()
        : sameId ? all.where((box) =>
            box.region.bubbleGroupId == aGroup).toList() : [a, b];
    final vertical = groupContext
        ? _orientation(context.map((box) => box.region).toList()) ==
            ComicTextOrientation.vertical
        : aOrientation == ComicTextOrientation.vertical;
    final measuredA = _characterSize(a, vertical);
    final measuredB = _characterSize(b, vertical);
    final dominantThickness = _dominantThickness(context, vertical);
    final aMeasuredText = _textBoundsAtSize(a, vertical, measuredA);
    final bMeasuredText = _textBoundsAtSize(b, vertical, measuredB);
    final rawCrossCenterDistance = vertical
        ? ((aMeasuredText.left + aMeasuredText.right) -
                (bMeasuredText.left + bMeasuredText.right)).abs() / 2
        : ((aMeasuredText.top + aMeasuredText.bottom) -
                (bMeasuredText.top + bMeasuredText.bottom)).abs() / 2;
    final rawCrossGap = vertical
        ? _gap(aMeasuredText.left, aMeasuredText.right,
            bMeasuredText.left, bMeasuredText.right)
        : _gap(aMeasuredText.top, aMeasuredText.bottom,
            bMeasuredText.top, bMeasuredText.bottom);
    final edgeProximity = (1 - rawCrossGap / (dominantThickness * 1.5))
        .clamp(0.0, 1.0);
    final centerProximity =
        (1 - rawCrossCenterDistance / (dominantThickness * 3))
            .clamp(0.0, 1.0);
    final proximity = edgeProximity * centerProximity;
    final bubbleCoverage = _min(
      _bubbleCoverage(a.region),
      _bubbleCoverage(b.region),
    );
    final aThickness = _effectiveCharacterSize(
      a,
      measuredA,
      dominantThickness,
      proximity,
    );
    final bThickness = _effectiveCharacterSize(
      b,
      measuredB,
      dominantThickness,
      proximity,
    );
    final characterSize = math.sqrt(aThickness * bThickness);
    final sizeRatio = _min(aThickness, bThickness) /
        _max(aThickness, bThickness);
    if (!groupContext && sizeRatio < .50) {
      trace?.write('reject=size ratio=${_number(sizeRatio)}');
      return false;
    }
    final aText = _textBoundsAtSize(a, vertical, aThickness);
    final bText = _textBoundsAtSize(b, vertical, bThickness);
    final crossOverlap = vertical
        ? _overlap(aText.left, aText.right, bText.left, bText.right) /
            _min(aText.width, bText.width)
        : _overlap(aText.top, aText.bottom, bText.top, bText.bottom) /
            _min(aText.height, bText.height);
    final aMainExtent = vertical ? aText.height : aText.width;
    final bMainExtent = vertical ? bText.height : bText.width;
    final mainOverlapLength = vertical
        ? _overlap(aText.top, aText.bottom, bText.top, bText.bottom)
        : _overlap(aText.left, aText.right, bText.left, bText.right);
    final shortMainOverlap = mainOverlapLength /
        _min(aMainExtent, bMainExtent);
    final longMainOverlap = mainOverlapLength /
        _max(aMainExtent, bMainExtent);
    final mainOverlapConfidence =
        shortMainOverlap * .72 + longMainOverlap * .28;
    final mainGap = vertical
        ? _gap(aText.top, aText.bottom, bText.top, bText.bottom)
        : _gap(aText.left, aText.right, bText.left, bText.right);
    final nearCrossDistance = rawCrossGap +
        (aThickness + bThickness) / 2;
    final correctedCrossDistance = _max(
      nearCrossDistance,
      _max(
        rawCrossCenterDistance * .65,
        rawCrossCenterDistance - dominantThickness * 1.15,
      ),
    );
    final crossCenterDistance = groupContext
        ? _min(rawCrossCenterDistance, correctedCrossDistance)
        : rawCrossCenterDistance;
    final crossCenterRatio = crossCenterDistance /
        (groupContext ? dominantThickness : characterSize);
    final weightedCrossRatio = _weightedDistance(crossCenterRatio);
    final overlapLimit = sameContainer ? 0.42 : 0.45;
    if (differentId && nativeGroupWeight > .10 &&
        crossCenterRatio < .72 && crossOverlap >= overlapLimit) {
      trace?.write('reject=overlapping-native-groups');
      return false;
    }
    final sameBandGap = sameContainer
        ? hasBubbleGeometry ? 1.8 - concavityWeight * .9 : 2.4
        : 1.6;
    final sameBand = crossCenterRatio < .72 &&
        crossOverlap >= overlapLimit &&
        mainGap <= dominantThickness * sameBandGap &&
        similarBackground &&
        (!differentId || nativeGroupWeight <= .10);
    final nativeLimitAdjustment =
        differentId ? -1.4 * nativeGroupWeight : 0.0;
    final backgroundLimitAdjustment = similarBackground ? 0.0 : -.35;
    final adjacentLimit = strongContainer
        ? 2.75 - concavityWeight * .40
        : groupContext
            ? 2.3 + backgroundLimitAdjustment
            : 1.8 + nativeLimitAdjustment + backgroundLimitAdjustment;
    final aCharacters = _characterCount(a.region.text);
    final bCharacters = _characterCount(b.region.text);
    final singleCharacter = _min(aCharacters, bCharacters) == 1 &&
        _max(aCharacters, bCharacters) > 1;
    final effectiveAdjacentLimit = strongContainer &&
            singleCharacter && crossOverlap < .05
        ? _min(adjacentLimit, 1.35)
        : adjacentLimit;
    final shortFragment = _min(aMainExtent, bMainExtent) <=
        characterSize * 1.55;
    final endpointContact = shortFragment &&
        mainGap <= characterSize * .65;
    final nativeOverlapAdjustment = sameId
        ? -.05 * nativeGroupWeight
        : differentId ? .18 * nativeGroupWeight : 0.0;
    final overlapContact = mainOverlapConfidence >=
        (sameContainer ? .38 : .48 + nativeOverlapAdjustment) +
            (similarBackground ? 0 : .08);
    final boundaryReliable = !hasBubbleGeometry ||
        bubbleCoverage >= .60 ||
        crossCenterRatio <= 1.30 ||
        endpointContact;
    final adjacentBand = !sameBand &&
        weightedCrossRatio <= effectiveAdjacentLimit &&
        (overlapContact || endpointContact) &&
        boundaryReliable;
    final related = sameBand || adjacentBand;
    if (trace != null) {
      trace.write(
        'v=$vertical measured=${_number(measuredA)}/${_number(measuredB)} '
        'effective=${_number(aThickness)}/${_number(bThickness)} '
        'body=${_number(dominantThickness)} '
        'text=${_boundsText(aText)}/${_boundsText(bText)} '
        'crossCenter=${_number(crossCenterRatio)} '
        'weighted=${_number(weightedCrossRatio)} '
        'limit=${_number(effectiveAdjacentLimit)} '
        'crossOverlap=${_number(crossOverlap)} '
        'mainOverlap=${_number(shortMainOverlap)}/'
        '${_number(longMainOverlap)}/${_number(mainOverlapConfidence)} '
        'mainGap=${_number(mainGap / dominantThickness)} '
        'same=$sameBand adjacent=$adjacentBand overlap=$overlapContact '
        'endpoint=$endpointContact boundary=$boundaryReliable '
        'coverage=${_number(bubbleCoverage)} concavity=${_number(concavityWeight)} '
        'background=${similarBackground ? 'same' : 'different'} '
        'single=$singleCharacter '
        'native=${sameId ? 'same' : differentId ? 'different' : 'none'}:'
        '${_number(nativeGroupWeight)}',
      );
    }
    return related;
  }

  bool _directionallySeparated<T>(
    _RegionBox<T> a,
    _RegionBox<T> b,
    List<_RegionBox<T>> all,
    {StringBuffer? trace,}
  ) {
    final sameId = a.region.bubbleGroupId != null &&
        a.region.bubbleGroupId == b.region.bubbleGroupId;
    final sameGeometry = _sameBubbleGeometry(a.region, b.region);
    if (!sameId && !sameGeometry) {
      trace?.write('skip=different-container');
      return false;
    }
    if (_characterCount(a.region.text) == 1 ||
        _characterCount(b.region.text) == 1) {
      trace?.write('skip=single-character');
      return false;
    }
    final container = all.where((box) => _sharesContainer(a, b, box)).toList();
    final vertical = _orientation(container.map((box) => box.region).toList()) ==
        ComicTextOrientation.vertical;
    final dominantThickness = _dominantThickness(container, vertical);
    final aText = _textBounds(a, vertical);
    final bText = _textBounds(b, vertical);
    final crossCenterDistance = vertical
        ? ((aText.left + aText.right) - (bText.left + bText.right)).abs() / 2
        : ((aText.top + aText.bottom) - (bText.top + bText.bottom)).abs() / 2;
    if (crossCenterDistance / dominantThickness < .72) {
      trace?.write('skip=same-column crossCenter='
          '${_number(crossCenterDistance / dominantThickness)}');
      return false;
    }
    final crossGap = vertical
        ? _gap(aText.left, aText.right, bText.left, bText.right)
        : _gap(aText.top, aText.bottom, bText.top, bText.bottom);
    final mainOverlap = vertical
        ? _overlap(aText.top, aText.bottom, bText.top, bText.bottom) /
            _min(aText.height, bText.height)
        : _overlap(aText.left, aText.right, bText.left, bText.right) /
            _min(aText.width, bText.width);
    final separated = crossGap / dominantThickness < .30 &&
        mainOverlap < .30;
    trace?.write(
      'crossCenter=${_number(crossCenterDistance / dominantThickness)} '
      'crossGap=${_number(crossGap / dominantThickness)} '
      'mainOverlap=${_number(mainOverlap)}',
    );
    return separated;
  }

  double _relationDistance<T>(
    _RegionBox<T> a,
    _RegionBox<T> b,
    List<_RegionBox<T>> all,
  ) {
    final container = all
        .where((box) => _sharesVisualContainer(a, b, box))
        .toList();
    if (container.isEmpty) container.addAll([a, b]);
    final vertical = _orientation(container.map((box) => box.region).toList()) ==
        ComicTextOrientation.vertical;
    final aText = _textBounds(a, vertical);
    final bText = _textBounds(b, vertical);
    final aMainExtent = vertical ? aText.height : aText.width;
    final bMainExtent = vertical ? bText.height : bText.width;
    final overlap = vertical
        ? _overlap(aText.top, aText.bottom, bText.top, bText.bottom)
        : _overlap(aText.left, aText.right, bText.left, bText.right);
    final mainOverlap = overlap / _min(aMainExtent, bMainExtent) * .72 +
        overlap / _max(aMainExtent, bMainExtent) * .28;
    final crossOverlap = vertical
        ? _overlap(aText.left, aText.right, bText.left, bText.right) /
            _min(aText.width, bText.width)
        : _overlap(aText.top, aText.bottom, bText.top, bText.bottom) /
            _min(aText.height, bText.height);
    final mainGap = vertical
        ? _gap(aText.top, aText.bottom, bText.top, bText.bottom)
        : _gap(aText.left, aText.right, bText.left, bText.right);
    final crossGap = vertical
        ? _gap(aText.left, aText.right, bText.left, bText.right)
        : _gap(aText.top, aText.bottom, bText.top, bText.bottom);
    final scale = math.sqrt(
      _characterSize(a, vertical) * _characterSize(b, vertical),
    );
    final crossCenterDistance = vertical
        ? ((aText.left + aText.right) - (bText.left + bText.right)).abs() / 2
        : ((aText.top + aText.bottom) - (bText.top + bText.bottom)).abs() / 2;
    final distance = crossCenterDistance / scale >= .72
        ? crossGap / scale + (1 - mainOverlap) * 1.5 +
            mainGap / scale * .35
        : mainGap / scale + (1 - crossOverlap) * .8 +
            (1 - mainOverlap) * 1.2;
    final sameId = a.region.bubbleGroupId != null &&
        a.region.bubbleGroupId == b.region.bubbleGroupId;
    return sameId ? distance * .96 : distance;
  }

  double _bubbleCoverage<T>(ComicTextRegion<T> region) {
    final bubble = region.bubblePolygon;
    if (bubble == null) return 1;
    final points = _positionPoints(region);
    final center = points.fold(
      const NormalizedPoint(0, 0),
      (sum, point) => NormalizedPoint(sum.x + point.x, sum.y + point.y),
    );
    final samples = [
      ...points,
      NormalizedPoint(
        center.x / points.length,
        center.y / points.length,
      ),
    ];
    return samples.where((point) => _contains(bubble, point)).length /
        samples.length;
  }

  double _concavityWeight(List<NormalizedPoint> polygon) {
    final solidity = _polygonArea(polygon) /
        _polygonArea(_convexHull(polygon));
    final confidence = ((1 - solidity - .02) / .14).clamp(0.0, 1.0);
    return confidence * confidence;
  }

  List<NormalizedPoint> _convexHull(List<NormalizedPoint> polygon) {
    final points = polygon.toList()..sort((a, b) {
      final x = a.x.compareTo(b.x);
      return x != 0 ? x : a.y.compareTo(b.y);
    });
    double cross(NormalizedPoint o, NormalizedPoint a, NormalizedPoint b) =>
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    final lower = <NormalizedPoint>[];
    for (final point in points) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, point) <= 0) {
        lower.removeLast();
      }
      lower.add(point);
    }
    final upper = <NormalizedPoint>[];
    for (final point in points.reversed) {
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, point) <= 0) {
        upper.removeLast();
      }
      upper.add(point);
    }
    return [...lower.take(lower.length - 1), ...upper.take(upper.length - 1)];
  }

  double _polygonArea(List<NormalizedPoint> polygon) {
    var area = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      area += a.x * b.y - b.x * a.y;
    }
    return area.abs() / 2;
  }

  bool _sharesContainer<T>(
    _RegionBox<T> a,
    _RegionBox<T> b,
    _RegionBox<T> candidate,
  ) {
    final group = a.region.bubbleGroupId ?? b.region.bubbleGroupId;
    if (group != null && candidate.region.bubbleGroupId == group) return true;
    return _sameBubbleGeometry(a.region, candidate.region) ||
        _sameBubbleGeometry(b.region, candidate.region) ||
        _containedByBubble(a, candidate) ||
        _containedByBubble(b, candidate);
  }

  bool _sharesVisualContainer<T>(
    _RegionBox<T> a,
    _RegionBox<T> b,
    _RegionBox<T> candidate,
  ) => _sameBubbleGeometry(a.region, candidate.region) ||
      _sameBubbleGeometry(b.region, candidate.region) ||
      _containedByBubble(a, candidate) ||
      _containedByBubble(b, candidate);

  double _dominantThickness<T>(
    List<_RegionBox<T>> boxes,
    bool vertical,
  ) {
    final values = boxes
        .map((box) => _characterSize(box, vertical))
        .where((value) => value > 0)
        .toList()
      ..sort();
    var bestStart = 0;
    var bestEnd = 1;
    for (var start = 0; start < values.length; start++) {
      var end = start + 1;
      while (end < values.length && values[end] <= values[start] * 1.35) {
        end++;
      }
      if (end - start > bestEnd - bestStart) {
        bestStart = start;
        bestEnd = end;
      }
    }
    final cluster = values.sublist(bestStart, bestEnd);
    return cluster[cluster.length ~/ 2];
  }

  int _characterCount(String text) => text
      .replaceAll(RegExp(r'\s'), '')
      .runes
      .length
      .clamp(1, 1000);

  double _characterSize<T>(_RegionBox<T> box, bool vertical) {
    final characters = _characterCount(box.region.text);
    final crossExtent = vertical ? box.width : box.height;
    if (characters == 1) return crossExtent;
    final mainExtent = vertical ? box.height : box.width;
    return math.sqrt(crossExtent * mainExtent / characters);
  }

  double _effectiveCharacterSize<T>(
    _RegionBox<T> box,
    double measured,
    double bodySize,
    double proximity,
  ) {
    if (measured <= bodySize * 1.15) return measured;
    final insideBubble = box.region.bubblePolygon != null &&
        _bubbleCoverage(box.region) >= .60;
    final confidence = (insideBubble ? .45 : 1.0) *
        (1 - proximity * .55);
    return bodySize + (measured - bodySize) * confidence;
  }

  _Bounds _textBounds<T>(_RegionBox<T> box, bool vertical) {
    final characterSize = _characterSize(box, vertical);
    return _textBoundsAtSize(box, vertical, characterSize);
  }

  _Bounds _textBoundsAtSize<T>(
    _RegionBox<T> box,
    bool vertical,
    double characterSize,
  ) {
    final mainExtent = characterSize * _characterCount(box.region.text);
    final position = _positionBox(box.region);
    final inkCenterX = position.centerX.clamp(box.left, box.right).toDouble();
    final inkCenterY = position.centerY.clamp(box.top, box.bottom).toDouble();
    return vertical
        ? _Bounds(
            inkCenterX - characterSize / 2,
            box.centerY - mainExtent / 2,
            inkCenterX + characterSize / 2,
            box.centerY + mainExtent / 2,
          )
        : _Bounds(
            box.centerX - mainExtent / 2,
            inkCenterY - characterSize / 2,
            box.centerX + mainExtent / 2,
            inkCenterY + characterSize / 2,
          );
  }

  bool _containedByBubble<T>(_RegionBox<T> a, _RegionBox<T> b) {
    bool contains(ComicTextRegion<T> owner, _RegionBox<T> other) {
      final polygon = owner.bubblePolygon;
      if (polygon == null ||
          !_similarBackground(owner, other.region, 48)) {
        return false;
      }
      final position = _positionBox(other.region);
      return _contains(
        polygon,
        NormalizedPoint(
          position.centerX / imageWidth,
          position.centerY / imageHeight,
        ),
      );
    }
    return contains(a.region, b) || contains(b.region, a);
  }

  bool _sameBubbleGeometry<T>(ComicTextRegion<T> a, ComicTextRegion<T> b) {
    final aa = a.bubblePolygon;
    final bb = b.bubblePolygon;
    if (aa == null || bb == null || !_similarBackground(a, b, 48)) return false;
    final ab = _polygonBounds(aa);
    final bounds = _polygonBounds(bb);
    final aArea = ab.width * ab.height;
    final bArea = bounds.width * bounds.height;
    if (_max(aArea, bArea) / _min(aArea, bArea) > 1.8) return false;
    final intersection = _overlap(ab.left, ab.right, bounds.left, bounds.right) *
        _overlap(ab.top, ab.bottom, bounds.top, bounds.bottom);
    return intersection / _min(aArea, bArea) >= 0.72;
  }

  bool _similarBackground<T>(
    ComicTextRegion<T> a,
    ComicTextRegion<T> b,
    int tolerance,
  ) {
    final aa = a.backgroundArgb;
    final bb = b.backgroundArgb;
    if (aa == null || bb == null) return true;
    int channel(int value, int shift) => (value >> shift) & 0xff;
    return [0, 8, 16].every((shift) =>
        (channel(aa, shift) - channel(bb, shift)).abs() <= tolerance);
  }

  double _groupOrder<T>(ResolvedComicTextGroup<T> group) {
    final boxes = group.regions.map(_box);
    return boxes.map((box) => box.top).reduce(_min) * imageWidth +
        boxes.map((box) => box.left).reduce(_min);
  }

  _RegionBox<T> _box<T>(ComicTextRegion<T> region) {
    final points = region.polygon;
    final xs = points.map((point) => point.x * imageWidth);
    final ys = points.map((point) => point.y * imageHeight);
    return _RegionBox(
      region,
      xs.reduce(_min),
      ys.reduce(_min),
      xs.reduce(_max),
      ys.reduce(_max),
    );
  }

  _RegionBox<T> _positionBox<T>(ComicTextRegion<T> region) {
    final points = _positionPoints(region);
    final xs = points.map((point) => point.x * imageWidth);
    final ys = points.map((point) => point.y * imageHeight);
    return _RegionBox(
      region,
      xs.reduce(_min),
      ys.reduce(_min),
      xs.reduce(_max),
      ys.reduce(_max),
    );
  }

  List<NormalizedPoint> _positionPoints<T>(ComicTextRegion<T> region) =>
      region.sourceMaskPolygons.isEmpty
          ? region.polygon
          : region.sourceMaskPolygons.expand((polygon) => polygon).toList();

  _Bounds _polygonBounds(List<NormalizedPoint> polygon) {
    final xs = polygon.map((point) => point.x * imageWidth);
    final ys = polygon.map((point) => point.y * imageHeight);
    return _Bounds(
      xs.reduce(_min),
      ys.reduce(_min),
      xs.reduce(_max),
      ys.reduce(_max),
    );
  }

  bool _contains(List<NormalizedPoint> polygon, NormalizedPoint point) {
    var inside = false;
    var previous = polygon.last;
    for (final current in polygon) {
      if ((current.y > point.y) != (previous.y > point.y) &&
          point.x <
              (previous.x - current.x) * (point.y - current.y) /
                      (previous.y - current.y) +
                  current.x) {
        inside = !inside;
      }
      previous = current;
    }
    return inside;
  }

  double _bandCenter<T>(List<_RegionBox<T>> band, bool vertical) =>
      band.fold(
        0.0,
        (sum, box) {
          final bounds = _textBounds(box, vertical);
          return sum + (vertical
              ? (bounds.left + bounds.right) / 2
              : (bounds.top + bounds.bottom) / 2);
        },
      ) /
      band.length;

  double _overlap(double a0, double a1, double b0, double b1) =>
      _max(0, _min(a1, b1) - _max(a0, b0));

  double _gap(double a0, double a1, double b0, double b1) =>
      _max(0, _max(a0, b0) - _min(a1, b1));

  double _weightedDistance(double value) {
    final excess = _max(0, value - 1.9);
    return value + excess * excess * 2;
  }

  String _boundsText(_Bounds bounds) =>
      '[${_number(bounds.left / imageWidth)},'
      '${_number(bounds.top / imageHeight)},'
      '${_number(bounds.right / imageWidth)},'
      '${_number(bounds.bottom / imageHeight)}]';

  String _number(num value) => value.toStringAsFixed(3);

  double _min(num a, num b) => a < b ? a.toDouble() : b.toDouble();

  double _max(num a, num b) => a > b ? a.toDouble() : b.toDouble();
}

final class _Bounds {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const _Bounds(this.left, this.top, this.right, this.bottom);

  double get width => right - left;

  double get height => bottom - top;
}

final class _RegionBox<T> extends _Bounds {
  final ComicTextRegion<T> region;

  const _RegionBox(
    this.region,
    super.left,
    super.top,
    super.right,
    super.bottom,
  );

  double get centerX => (left + right) / 2;

  double get centerY => (top + bottom) / 2;
}

final class _GroupingEdge {
  final int a;
  final int b;
  final double distance;

  const _GroupingEdge(this.a, this.b, this.distance);
}
