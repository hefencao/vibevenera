part of '../webp_image_provider.dart';

// ═══════════════════════════════════════════════════════════════
// 7. Result types
// ═══════════════════════════════════════════════════════════════

enum _ResultType { static, animated, fallback, error }

class _ImageResult {
  final _ResultType type;
  final ImageInfo? imageInfo;
  final DecoderHolder? holder;
  final Uint8List? rawBytes;
  final Object? error;
  final StreamSubscription<ImageDownloadProgress>? progressiveSub;

  _ImageResult._({
    required this.type,
    this.imageInfo,
    this.holder,
    this.rawBytes,
    this.error,
    this.progressiveSub,
  });

  factory _ImageResult.static(ImageInfo info) =>
      _ImageResult._(type: _ResultType.static, imageInfo: info);
  factory _ImageResult.animated(
    DecoderHolder holder, {
    StreamSubscription<ImageDownloadProgress>? progressiveSub,
  }) =>
      _ImageResult._(
        type: _ResultType.animated,
        holder: holder,
        progressiveSub: progressiveSub,
      );
  factory _ImageResult.fallback(Uint8List bytes) =>
      _ImageResult._(type: _ResultType.fallback, rawBytes: bytes);
  factory _ImageResult.error(Object e) =>
      _ImageResult._(type: _ResultType.error, error: e);
}

class _ProgressiveLoadResult {
  final DecoderHolder? holder;
  final Uint8List? bytes;
  final StreamSubscription<ImageDownloadProgress>? subscription;

  const _ProgressiveLoadResult._({this.holder, this.bytes, this.subscription});
  factory _ProgressiveLoadResult.animated(
    DecoderHolder holder,
    StreamSubscription<ImageDownloadProgress> subscription,
  ) =>
      _ProgressiveLoadResult._(holder: holder, subscription: subscription);
  factory _ProgressiveLoadResult.bytes(Uint8List bytes) =>
      _ProgressiveLoadResult._(bytes: bytes);
}
