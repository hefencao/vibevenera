part of '../webp_image_provider.dart';

extension WebPStreamLoad on WebPStreamSession {
  Future<_ProgressiveLoadResult?> loadAnimated({
    StreamController<ImageChunkEvent>? chunkEvents,
  }) async {
    final decoder = webp.createStreamingAnimDecoder(
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    if (decoder == null) return null;

    final completer = Completer<_ProgressiveLoadResult?>();
    DecoderHolder? holder;
    Uint8List? finalBytes;
    var chunkCount = 0;
    var lastDebugBytes = 0;
    var lastFrameCount = -1;
    debugPrint('[WebP-Stream][visible] START ${_short(_fullKey)}');

    late StreamSubscription<ImageDownloadProgress> sub;
    sub = ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      debugLabel: 'webp-stream:$imageKey',
    ).listen(
      (event) {
        if (event.reset) {
          holder?.updateStreamTransfer(0, null, reset: true);
        } else {
          holder?.updateStreamTransfer(event.currentBytes, event.totalBytes);
        }
        PipelineController.instance.publishExternalDownloadProgress(
          imageKey,
          event.currentBytes,
          event.totalBytes,
          done: event.imageBytes != null,
        );
        if (chunkEvents != null &&
            !chunkEvents.isClosed &&
            event.chunkBytes == null) {
          chunkEvents.add(
            ImageChunkEvent(
              cumulativeBytesLoaded: event.currentBytes,
              expectedTotalBytes: event.totalBytes ?? 0,
            ),
          );
        }
        if (event.reset && !decoder.isDisposed) {
          debugPrint('[WebP-Stream][visible] RESET ${_short(_fullKey)}');
          decoder.resetStreamInput();
          holder?.clearBufferedFrames();
          holder?.resetStreamPlaybackState();
        }
        final chunk = event.chunkBytes;
        if (chunk != null && !decoder.isDisposed) {
          chunkCount++;
          if (chunkCount <= 3 ||
              event.currentBytes - lastDebugBytes >= 1024 * 1024) {
            lastDebugBytes = event.currentBytes;
            debugPrint(
              '[WebP-Stream][visible] chunk#$chunkCount '
              '+${chunk.length} loaded=${event.currentBytes}/${event.totalBytes ?? -1}',
            );
          }
          final ready = decoder.appendStreamChunk(chunk);
          if (ready && decoder.frameCount != lastFrameCount) {
            lastFrameCount = decoder.frameCount;
            debugPrint(
              '[WebP-Stream][visible] info animated=${decoder.streamIsAnimated} '
              'frames=${decoder.frameCount} ${decoder.targetWidth}x${decoder.targetHeight} '
              '${_short(_fullKey)}',
            );
          }
          if (ready && !decoder.streamIsAnimated) {
            debugPrint(
              '[WebP-Stream][visible] ready but static '
              '${decoder.targetWidth}x${decoder.targetHeight} ${_short(_fullKey)}',
            );
          }
          if (ready &&
              decoder.streamIsAnimated &&
              holder == null &&
              decoder.frameCount > 0 &&
              decoder.targetWidth > 0) {
            debugPrint(
              '[WebP-Stream][visible] READY animated '
              '${decoder.frameCount}f ${decoder.targetWidth}x${decoder.targetHeight} '
              '${_short(_fullKey)}',
            );
            holder = DecoderManager.instance.getOrCreateHolder(
              _fullKey,
              decoder,
              decoder.targetWidth,
              decoder.targetHeight,
              scale,
            );
            holder!.updateStreamTransfer(event.currentBytes, event.totalBytes);
            holder!.markStreamActive();
            PipelineController.instance.publishExternalHolder(
              imageKey,
              _fullKey,
              holder,
            );
            if (holder!.state == PageState.current) holder!.requestRefill();
            debugPrint('[WebP-Stream][visible] HOLDER ${_short(_fullKey)}');
            if (!completer.isCompleted) {
              completer.complete(
                _ProgressiveLoadResult.animated(holder!, sub),
              );
            }
          } else {
            if (holder?.state == PageState.current) holder?.requestRefill();
          }
        }
        final bytes = event.imageBytes;
        if (bytes != null) {
          finalBytes = bytes;
          holder?.updateStreamTransfer(bytes.length, bytes.length);
          debugPrint(
            '[WebP-Stream][visible] FINAL ${bytes.length}B '
            'holder=${holder != null} ${_short(_fullKey)}',
          );
          if (cache != null && webp.isWebP(bytes)) cache!.putL2(imageKey, bytes);
          PipelineController.instance.publishExternalBytes(imageKey, bytes);
          if (!decoder.isDisposed) {
            decoder.appendStreamChunk(Uint8List(0), isFinal: true);
          }
          if (holder?.state == PageState.current) holder?.requestRefill();
          if (!completer.isCompleted) {
            completer.complete(holder != null
                ? _ProgressiveLoadResult.animated(holder!, sub)
                : _ProgressiveLoadResult.bytes(bytes));
          }
        }
      },
      onError: (e) {
        debugPrint('[WebP-Stream][visible] ERROR ${_short(_fullKey)} $e');
        final h = holder;
        if (h != null && h.decoder.isStreaming && !h.decoder.streamIsComplete) {
          h.markStreamDownloadClosed(e);
        } else {
          h?.markStreamFailed(e);
        }
        if (!completer.isCompleted) completer.complete(null);
        if (holder == null && !decoder.isDisposed) decoder.dispose();
      },
      onDone: () {
        debugPrint(
          '[WebP-Stream][visible] DONE holder=${holder != null} '
          'final=${finalBytes?.length ?? 0} ${_short(_fullKey)}',
        );
        if (holder != null && finalBytes == null) {
          holder!.markStreamDownloadClosed(StateError('stream ended without final bytes'));
        }
        if (!completer.isCompleted) {
          final bytes = finalBytes;
          completer.complete(bytes == null
              ? null
              : holder != null
                  ? _ProgressiveLoadResult.animated(holder!, sub)
                  : _ProgressiveLoadResult.bytes(bytes));
        }
        if (holder == null && !decoder.isDisposed) decoder.dispose();
      },
      cancelOnError: false,
    );
    completer.future.whenComplete(() {
      if (holder == null && finalBytes != null) {
        sub.cancel();
        if (!decoder.isDisposed) decoder.dispose();
      }
    });
    return completer.future;
  }
}
