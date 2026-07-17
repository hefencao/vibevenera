import 'dart:math' as math;

import 'models.dart';

final class ComicTextRegion<T> {
  final T value;
  final String id;
  final String text;
  final List<NormalizedPoint> polygon;
  final ComicTextOrientation orientation;
  final int? backgroundArgb;
  final int? bubbleGroupId;
  final List<NormalizedPoint>? bubblePolygon;

  const ComicTextRegion({
    required this.value,
    required this.id,
    required this.text,
    required this.polygon,
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
          edges.add(_GroupingEdge(i, j, _relationDistance(boxes[i], boxes[j])));
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

  List<ComicTextBand<T>> _bands<T>(
    List<ComicTextRegion<T>> regions,
    ComicTextOrientation orientation,
  ) {
    final boxes = regions.map(_box).toList();
    final vertical = orientation == ComicTextOrientation.vertical;
    final dominantThickness = _dominantThickness(boxes);
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
        final overlap = vertical
            ? _overlap(boxes[i].left, boxes[i].right,
                    boxes[j].left, boxes[j].right) /
                _min(boxes[i].width, boxes[j].width)
            : _overlap(boxes[i].top, boxes[i].bottom,
                    boxes[j].top, boxes[j].bottom) /
                _min(boxes[i].height, boxes[j].height);
        final centerDistance = vertical
            ? (boxes[i].centerX - boxes[j].centerX).abs()
            : (boxes[i].centerY - boxes[j].centerY).abs();
        if (overlap >= 0.45 ||
            centerDistance <= dominantThickness * 0.62) {
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
    for (final region in regions) {
      final box = _box(region);
      final orientation = box.height >= box.width * 1.15
          ? ComicTextOrientation.vertical
          : box.width >= box.height * 1.15
              ? ComicTextOrientation.horizontal
              : region.orientation;
      final weight = region.text.runes.length.clamp(1, 12);
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
  ) {
    final aGroup = a.region.bubbleGroupId;
    final bGroup = b.region.bubbleGroupId;
    final sameId = aGroup != null && aGroup == bGroup;
    final duplicateBubble = _sameBubbleGeometry(a.region, b.region);
    final hasBubbleGeometry =
        a.region.bubblePolygon != null && b.region.bubblePolygon != null;
    final sameIdContainer = sameId && (!hasBubbleGeometry || duplicateBubble);
    final contained = aGroup == null || bGroup == null
        ? _containedByBubble(a, b)
        : false;
    final sameContainer = sameIdContainer || duplicateBubble || contained;
    final strongContainer = sameIdContainer || duplicateBubble;
    if (aGroup != null && bGroup != null && !sameContainer) return false;
    final mixedBubble = !sameContainer && (aGroup == null) != (bGroup == null);
    if (!sameContainer && !_similarBackground(a.region, b.region, 40)) {
      return false;
    }
    final aOrientation = _orientation([a.region]);
    final bOrientation = _orientation([b.region]);
    if (aOrientation != bOrientation && !sameContainer) return false;
    final vertical = sameContainer
        ? _orientation([a.region, b.region]) == ComicTextOrientation.vertical
        : aOrientation == ComicTextOrientation.vertical;
    final aThickness = _fontSize(a);
    final bThickness = _fontSize(b);
    if (_min(aThickness, bThickness) / _max(aThickness, bThickness) <
        (sameContainer ? 0.28 : 0.50)) {
      return false;
    }
    final crossOverlap = vertical
        ? _overlap(a.left, a.right, b.left, b.right) /
            _min(a.width, b.width)
        : _overlap(a.top, a.bottom, b.top, b.bottom) /
            _min(a.height, b.height);
    final mainOverlap = vertical
        ? _overlap(a.top, a.bottom, b.top, b.bottom) /
            _min(a.height, b.height)
        : _overlap(a.left, a.right, b.left, b.right) /
            _min(a.width, b.width);
    final mainGap = vertical
        ? _gap(a.top, a.bottom, b.top, b.bottom)
        : _gap(a.left, a.right, b.left, b.right);
    final mainStartOffset = vertical
        ? (a.top - b.top).abs()
        : (a.left - b.left).abs();
    final mainExtent = vertical
        ? _min(a.height, b.height)
        : _min(a.width, b.width);
    final crossGap = vertical
        ? _gap(a.left, a.right, b.left, b.right)
        : _gap(a.top, a.bottom, b.top, b.bottom);
    final container = sameContainer
        ? all.where((box) => _sharesContainer(a, b, box)).toList()
        : [a, b];
    final dominantThickness = _dominantThickness(container);
    final overlapLimit = mixedBubble ? 0.60 : 0.45;
    final sameBandGap = sameContainer
        ? hasBubbleGeometry ? 0.8 : 2.4
        : 1.6;
    final sameBand = crossOverlap >= overlapLimit &&
        mainGap <= dominantThickness * sameBandGap &&
        (!hasBubbleGeometry || mainStartOffset <= mainExtent * .85);
    final adjacentBand = crossGap <=
            dominantThickness *
                (strongContainer ? 1.8 : sameContainer ? 1.25 : 0.85) &&
        ((mainOverlap >= overlapLimit && mainStartOffset <= mainExtent * .55) ||
            (sameContainer && !hasBubbleGeometry));
    return sameBand || adjacentBand;
  }

  bool _directionallySeparated<T>(
    _RegionBox<T> a,
    _RegionBox<T> b,
    List<_RegionBox<T>> all,
  ) {
    final sameId = a.region.bubbleGroupId != null &&
        a.region.bubbleGroupId == b.region.bubbleGroupId;
    if (!sameId && !_sameBubbleGeometry(a.region, b.region)) return false;
    final vertical = _orientation([a.region, b.region]) ==
        ComicTextOrientation.vertical;
    final crossOverlap = vertical
        ? _overlap(a.left, a.right, b.left, b.right) /
            _min(a.width, b.width)
        : _overlap(a.top, a.bottom, b.top, b.bottom) /
            _min(a.height, b.height);
    if (crossOverlap < 0.45) return false;
    final mainGap = vertical
        ? _gap(a.top, a.bottom, b.top, b.bottom)
        : _gap(a.left, a.right, b.left, b.right);
    final container = all.where((box) => _sharesContainer(a, b, box)).toList();
    return mainGap > _dominantThickness(container) * 0.8;
  }

  double _relationDistance<T>(_RegionBox<T> a, _RegionBox<T> b) {
    final dx = a.centerX - b.centerX;
    final dy = a.centerY - b.centerY;
    return math.sqrt(dx * dx + dy * dy) /
        math.sqrt(_fontSize(a) * _fontSize(b));
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

  double _dominantThickness<T>(List<_RegionBox<T>> boxes) {
    final values = boxes
        .map(_fontSize)
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

  double _fontSize<T>(_RegionBox<T> box) {
    final characters = box.region.text
        .replaceAll(RegExp(r'\s'), '')
        .runes
        .length
        .clamp(1, 1000);
    return math.sqrt(box.width * box.height / characters);
  }

  bool _containedByBubble<T>(_RegionBox<T> a, _RegionBox<T> b) {
    bool contains(ComicTextRegion<T> owner, _RegionBox<T> other) {
      final polygon = owner.bubblePolygon;
      if (polygon == null ||
          !_similarBackground(owner, other.region, 48)) {
        return false;
      }
      return _contains(
        polygon,
        NormalizedPoint(
          other.centerX / imageWidth,
          other.centerY / imageHeight,
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
    final xs = region.polygon.map((point) => point.x * imageWidth);
    final ys = region.polygon.map((point) => point.y * imageHeight);
    return _RegionBox(
      region,
      xs.reduce(_min),
      ys.reduce(_min),
      xs.reduce(_max),
      ys.reduce(_max),
    );
  }

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
        (sum, box) => sum + (vertical ? box.centerX : box.centerY),
      ) /
      band.length;

  double _overlap(double a0, double a1, double b0, double b1) =>
      _max(0, _min(a1, b1) - _max(a0, b0));

  double _gap(double a0, double a1, double b0, double b1) =>
      _max(0, _max(a0, b0) - _min(a1, b1));

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
