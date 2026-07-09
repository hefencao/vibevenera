part of '../webp_image_provider.dart';

class _PlaybackStreamSyncResult {
  final DecoderHolder holder;
  final bool restartLoop;
  const _PlaybackStreamSyncResult(this.holder, {this.restartLoop = false});
}

extension WebPPlaybackStreaming on WebPPlaybackController {
  Future<DecoderHolder?> _replaceDisposedHolder(
    DecoderHolder holder,
    WebPPlaybackState playback,
  ) async {
    holder.clearBufferedFrames();
    final nh = await _reloadAndRestart(holder);
    if (nh == null) return null;
    _activeHolder = nh;
    playback.resetStartup();
    return nh;
  }

  Future<_PlaybackStreamSyncResult> _syncStreamState(
    DecoderHolder holder,
    WebPPlaybackState playback,
  ) async {
    final pipelineAttached =
        PipelineController.instance.hasStreamDecodeAttached(holder.key);
    if (holder.streamNeedsResume && _progressiveSub == null && !pipelineAttached) {
      _resumeClosedStream(holder, playback);
    } else if (holder.streamFailed) {
      final nh = await _reloadFailedStream(holder, playback);
      return _PlaybackStreamSyncResult(nh ?? holder, restartLoop: true);
    }
    _ensureStreamingActive(holder, playback, pipelineAttached);
    return _PlaybackStreamSyncResult(holder);
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

  void _resumeClosedStream(
    DecoderHolder holder,
    WebPPlaybackState playback,
  ) {
    debugPrint(
      '[WebP-Stream][visible] RESUME-CLOSED ${holder.shortKey} '
      'frames=${holder.decoder.frameCount} decoded=${holder.decodedFrameCount} '
      'buf=${holder.bufferLength} loaded=${holder.streamLoadedBytes}/${holder.streamExpectedBytes ?? -1} '
      '${holder.streamError}',
    );
    _progressiveSub = provider._resumeStreamingIntoHolder(
      holder,
      onDone: () => _progressiveSub = null,
    );
    playback.markResumeStarted();
  }

  Future<DecoderHolder?> _reloadFailedStream(
    DecoderHolder holder,
    WebPPlaybackState playback,
  ) async {
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
      _activeHolder = nh;
      playback.resetStartup();
      return nh;
    }
    await Future.delayed(const Duration(milliseconds: 500));
    return null;
  }

  void _ensureStreamingActive(
    DecoderHolder holder,
    WebPPlaybackState playback,
    bool pipelineAttached,
  ) {
    if (_progressiveSub != null ||
        !holder.decoder.isStreaming ||
        holder.decoder.streamIsComplete) {
      return;
    }
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
}
