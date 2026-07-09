part of '../webp_image_provider.dart';

class _WebPImageStreamCompleter extends ImageStreamCompleter
    with WidgetsBindingObserver {
  final WebPImageProvider _provider;
  bool _disposed = false;
  StreamSubscription<ImageChunkEvent>? _chunkSub;
  WebPPlaybackController? _playback;

  _WebPImageStreamCompleter(
    Future<_ImageResult> future,
    this._provider, {
    Stream<ImageChunkEvent>? chunkEvents,
  }) {
    WidgetsBinding.instance.addObserver(this);
    if (chunkEvents != null) {
      _chunkSub = chunkEvents.listen((event) {
        if (!_disposed) reportImageChunkEvent(event);
      });
    }
    future.then(_onResult, onError: _onError);
  }

  @override
  void onDisposed() {
    WidgetsBinding.instance.removeObserver(this);
    _chunkSub?.cancel();
    _playback?.dispose();
    _disposed = true;
    super.onDisposed();
  }

  @override
  void didChangeAppLifecycleState(ui.AppLifecycleState state) {
    if (_disposed) return;
    if (state == ui.AppLifecycleState.resumed) _playback?.onAppResumed();
  }

  void _onResult(_ImageResult result) {
    if (_disposed) {
      result.progressiveSub?.cancel();
      return;
    }
    switch (result.type) {
      case _ResultType.static:
        setImage(result.imageInfo!);
        break;
      case _ResultType.animated:
        _startPlayback(result.holder!, result.progressiveSub);
        break;
      case _ResultType.fallback:
        _fallbackDecode(result.rawBytes!);
        break;
      case _ResultType.error:
        reportError(exception: result.error ?? 'Unknown error');
        break;
    }
  }

  void _onError(Object error, StackTrace? stack) {
    if (!_disposed) reportError(exception: error, stack: stack);
  }

  void _startPlayback(
    DecoderHolder holder,
    StreamSubscription<ImageDownloadProgress>? progressiveSub,
  ) {
    _playback?.dispose();
    _playback = WebPPlaybackController(
      provider: _provider,
      hasListeners: () => hasListeners,
      emitImage: (info) {
        if (!_disposed) setImage(info);
      },
    )..start(holder, progressiveSub: progressiveSub);
  }

  void _fallbackDecode(Uint8List bytes) {
    ui.instantiateImageCodec(bytes).then((codec) {
      codec.getNextFrame().then((frame) {
        if (!_disposed) {
          setImage(ImageInfo(image: frame.image, scale: _provider.scale));
        }
      });
    });
  }
}

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
