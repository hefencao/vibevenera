import 'dart:math' as math;
import 'dart:ui';

enum ComicBubbleBoundarySource { confirmed, candidate, combined }

final class ComicBubbleBoundaryDecision {
  final bool initialOpen;
  final int nearbyCandidates;
  final List<List<Offset>>? polygons;
  final ComicBubbleBoundarySource? source;
  final bool relaxed;
  final Rect sourceBounds;
  final Rect? boundaryBounds;

  const ComicBubbleBoundaryDecision({
    required this.initialOpen,
    required this.nearbyCandidates,
    required this.polygons,
    required this.source,
    required this.relaxed,
    required this.sourceBounds,
    required this.boundaryBounds,
  });

  bool get formedBoundary => initialOpen && polygons != null;
}

ComicBubbleBoundaryDecision exploreComicBubbleBoundary({
  required List<Rect> inkBounds,
  required List<List<Offset>> confirmedPolygons,
  required List<List<Offset>> candidatePolygons,
}) {
  final sourceBounds = inkBounds
      .reduce((value, next) => value.expandToInclude(next));
  final searchMargin = math.max(
    4.0,
    inkBounds.map((bounds) => math.min(bounds.width, bounds.height))
        .reduce(math.max) * 1.5,
  );
  final searchBounds = sourceBounds.inflate(searchMargin);
  final candidates = candidatePolygons
      .where((polygon) => _bounds(polygon).overlaps(searchBounds))
      .toList();

  bool covers(List<List<Offset>> polygons, bool relaxed) => inkBounds.every(
    (bounds) {
      final core = Rect.fromCenter(
        center: bounds.center,
        width: bounds.width * .6,
        height: bounds.height * .6,
      );
      final samples = [
        core.center,
        core.topCenter,
        core.centerRight,
        core.bottomCenter,
        core.centerLeft,
      ];
      final covered = samples.where((point) =>
          polygons.any((polygon) => _contains(polygon, point))).length;
      return relaxed
          ? polygons.any((polygon) => _contains(polygon, samples.first)) &&
              covered >= 3
          : covered == samples.length;
    },
  );

  ({List<List<Offset>> polygons, ComicBubbleBoundarySource source,
      double area})? select(
    List<({List<List<Offset>> polygons, ComicBubbleBoundarySource source})>
        options,
    bool relaxed,
  ) {
    ({List<List<Offset>> polygons, ComicBubbleBoundarySource source,
        double area})? best;
    for (final option in options) {
      if (!covers(option.polygons, relaxed)) continue;
      final bounds = _bounds(option.polygons.expand((value) => value));
      final value = (
        polygons: option.polygons,
        source: option.source,
        area: bounds.width * bounds.height,
      );
      if (best == null || value.area < best.area) best = value;
    }
    return best;
  }

  final confirmedOptions = confirmedPolygons.isEmpty
      ? const <({List<List<Offset>> polygons,
          ComicBubbleBoundarySource source})>[]
      : [(polygons: confirmedPolygons,
          source: ComicBubbleBoundarySource.confirmed)];
  final confirmed = select(confirmedOptions, false);
  if (confirmed != null) {
    return ComicBubbleBoundaryDecision(
      initialOpen: false,
      nearbyCandidates: candidates.length,
      polygons: confirmed.polygons,
      source: confirmed.source,
      relaxed: false,
      sourceBounds: sourceBounds,
      boundaryBounds: _bounds(confirmed.polygons.expand((value) => value)),
    );
  }

  final options = <({List<List<Offset>> polygons,
      ComicBubbleBoundarySource source})>[];
  for (final candidate in candidates) {
    options.add((
      polygons: [candidate],
      source: ComicBubbleBoundarySource.candidate,
    ));
    if (confirmedPolygons.isNotEmpty) {
      options.add((
        polygons: [...confirmedPolygons, candidate],
        source: ComicBubbleBoundarySource.combined,
      ));
    }
  }
  if (candidates.length > 1) {
    options.add((
      polygons: candidates,
      source: ComicBubbleBoundarySource.candidate,
    ));
    if (confirmedPolygons.isNotEmpty) {
      options.add((
        polygons: [...confirmedPolygons, ...candidates],
        source: ComicBubbleBoundarySource.combined,
      ));
    }
  }
  final strict = select(options, false);
  final selected = strict ?? select(options, true);
  return ComicBubbleBoundaryDecision(
    initialOpen: true,
    nearbyCandidates: candidates.length,
    polygons: selected?.polygons,
    source: selected?.source,
    relaxed: strict == null && selected != null,
    sourceBounds: sourceBounds,
    boundaryBounds: selected == null
        ? null
        : _bounds(selected.polygons.expand((value) => value)),
  );
}

Rect comicBubbleInnerBounds({
  required List<List<Offset>> polygons,
  required Rect sourceBounds,
  required Offset sourceCenter,
  required double sourceFontSize,
}) {
  var bubble = Path()..addPolygon(polygons.first, true);
  for (final polygon in polygons.skip(1)) {
    bubble = Path.combine(
      PathOperation.union,
      bubble,
      Path()..addPolygon(polygon, true),
    );
  }
  final bubbleBounds = _bounds(polygons.expand((polygon) => polygon));
  final inset = math.max(2.0, sourceFontSize * .12);
  final requiredWidth = sourceBounds.width + inset * 2;
  final requiredHeight = sourceBounds.height + inset * 2;
  Rect candidateAt(Offset center) {
    final maxWidth = 2.0 * math.min(
      center.dx - bubbleBounds.left,
      bubbleBounds.right - center.dx,
    );
    final maxHeight = 2.0 * math.min(
      center.dy - bubbleBounds.top,
      bubbleBounds.bottom - center.dy,
    );
    if (maxWidth <= 0 || maxHeight <= 0) return Rect.zero;
    Rect best = Rect.zero;
    Rect fittingSource = Rect.zero;
    final widths = <double>[
      sourceBounds.width.clamp(0.0, maxWidth).toDouble(),
      for (var step = 1; step <= 16; step++) maxWidth * step / 16,
    ]..sort();
    double previous = -1;
    for (final width in widths) {
      if ((width - previous).abs() < .25) continue;
      previous = width;
      var low = 0.0;
      var high = maxHeight;
      for (var step = 0; step < 10; step++) {
        final height = (low + high) / 2;
        final candidate = Rect.fromCenter(
          center: center,
          width: width,
          height: height,
        );
        if (_rectFitsBubble(bubble, candidate)) {
          low = height;
        } else {
          high = height;
        }
      }
      final candidate = Rect.fromCenter(
        center: center,
        width: width,
        height: low,
      );
      if (candidate.width * candidate.height > best.width * best.height) {
        best = candidate;
      }
      if (candidate.width >= requiredWidth &&
          candidate.height >= requiredHeight &&
          candidate.width * candidate.height >
              fittingSource.width * fittingSource.height) {
        fittingSource = candidate;
      }
    }
    return fittingSource.isEmpty ? best : fittingSource;
  }

  final centroid = _bubbleCentroid(polygons);
  final center = bubble.contains(sourceCenter)
      ? sourceCenter
      : bubble.contains(sourceBounds.center)
          ? sourceBounds.center
          : bubble.contains(centroid)
              ? centroid
              : bubbleBounds.center;
  final delta = centroid - center;
  final travel = math.min(delta.distance, sourceFontSize);
  final end = delta.distance == 0
      ? center
      : center + delta / delta.distance * travel;
  final candidates = [
    center,
    Offset.lerp(center, end, .5)!,
    end,
  ].where(bubble.contains).map(candidateAt).toList();
  final fitting = candidates.where((candidate) =>
      candidate.width >= requiredWidth &&
      candidate.height >= requiredHeight).toList();
  final choices = fitting.isEmpty ? candidates : fitting;
  final best = choices.reduce((value, next) =>
      next.width * next.height > value.width * value.height ? next : value);
  return best.deflate(inset);
}

Rect _bounds(Iterable<Offset> points) {
  final values = points.toList();
  return Rect.fromLTRB(
    values.map((point) => point.dx).reduce(math.min),
    values.map((point) => point.dy).reduce(math.min),
    values.map((point) => point.dx).reduce(math.max),
    values.map((point) => point.dy).reduce(math.max),
  );
}

bool _contains(List<Offset> polygon, Offset point) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i];
    final b = polygon[j];
    if ((a.dy > point.dy) != (b.dy > point.dy) &&
        point.dx < (b.dx - a.dx) * (point.dy - a.dy) /
            (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
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

Offset _bubbleCentroid(List<List<Offset>> polygons) {
  var total = 0.0;
  var x = 0.0;
  var y = 0.0;
  for (final polygon in polygons) {
    var twiceArea = 0.0;
    for (var index = 0; index < polygon.length; index++) {
      final a = polygon[index];
      final b = polygon[(index + 1) % polygon.length];
      twiceArea += a.dx * b.dy - b.dx * a.dy;
    }
    final area = twiceArea.abs() / 2;
    final center = _polygonCentroid(polygon);
    total += area;
    x += center.dx * area;
    y += center.dy * area;
  }
  return total == 0
      ? _bounds(polygons.expand((polygon) => polygon)).center
      : Offset(x / total, y / total);
}

bool _rectFitsBubble(Path path, Rect rect) {
  if (rect.width <= 0 || rect.height <= 0) return path.contains(rect.center);
  for (var step = 0; step <= 4; step++) {
    final factor = step / 4;
    if (!path.contains(Offset(rect.left + rect.width * factor, rect.top)) ||
        !path.contains(Offset(rect.left + rect.width * factor, rect.bottom)) ||
        !path.contains(Offset(rect.left, rect.top + rect.height * factor)) ||
        !path.contains(Offset(rect.right, rect.top + rect.height * factor))) {
      return false;
    }
  }
  return path.contains(rect.center);
}
