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
    holder.traceStreamState('VISIBLE-START');
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
