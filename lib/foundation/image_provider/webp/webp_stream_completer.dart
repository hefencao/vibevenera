part of '../webp_image_provider.dart';

class _WebPImageStreamCompleter extends ImageStreamCompleter
    with WidgetsBindingObserver {
  final WebPImageProvider _provider;
  bool _disposed = false;
  StreamSubscription<ImageChunkEvent>? _chunkSub;
  StreamSubscription<ImageDownloadProgress>? _progressiveSub;
  DecoderHolder? _activeHolder;

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
    _progressiveSub?.cancel();
    _disposed = true;
    super.onDisposed();
  }

  @override
  void didChangeAppLifecycleState(ui.AppLifecycleState state) {
    if (_disposed) return;
    if (state == ui.AppLifecycleState.resumed) {
      _activeHolder?.resumeFromLifecyclePause();
    }
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
        _progressiveSub = result.progressiveSub;
        _startAnimationLoop(result.holder!);
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

  void _fallbackDecode(Uint8List bytes) {
    ui.instantiateImageCodec(bytes).then((codec) {
      codec.getNextFrame().then((frame) {
        if (!_disposed) {
          setImage(ImageInfo(image: frame.image, scale: _provider.scale));
        }
      });
    });
  }

  Future<DecoderHolder?> _reloadAndRestart(
    DecoderHolder oldHolder, {
    bool forceNetwork = false,
    bool forceFullDecode = false,
  }) async {
    if (_disposed) return null;
    try {
      await _progressiveSub?.cancel();
      _progressiveSub = null;
      if (forceNetwork) {
        _provider.cache?.evictL2(_provider.imageKey);
        await CacheManager().delete(
          '${_provider.imageKey}@${_provider.sourceKey}@${_provider.cid}@${_provider.eid}',
        );
      }
      oldHolder.dispose();
      final result = await _provider._loadImageAsync(
        forceNetwork: forceNetwork,
        disableStreaming: forceFullDecode,
      );
      if (_disposed) return null;
      if (result.type == _ResultType.animated) {
        _progressiveSub = result.progressiveSub;
        return result.holder;
      }
      if (result.type == _ResultType.static) setImage(result.imageInfo!);
    } catch (_) {
      // Reload failed silently; animation will stop.
    }
    return null;
  }

  void _startAnimationLoop(DecoderHolder initialHolder) async {
    DecoderHolder holder = initialHolder;
    _activeHolder = holder;
    var hasShownFirstFrame = false;
    var nullFrameWaits = 0;
    var resumeStartedAt = 0;
    while (!_disposed) {
      if (!hasListeners) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }
      try {
        final state = WidgetsBinding.instance.lifecycleState;
        if (state == ui.AppLifecycleState.paused ||
            state == ui.AppLifecycleState.hidden) {
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }
      } catch (_) {}

      final active = DecoderManager.instance.isActiveImageKey(
        _provider.imageKey,
      );
      if (!active) {
        if (_progressiveSub != null &&
            holder.decoder.isStreaming &&
            !holder.decoder.streamIsComplete) {
          debugPrint('[WebP-Stream][visible] PAUSE ${holder.shortKey}');
          await _progressiveSub?.cancel();
          _progressiveSub = null;
        }
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }

      if (holder.disposed) {
        _drainBuffer(holder);
        final nh = await _reloadAndRestart(holder);
        if (nh != null) {
          holder = nh;
          _activeHolder = holder;
          hasShownFirstFrame = false;
          nullFrameWaits = 0;
          continue;
        } else {
          break;
        }
      }

      final pipelineAttached =
          PipelineController.instance.hasStreamDecodeAttached(holder.key);
      if (holder.streamNeedsResume && _progressiveSub == null && !pipelineAttached) {
        debugPrint(
          '[WebP-Stream][visible] RESUME-CLOSED ${holder.shortKey} '
          'frames=${holder.decoder.frameCount} decoded=${holder.decodedFrameCount} '
          'buf=${holder.bufferLength} loaded=${holder.streamLoadedBytes}/${holder.streamExpectedBytes ?? -1} '
          '${holder.streamError}',
        );
        _progressiveSub = _provider._resumeStreamingIntoHolder(
          holder,
          onDone: () => _progressiveSub = null,
        );
        resumeStartedAt = _nowMs();
      } else if (holder.streamFailed) {
        debugPrint(
          '[WebP-Stream][visible] RELOAD failed-stream ${holder.shortKey} '
          '${holder.streamError}',
        );
        final canUseFinalBytes =
            holder.decoder.isStreaming && holder.decoder.streamIsComplete;
        final nh = await _reloadAndRestart(
          holder,
          forceNetwork: !canUseFinalBytes,
          forceFullDecode: canUseFinalBytes,
        );
        if (nh != null) {
          holder = nh;
          _activeHolder = holder;
          hasShownFirstFrame = false;
          nullFrameWaits = 0;
          continue;
        }
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      if (_progressiveSub == null &&
          holder.decoder.isStreaming &&
          !holder.decoder.streamIsComplete) {
        if (pipelineAttached) {
          holder.markStreamActive();
          holder.requestRefill();
        } else {
          _progressiveSub = _provider._resumeStreamingIntoHolder(
            holder,
            onDone: () => _progressiveSub = null,
          );
          resumeStartedAt = _nowMs();
        }
        holder.requestRefill();
      }

      final startupWatermark = hasShownFirstFrame
          ? 0
          : DecoderHolder._firstFrameWatermark;
      if (holder.bufferLength < startupWatermark &&
          holder.state == PageState.current) {
        holder.requestRefill();
        holder.refillSignal ??= Completer<void>();
        await Future.any([
          holder.refillSignal!.future,
          Future.delayed(const Duration(milliseconds: 200)),
        ]);
        continue;
      }

      final frame = holder.consumeFrame();
      if (frame == null) {
        nullFrameWaits++;
        final currentHolder = holder.state == PageState.current;
        if (currentHolder &&
            holder.decoder.isStreaming &&
            !holder.decoder.streamIsComplete &&
            holder._streamAtAvailableEnd &&
            nullFrameWaits >= (hasShownFirstFrame ? 1 : 3) &&
            holder.restartAvailableStreamPlayback()) {
          debugPrint('[WebP-Stream][visible] REPLAY-PARTIAL ${holder.shortKey}');
          hasShownFirstFrame = false;
          nullFrameWaits = 0;
          continue;
        }
        if (currentHolder &&
            holder.decoder.isStreaming &&
            !holder.decoder.streamIsComplete &&
            _progressiveSub != null &&
            nullFrameWaits >= 30 &&
            _nowMs() - resumeStartedAt > 1500) {
          debugPrint(
            '[WebP-Stream][visible] WAIT-DOWNLOAD ${holder.shortKey} '
            'frames=${holder.decoder.frameCount} decoded=${holder.decodedFrameCount} '
            'buf=${holder.bufferLength} raw=${holder.queuedFrameCount - holder.bufferLength} '
            'inFlight=${holder._decodeInFlight} uploading=${holder._isUploading} '
            'loaded=${holder.streamLoadedBytes}/${holder.streamExpectedBytes ?? -1}',
          );
          nullFrameWaits = 0;
        }
        if (currentHolder &&
            holder.decoder.isStreaming &&
            holder.decoder.streamIsComplete &&
            nullFrameWaits >= 6 &&
            holder._streamMayDecodeMore) {
          holder.markStreamFailed(StateError('stream ended before all frames'));
          continue;
        }
        if (holder.disposed) continue;
        holder.refillSignal ??= Completer<void>();
        await Future.any([
          holder.refillSignal!.future,
          Future.delayed(Duration(milliseconds: currentHolder ? 200 : 800)),
        ]);
        continue;
      }

      setImage(ImageInfo(image: frame.image, scale: holder.scale));
      hasShownFirstFrame = true;
      nullFrameWaits = 0;
      final rawDelay = frame.durationMs <= 0 ? 100 : frame.durationMs;
      final delay = rawDelay.clamp(16, 200);
      final bufferPressureDelay = _bufferPressureDelay(holder);
      await Future.delayed(
        Duration(
          milliseconds: (delay * bufferPressureDelay / webpPlaybackSpeed)
              .round(),
        ),
      );
    }
    if (_activeHolder == holder) {
      _activeHolder = null;
    }
  }

  double _bufferPressureDelay(DecoderHolder holder) {
    if (holder.state != PageState.current) return 1.0;
    final remaining = holder.bufferLength;
    if (remaining <= 1) return 1.3;
    if (remaining <= 3) return 1.2;
    if (remaining <= 5) return 1.1;
    return 1.0;
  }

  /// Dispose all frames remaining in a holder's buffer.
  void _drainBuffer(DecoderHolder h) {
    h.clearBufferedFrames();
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
