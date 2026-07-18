part of 'reader.dart';

class _TranslationLayoutCache {
  final Map<String, _TranslationLayoutPlan> plans = {};
  final Map<String, _TranslationBlockGeometry> geometries = {};
  final Map<String, _TranslationPreparedBlock> prepared = {};
  final Set<String> preparedRegionIds = {};
  final ValueNotifier<int> repaint = ValueNotifier(0);
  final Set<String> skipped = {};
  final Map<String, _VerticalGlyphMetrics> verticalMetrics = {};
  final Map<String, double> horizontalWidthFactors = {};
  List<_TranslationLayoutBlock>? blocks;
  Rect? imageRect;
  _TranslationLayoutSearch? search;
  _TranslationRenderPreparation? render;
  Color? renderBackground;
  Color? renderForeground;
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
  }) : super(repaint: layoutCache.repaint);

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
    layoutCache.geometries.clear();
    layoutCache.prepared.clear();
    layoutCache.preparedRegionIds.clear();
    layoutCache.skipped.clear();
    layoutCache.search = null;
    layoutCache.render = null;
  }

  void _syncVisualStyle() {
    if (layoutCache.renderBackground == background &&
        layoutCache.renderForeground == foreground) {
      return;
    }
    layoutCache.renderBackground = background;
    layoutCache.renderForeground = foreground;
    layoutCache.prepared.clear();
    layoutCache.preparedRegionIds.clear();
    layoutCache.render = null;
  }

  bool isPreparedFor(Size size) {
    _syncVisualStyle();
    if (_layoutImageRect != _imageRect(size)) return false;
    if (layoutCache.search != null || layoutCache.render != null) return false;
    return _layoutBlocks().every((block) =>
        layoutCache.prepared.containsKey(block.key) ||
        layoutCache.skipped.contains(block.key));
  }

  bool prepareNext(Size size) {
    _syncVisualStyle();
    _syncLayoutSize(size);
    final imageRect = _layoutImageRect!;
    final render = layoutCache.render;
    if (render != null) {
      if (!render.step()) return false;
      final result = render.result;
      layoutCache.prepared[render.block.key] = result;
      layoutCache.preparedRegionIds.addAll(
        render.block.regions.map((region) => region.region.ocrRegionId),
      );
      layoutCache.render = null;
      layoutCache.repaint.value++;
      return isPreparedFor(size);
    }
    final pending = layoutCache.search;
    if (pending != null) {
      if (!pending.step()) return false;
      final plan = pending.plan!;
      _layoutPlans[pending.block.key] = plan;
      layoutCache.render = _TranslationRenderPreparation(
        this,
        pending.block,
        plan,
        layoutCache.geometries[pending.block.key]!,
        imageRect,
      );
      layoutCache.search = null;
      return false;
    }
    for (final block in _layoutBlocks()) {
      if (layoutCache.prepared.containsKey(block.key) ||
          layoutCache.skipped.contains(block.key)) {
        continue;
      }
      final plan = _layoutPlans[block.key];
      if (plan != null) {
        layoutCache.render = _TranslationRenderPreparation(
          this,
          block,
          plan,
          layoutCache.geometries[block.key]!,
          imageRect,
        );
        return false;
      }
      final geometry = _blockGeometry(block, imageRect);
      if (geometry == null) {
        layoutCache.skipped.add(block.key);
      } else {
        layoutCache.geometries[block.key] = geometry;
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

  @override
  void paint(Canvas canvas, Size size) {
    _hitRegions.clear();
    _syncVisualStyle();
    _syncLayoutSize(size);
    if (layoutCache.prepared.isEmpty) return;
    for (final block in _layoutBlocks()) {
      if (block.key == hiddenBlockKey) continue;
      final prepared = layoutCache.prepared[block.key];
      if (prepared == null) continue;
      final geometry = prepared.geometry;
      final bounds = geometry.bounds;
      final bubblePath = geometry.bubblePath;
      _hitRegions.add(_TranslationHitRegion(
        block.key,
        bubblePath ?? (Path()..addRect(bounds)),
      ));
      if (!hasCleanOverlay) {
        for (final shape in prepared.backgrounds) {
          canvas.drawPath(shape.path, shape.paint);
        }
      }
      canvas.save();
      if (bubblePath != null) canvas.clipPath(bubblePath);
      for (final command in prepared.text) {
        command.stroke.paint(canvas, command.offset);
        command.fill.paint(canvas, command.offset);
      }
      canvas.restore();
    }
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
  final Rect inkBounds;

  const _TranslationLayoutRegion(
    this.region,
    this.bounds,
    this.inkBounds,
  );
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
  final List<_VerticalTextLayout?> laneLayouts;
  final double fontSize;

  const _TranslationLayoutPlan(this.lanes, this.laneLayouts, this.fontSize);
}

class _TranslationPreparedBlock {
  final _TranslationBlockGeometry geometry;
  final List<_TranslationBackgroundShape> backgrounds;
  final List<_TranslationTextCommand> text;

  const _TranslationPreparedBlock(this.geometry, this.backgrounds, this.text);
}

class _TranslationBackgroundShape {
  final Path path;
  final Paint paint;

  const _TranslationBackgroundShape(this.path, this.paint);
}

class _TranslationTextCommand {
  final TextPainter fill;
  final TextPainter stroke;
  final Offset offset;

  const _TranslationTextCommand(this.fill, this.stroke, this.offset);
}
