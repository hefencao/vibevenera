part of '../webp_image_provider.dart';

class WebPPlaybackState {
  bool hasShownFirstFrame = false;
  int nullFrameWaits = 0;
  int resumeStartedAt = 0;

  void resetStartup() {
    hasShownFirstFrame = false;
    nullFrameWaits = 0;
  }

  void markResumeStarted() => resumeStartedAt = _nowMs();
  void markNullFrame() => nullFrameWaits++;
  void markFrameShown() {
    hasShownFirstFrame = true;
    nullFrameWaits = 0;
  }

  bool get resumeWaitElapsed => _nowMs() - resumeStartedAt > 1500;
}

class WebPPlaybackTiming {
  static const listenerPoll = Duration(milliseconds: 200);
  static const inactivePoll = Duration(milliseconds: 200);
  static const firstFramePoll = Duration(milliseconds: 200);

  static int startupWatermark(WebPPlaybackState state) =>
      state.hasShownFirstFrame ? 0 : DecoderHolder._firstFrameWatermark;

  static Duration emptyFrameWait(bool currentHolder) =>
      Duration(milliseconds: currentHolder ? 200 : 800);

  static Duration frameDelay(BufferedFrame frame, DecoderHolder holder) {
    final rawDelay = frame.durationMs <= 0 ? 100 : frame.durationMs;
    final delay = rawDelay.clamp(16, 200);
    return Duration(
      milliseconds: (delay * bufferPressureDelay(holder) / webpPlaybackSpeed)
          .round(),
    );
  }

  static double bufferPressureDelay(DecoderHolder holder) {
    if (holder.state != PageState.current) return 1.0;
    final remaining = holder.bufferLength;
    if (remaining <= 1) return 1.3;
    if (remaining <= 3) return 1.2;
    if (remaining <= 5) return 1.1;
    return 1.0;
  }
}

class WebPPlaybackController {
  final WebPImageProvider provider;
  final bool Function() hasListeners;
  final void Function(ImageInfo) emitImage;
  bool _disposed = false;
  StreamSubscription<ImageDownloadProgress>? _progressiveSub;
  DecoderHolder? _activeHolder;

  WebPPlaybackController({
    required this.provider,
    required this.hasListeners,
    required this.emitImage,
  });

  void start(
    DecoderHolder holder, {
    StreamSubscription<ImageDownloadProgress>? progressiveSub,
  }) {
    _progressiveSub = progressiveSub;
    unawaited(_run(holder));
  }

  void dispose() {
    _disposed = true;
    _activeHolder?.wakePlaybackWaiters();
    _activeHolder?.releaseStreamOwner('visible');
    _progressiveSub?.cancel();
    _progressiveSub = null;
  }

  void onAppResumed() {
    if (!_disposed) _activeHolder?.resumeFromLifecyclePause();
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
      oldHolder.releaseStreamOwner('visible');
      if (forceNetwork) {
        provider.cache?.evictL2(provider.imageKey);
        await CacheManager().delete(
          '${provider.imageKey}@${provider.sourceKey}@${provider.cid}@${provider.eid}',
        );
      }
      oldHolder.dispose();
      final result = await provider._loadImageAsync(
        forceNetwork: forceNetwork,
        disableStreaming: forceFullDecode,
      );
      if (_disposed) return null;
      if (result.type == _ResultType.animated) {
        _progressiveSub = result.progressiveSub;
        return result.holder;
      }
      if (result.type == _ResultType.static) emitImage(result.imageInfo!);
    } catch (_) {
      // Keep previous behavior: reload failure stops the loop quietly.
    }
    return null;
  }

  Future<void> _run(DecoderHolder initialHolder) async {
    var holder = initialHolder;
    _activeHolder = holder;
    final playback = WebPPlaybackState();
    while (!_disposed) {
      if (await _waitIfNotRenderable()) continue;
      if (await _pauseIfInactive(holder)) continue;

      if (holder.disposed) {
        holder.clearBufferedFrames();
        final nh = await _reloadAndRestart(holder);
        if (nh != null) {
          holder = nh;
          _activeHolder = holder;
          playback.resetStartup();
          continue;
        }
        break;
      }

      final pipelineAttached =
          PipelineController.instance.hasStreamDecodeAttached(holder.key);
      if (holder.streamNeedsResume && _progressiveSub == null && !pipelineAttached) {
        _progressiveSub = provider._resumeStreamingIntoHolder(
          holder,
          onDone: () => _progressiveSub = null,
        );
        playback.markResumeStarted();
      } else if (holder.streamFailed) {
        Log.warning(
          'WebP.Stream.Visible',
          'RELOAD failed-stream ${holder.shortKey} ${holder.streamError}',
        );
        final nh = await _reloadAndRestart(
          holder,
          forceFullDecode: true,
        );
        if (nh != null) {
          holder = nh;
          _activeHolder = holder;
          playback.resetStartup();
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
          _progressiveSub = provider._resumeStreamingIntoHolder(
            holder,
            onDone: () => _progressiveSub = null,
          );
          playback.markResumeStarted();
        }
        holder.requestRefill();
      }

      if (await _waitForStartup(holder, playback)) continue;
      final frame = holder.consumeFrame();
      if (frame == null) {
        await _waitAfterNullFrame(holder, playback);
        continue;
      }

      emitImage(ImageInfo(image: frame.image, scale: holder.scale));
      playback.markFrameShown();
      await Future.delayed(WebPPlaybackTiming.frameDelay(frame, holder));
    }
    if (_activeHolder == holder) _activeHolder = null;
  }

  Future<bool> _waitIfNotRenderable() async {
    if (!hasListeners()) {
      await Future.delayed(WebPPlaybackTiming.listenerPoll);
      return true;
    }
    try {
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == ui.AppLifecycleState.paused ||
          state == ui.AppLifecycleState.hidden) {
        await Future.delayed(WebPPlaybackTiming.inactivePoll);
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<bool> _pauseIfInactive(DecoderHolder holder) async {
    if (DecoderManager.instance.isActiveImageKey(provider.imageKey)) return false;
    if (_progressiveSub != null &&
        holder.decoder.isStreaming &&
        !holder.decoder.streamIsComplete) {
      await _progressiveSub?.cancel();
      _progressiveSub = null;
      holder.releaseStreamOwner('visible');
    }
    await Future.delayed(WebPPlaybackTiming.inactivePoll);
    return true;
  }

  Future<bool> _waitForStartup(
    DecoderHolder holder,
    WebPPlaybackState playback,
  ) async {
    final startupWatermark = WebPPlaybackTiming.startupWatermark(playback);
    if (holder.bufferLength >= startupWatermark ||
        holder.state != PageState.current) {
      return false;
    }
    holder.refillSignal ??= Completer<void>();
    final refill = holder.refillSignal!.future;
    holder.requestRefill();
    await Future.any([
      refill,
      Future.delayed(WebPPlaybackTiming.firstFramePoll),
    ]);
    return true;
  }

  Future<void> _waitAfterNullFrame(
    DecoderHolder holder,
    WebPPlaybackState playback,
  ) async {
    playback.markNullFrame();
    if (playback.nullFrameWaits == 1 ||
        playback.nullFrameWaits == 3 ||
        playback.nullFrameWaits == 6 ||
        playback.nullFrameWaits % 30 == 0) {
      holder.traceStreamState('PLAYBACK-NULL n=${playback.nullFrameWaits}');
    }
    final currentHolder = holder.state == PageState.current;
    if (currentHolder &&
        holder.decoder.isStreaming &&
        !holder.decoder.streamIsComplete &&
        holder._streamAtAvailableEnd &&
        playback.nullFrameWaits >= (playback.hasShownFirstFrame ? 1 : 3) &&
        holder.restartAvailableStreamPlayback()) {
      playback.resetStartup();
      return;
    }
    if (currentHolder &&
        holder.decoder.isStreaming &&
        holder.decoder.streamIsComplete &&
        playback.nullFrameWaits >= 1 &&
        holder._restartCompletedStreamPlayback()) {
      playback.resetStartup();
      return;
    }
    if (currentHolder &&
        holder.decoder.isStreaming &&
        holder.decoder.streamIsComplete &&
        playback.nullFrameWaits >= 6 &&
        holder._streamMayDecodeMore) {
      holder.markStreamFailed(StateError('stream ended before all frames'));
      return;
    }
    if (currentHolder &&
        holder.decoder.isStreaming &&
        !holder.decoder.streamIsComplete &&
        playback.nullFrameWaits >= 6 &&
        holder.decodedFrameCount == 0 &&
        holder.streamLoadedBytes >= 1024 * 1024) {
      holder.traceStreamState('RESYNC partial-stall');
      await _progressiveSub?.cancel();
      _progressiveSub = null;
      holder.releaseStreamOwner('visible');
      holder.markStreamDownloadClosed(StateError('partial stream stalled'));
      return;
    }
    if (holder.disposed) return;
    holder.refillSignal ??= Completer<void>();
    final refill = holder.refillSignal!.future;
    holder.requestRefill();
    if (currentHolder &&
        holder.decoder.isStreaming &&
        !holder.decoder.streamIsComplete) {
      await Future.any([
        refill,
        Future.delayed(WebPPlaybackTiming.emptyFrameWait(true)),
      ]);
      return;
    }
    await Future.any([
      refill,
      Future.delayed(WebPPlaybackTiming.emptyFrameWait(currentHolder)),
    ]);
  }
}
