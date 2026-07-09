part of '../webp_image_provider.dart';

class _WebPStreamSession {
  final WebPImageProvider provider;
  _WebPStreamSession(this.provider);

  String get imageKey => provider.imageKey;
  String? get sourceKey => provider.sourceKey;
  String get cid => provider.cid;
  String get eid => provider.eid;
  int get targetWidth => provider.targetWidth;
  int get targetHeight => provider.targetHeight;
  double get scale => provider.scale;
  DecodedImageCache? get cache => provider.cache;
  String get _fullKey => provider._fullKey;

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
          decoder.resetStreamInput();
          holder?.clearBufferedFrames();
          holder?.resetStreamPlaybackState();
          holder?.notifyStreamInputChanged();
        }
        final chunk = event.chunkBytes;
        if (chunk != null && !decoder.isDisposed) {
          final ready = decoder.appendStreamChunk(chunk);
          if (ready &&
              decoder.streamIsAnimated &&
              holder == null &&
              decoder.frameCount > 0 &&
              decoder.targetWidth > 0) {
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
            if (!completer.isCompleted) {
              completer.complete(
                _ProgressiveLoadResult.animated(holder!, sub),
              );
            }
          } else {
            holder?.notifyStreamInputChanged();
          }
        }
        final bytes = event.imageBytes;
        if (bytes != null) {
          finalBytes = bytes;
          holder?.updateStreamTransfer(bytes.length, bytes.length);
          if (cache != null && webp.isWebP(bytes)) cache!.putL2(imageKey, bytes);
          PipelineController.instance.publishExternalBytes(imageKey, bytes);
          if (!decoder.isDisposed) {
            decoder.appendStreamChunk(Uint8List(0), isFinal: true);
          }
          holder?.notifyStreamInputChanged();
          if (!completer.isCompleted) {
            completer.complete(holder != null
                ? _ProgressiveLoadResult.animated(holder!, sub)
                : _ProgressiveLoadResult.bytes(bytes));
          }
        }
      },
      onError: (e) {
        Log.warning('WebP.Stream.Visible', 'ERROR ${_short(_fullKey)} $e');
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
    if (attachedByPipeline) {
      holder.markStreamActive();
      holder.requestRefill();
      return null;
    }
    if (resumeExistingInput) {
      holder.restartAvailableStreamPlayback(minFrames: 1);
    } else {
      decoder.resetStreamInput();
      holder.clearBufferedFrames();
      holder.resetStreamPlaybackState();
    }
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
          holder.notifyStreamInputChanged();
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
          decoder.appendStreamChunk(data);
          holder.notifyStreamInputChanged();
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
          holder.notifyStreamInputChanged();
          onDone?.call();
        }
      },
      onError: (e) {
        Log.warning(
          'WebP.Stream.Visible',
          'RESUME-ERROR ${_short(_fullKey)} $e',
        );
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
