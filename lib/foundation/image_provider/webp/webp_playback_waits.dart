part of '../webp_image_provider.dart';

extension WebPPlaybackWaits on WebPPlaybackController {
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
      debugPrint('[WebP-Stream][visible] PAUSE ${holder.shortKey}');
      await _progressiveSub?.cancel();
      _progressiveSub = null;
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
    holder.requestRefill();
    holder.refillSignal ??= Completer<void>();
    await Future.any([
      holder.refillSignal!.future,
      Future.delayed(WebPPlaybackTiming.firstFramePoll),
    ]);
    return true;
  }

  Future<void> _waitAfterNullFrame(
    DecoderHolder holder,
    WebPPlaybackState playback,
  ) async {
    playback.markNullFrame();
    final currentHolder = holder.state == PageState.current;
    if (currentHolder &&
        holder.decoder.isStreaming &&
        !holder.decoder.streamIsComplete &&
        holder._streamAtAvailableEnd &&
        playback.nullFrameWaits >= (playback.hasShownFirstFrame ? 1 : 3) &&
        holder.restartAvailableStreamPlayback()) {
      debugPrint('[WebP-Stream][visible] REPLAY-PARTIAL ${holder.shortKey}');
      playback.resetStartup();
      return;
    }
    if (currentHolder &&
        holder.decoder.isStreaming &&
        !holder.decoder.streamIsComplete &&
        _progressiveSub != null &&
        playback.nullFrameWaits >= 30 &&
        playback.resumeWaitElapsed) {
      debugPrint(
        '[WebP-Stream][visible] WAIT-DOWNLOAD ${holder.shortKey} '
        'frames=${holder.decoder.frameCount} decoded=${holder.decodedFrameCount} '
        'buf=${holder.bufferLength} raw=${holder.queuedFrameCount - holder.bufferLength} '
        'inFlight=${holder._decodeInFlight} uploading=${holder._isUploading} '
        'loaded=${holder.streamLoadedBytes}/${holder.streamExpectedBytes ?? -1}',
      );
      playback.nullFrameWaits = 0;
    }
    if (currentHolder &&
        holder.decoder.isStreaming &&
        holder.decoder.streamIsComplete &&
        playback.nullFrameWaits >= 6 &&
        holder._streamMayDecodeMore) {
      holder.markStreamFailed(StateError('stream ended before all frames'));
      return;
    }
    if (holder.disposed) return;
    holder.refillSignal ??= Completer<void>();
    await Future.any([
      holder.refillSignal!.future,
      Future.delayed(WebPPlaybackTiming.emptyFrameWait(currentHolder)),
    ]);
  }
}
