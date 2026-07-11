part of '../webp_image.dart';

(int, int) _calculateWebPTargetSize(BuildContext context) {
  final mq = MediaQuery.of(context);
  final dpr = mq.devicePixelRatio;
  final width = _alignWebPDecodeDimension((mq.size.width * dpr).round());
  final height = _alignWebPDecodeDimension((mq.size.height * dpr).round());
  return (width, height);
}

int _alignWebPDecodeDimension(int value, {int alignment = 8}) {
  if (value <= alignment) return math.max(1, value);
  final aligned = value - (value % alignment);
  return math.max(alignment, aligned);
}

bool _isLikelyWebP(String imageKey) => imageKey.toLowerCase().contains('.webp');

void _onWebPPageChanged({
  required int currentPageIndex,
  required List<String> images,
  required BuildContext context,
  required String cid,
  required String eid,
  required String? sourceKey,
  DecodedImageCache? cache,
}) {
  final pipeline = PipelineController.instance;
  final (targetWidth, targetHeight) = _calculateWebPTargetSize(context);
  pipeline.setTargetSize(targetWidth, targetHeight);
  pipeline.onWindowChanged =
      (currentKey, decodeNextKeys, decodePrevKeys, downloadOnlyKeys) {
        if (cache == null) return;
        String cacheKey(String imageKey) => targetWidth > 0 || targetHeight > 0
            ? '$imageKey@${targetWidth}x$targetHeight'
            : imageKey;
        cache.setActivePages(
          [
            currentKey,
            ...decodeNextKeys,
            ...decodePrevKeys,
          ].where((key) => key.isNotEmpty).map(cacheKey),
        );
      };
  pipeline.onPageRangeChanged(
    currentIdx: currentPageIndex,
    images: images,
    cid: cid,
    eid: eid,
    sourceKey: sourceKey,
    cache: cache,
  );
}
