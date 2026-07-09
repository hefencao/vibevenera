part of '../webp_image_provider.dart';

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

(int, int) _resolveWebPDecodeTarget(
  webp.WebPImageInfo info,
  int boundWidth,
  int boundHeight,
) {
  if (boundWidth <= 0 && boundHeight <= 0) return (info.width, info.height);
  final bw = boundWidth > 0 ? boundWidth : info.width;
  final bh = boundHeight > 0 ? boundHeight : info.height;
  final scale = math.min(1.0, math.min(bw / info.width, bh / info.height));
  final tw = _alignWebPDecodeDimension((info.width * scale).round());
  final th = _alignWebPDecodeDimension((tw * info.height / info.width).round());
  return (math.min(tw, info.width), math.min(th, info.height));
}

bool _isLikelyWebP(String imageKey) => imageKey.toLowerCase().contains('.webp');

Future<DecoderHolder?> _ensureWebPHolder({
  required String imageKey,
  required String fullKey,
  DecodedImageCache? cache,
  String? sourceKey,
  required String cid,
  required String eid,
  int targetWidth = 0,
  int targetHeight = 0,
  double scale = 1.0,
  Uint8List? providedBytes,
  bool onlyIfCached = false,
}) async {
  final existing = DecoderManager.instance.getHolder(fullKey);
  if (existing != null && !existing.disposed) return existing;

  Uint8List? bytes = providedBytes;
  if (bytes == null && cache?.hasL2(imageKey) == true) {
    bytes = cache!.getL2(imageKey);
  }
  if (bytes == null) {
    if (onlyIfCached) return null;
    try {
      final fetched = await fetchImageBytes(
        imageKey,
        sourceKey,
        cid,
        eid,
        debugLabel: 'webp-holder',
      );
      bytes = fetched;
      if (cache != null && webp.isWebP(fetched)) cache.putL2(imageKey, fetched);
    } catch (_) {
      return null;
    }
  }
  if (!webp.isWebP(bytes)) return null;

  final info = webp.getInfo(bytes);
  if (info == null || !info.isAnimated) return null;
  final (tw, th) = _resolveWebPDecodeTarget(info, targetWidth, targetHeight);

  try {
    final decoder = webp.createAnimDecoder(
      bytes,
      targetWidth: tw,
      targetHeight: th,
    );
    if (decoder == null) return null;
    final holder = DecoderManager.instance.getOrCreateHolder(
      fullKey,
      decoder,
      tw,
      th,
      scale,
    );
    return holder;
  } catch (_) {
    return null;
  }
}

void _onWebPPageChanged({
  required int currentPageIndex,
  required List<String> images,
  required BuildContext context,
  required String cid,
  required String eid,
  required String? sourceKey,
  DecodedImageCache? cache,
}) {
  DecoderManager.instance.cache = cache;
  DecoderManager.instance.decodeService.updateGeneration(
    DecoderManager.instance.generation + 1,
  );

  String fk(int i) => (i >= 0 && i < images.length) ? images[i] : '';
  final current = fk(currentPageIndex);
  PipelineController.instance.onWindowChanged =
      (currentKey, decodeNextKeys, decodePrevKeys, downloadOnlyKeys) {
        DecoderManager.instance.setPageRange(
          currentKey: currentKey,
          nextKeys: decodeNextKeys,
          lastKeys: decodePrevKeys,
          precacheKeys: downloadOnlyKeys,
        );

        if (cache != null) {
          cache.setActivePages(
            [
              currentKey,
              ...decodeNextKeys,
              ...decodePrevKeys,
            ].where((k) => k.isNotEmpty),
          );
        }
      };

  DecoderManager.instance.setPageRange(
    currentKey: current,
    nextKeys: const <String>{},
    lastKeys: const <String>{},
    precacheKeys: const <String>{},
  );
}
