part of '../webp_image_provider.dart';

extension WebPStreamResume on WebPStreamSession {
  StreamSubscription<ImageDownloadProgress>? resumeIntoHolder(
    DecoderHolder holder, {
    void Function()? onDone,
  }) {
    final decoder = holder.decoder;
    if (!decoder.isStreaming || decoder.isDisposed || decoder.streamIsComplete) {
      return null;
    }
    final resumeFromBytes = holder.streamLoadedBytes;
    final attachedByPipeline =
        PipelineController.instance.hasStreamDecodeAttached(_fullKey);
    final resumeExistingInput = resumeFromBytes > 0;
    var appendedUntil = resumeExistingInput ? resumeFromBytes : 0;
    debugPrint(
      '[WebP-Stream][visible] RESUME ${_short(_fullKey)} '
      'offset=$resumeFromBytes keep=$resumeExistingInput '
      'attached=$attachedByPipeline',
    );
    if (attachedByPipeline) {
      holder.markStreamActive();
      holder.requestRefill();
      return null;
    }
    if (resumeExistingInput) {
      final restarted = holder.restartAvailableStreamPlayback(minFrames: 1);
      debugPrint(
        '[WebP-Stream][visible] RESUME-RESTART ${_short(_fullKey)} '
        'ok=$restarted frames=${decoder.frameCount} decoded=${holder.decodedFrameCount} '
        'buf=${holder.bufferLength} '
        'raw=${holder.queuedFrameCount - holder.bufferLength} '
        'inFlight=${holder._decodeInFlight} uploading=${holder._isUploading}',
      );
    } else {
      decoder.resetStreamInput();
      holder.clearBufferedFrames();
      holder.resetStreamPlaybackState();
    }
    var chunkCount = 0;
    var lastDebugBytes = 0;
    var completed = false;
    var closedByPolicy = false;
    late StreamSubscription<ImageDownloadProgress> sub;
    sub = ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      debugLabel: 'webp-resume:$imageKey',
      resumeFromBytes: resumeExistingInput ? resumeFromBytes : null,
      resumeExpectedBytes: holder.streamExpectedBytes,
      replayPartial: !resumeExistingInput,
    ).listen(
      (event) {
        if (event.reset) {
          holder.updateStreamTransfer(0, null, reset: true);
        } else {
          holder.updateStreamTransfer(event.currentBytes, event.totalBytes);
        }
        PipelineController.instance.publishExternalDownloadProgress(
          imageKey,
          event.currentBytes,
          event.totalBytes,
          done: event.imageBytes != null,
        );
        holder.markStreamActive();
        if (!DecoderManager.instance.isActiveImageKey(imageKey)) {
          closedByPolicy = true;
          sub.cancel();
          onDone?.call();
          return;
        }
        if (event.reset && !decoder.isDisposed) {
          decoder.resetStreamInput();
          holder.clearBufferedFrames();
          holder.resetStreamPlaybackState();
        }
        final chunk = event.chunkBytes;
        if (chunk != null && !decoder.isDisposed) {
          final chunkEnd = event.currentBytes;
          final chunkStart = chunkEnd - chunk.length;
          if (chunkEnd <= appendedUntil) return;
          final data = chunkStart < appendedUntil
              ? Uint8List.sublistView(chunk, appendedUntil - chunkStart)
              : chunk;
          appendedUntil = chunkEnd;
          chunkCount++;
          if (chunkCount <= 3 ||
              event.currentBytes - lastDebugBytes >= 1024 * 1024) {
            lastDebugBytes = event.currentBytes;
            debugPrint(
              '[WebP-Stream][visible] resume-chunk#$chunkCount '
              '+${data.length} loaded=${event.currentBytes}/${event.totalBytes ?? -1} '
              '${_short(_fullKey)}',
            );
          }
          final ready = decoder.appendStreamChunk(data);
          if (ready) holder.requestRefill();
        }
        final bytes = event.imageBytes;
        if (bytes != null) {
          completed = true;
          holder.updateStreamTransfer(bytes.length, bytes.length);
          if (cache != null && webp.isWebP(bytes)) cache!.putL2(imageKey, bytes);
          PipelineController.instance.publishExternalBytes(imageKey, bytes);
          if (!decoder.isDisposed) {
            decoder.appendStreamChunk(
              appendedUntil == 0 ? bytes : Uint8List(0),
              isFinal: true,
            );
          }
          holder.requestRefill();
          onDone?.call();
        }
      },
      onError: (e) {
        debugPrint('[WebP-Stream][visible] RESUME-ERROR ${_short(_fullKey)} $e');
        holder.markStreamDownloadClosed(e);
        onDone?.call();
      },
      onDone: () {
        if (!completed && !closedByPolicy) {
          holder.markStreamDownloadClosed(StateError('resume ended without final bytes'));
        }
        onDone?.call();
      },
      cancelOnError: false,
    );
    return sub;
  }
}
