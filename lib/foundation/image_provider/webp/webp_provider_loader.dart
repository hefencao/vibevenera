part of '../webp_image_provider.dart';

extension _WebPImageProviderLoader on WebPImageProvider {
  // ── Image loading ──────────────────────────────────────────

  Future<_ImageResult> _loadImageAsync({
    StreamController<ImageChunkEvent>? chunkEvents,
    bool forceNetwork = false,
    bool disableStreaming = false,
  }) async {
    try {
      final existingHolder = DecoderManager.instance.getHolder(_fullKey);
      if (!forceNetwork &&
          !disableStreaming &&
          existingHolder != null &&
          !existingHolder.disposed) {
        if (existingHolder.decoder.isStreaming) {
          debugPrint(
            '[WebP-Stream][visible] REUSE-HOLDER ${existingHolder.shortKey} '
            'frames=${existingHolder.decoder.frameCount} decoded=${existingHolder.decodedFrameCount} '
            'buf=${existingHolder.bufferLength} raw=${existingHolder.queuedFrameCount - existingHolder.bufferLength} '
            'closed=${existingHolder.streamNeedsResume} failed=${existingHolder.streamFailed} '
            'loaded=${existingHolder.streamLoadedBytes}/${existingHolder.streamExpectedBytes ?? -1}',
          );
        }
        return _ImageResult.animated(existingHolder);
      }

      // L1 cache check (decoded ui.Image in memory)
      if (!forceNetwork && cache != null) {
        final cached = cache!.getL1(_fullKey);
        if (cached != null) {
          return _ImageResult.static(ImageInfo(image: cached, scale: scale));
        }
      }

      // Get bytes — check L2 cache first, then network / local file.
      Uint8List bytes;
      if (forceNetwork) {
        cache?.evictL2(imageKey);
        await CacheManager().delete('$imageKey@$sourceKey@$cid@$eid');
      }
      if (!forceNetwork && cache?.hasL2(imageKey) == true) {
        final cached = cache!.getL2(imageKey)!;
        if (ImageDownloader.isIncompleteWebPBytes(cached)) {
          cache!.evictL2(imageKey);
          bytes = Uint8List(0);
        } else {
          bytes = cached;
        }
      } else {
        bytes = Uint8List(0);
      }
      if (bytes.isEmpty) {
        final cachedBytes = forceNetwork
            ? null
            : await tryReadFromCache(imageKey, sourceKey, cid, eid);
        if (cachedBytes != null) {
          bytes = cachedBytes;
        } else {
          final progressive = disableStreaming
              ? null
              : await _tryLoadAnimatedStreaming(chunkEvents: chunkEvents);
          if (progressive?.holder != null) {
            return _ImageResult.animated(
              progressive!.holder!,
              progressiveSub: progressive.subscription,
            );
          }
          bytes =
              progressive?.bytes ?? await _fetchBytes(chunkEvents: chunkEvents);
          if (cache != null && webp.isWebP(bytes)) {
            cache!.putL2(imageKey, bytes);
          }
        }
      }

      // Check if WebP
      if (!webp.isWebP(bytes)) return _ImageResult.fallback(bytes);

      final info = webp.getInfo(bytes);
      if (info == null) return _ImageResult.error('Invalid WebP header');

      if (info.isAnimated) {
        final holder = await _createAnimatedHolder(bytes, info);
        if (holder != null) {
          PipelineController.instance.publishExternalHolder(
            imageKey,
            _fullKey,
            holder,
          );
          return _ImageResult.animated(holder);
        }
        return _ImageResult.error('Failed to create animated decoder');
      } else {
        final image = await _decodeStatic(bytes, info);
        if (image != null) {
          if (cache != null) cache!.putL1(_fullKey, image);
          return _ImageResult.static(ImageInfo(image: image, scale: scale));
        }
        return _ImageResult.error('WebP static decode failed');
      }
    } catch (e) {
      return _ImageResult.error(e);
    }
  }

  Future<_ProgressiveLoadResult?> _tryLoadAnimatedStreaming({
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

  StreamSubscription<ImageDownloadProgress>? _resumeStreamingIntoHolder(
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

  Future<Uint8List> _fetchBytes({
    StreamController<ImageChunkEvent>? chunkEvents,
  }) async {
    return fetchImageBytes(
      imageKey,
      sourceKey,
      cid,
      eid,
      chunkEvents: chunkEvents,
      debugLabel: 'webp-visible:$imageKey',
      onEvent: (event) {
        PipelineController.instance.publishExternalDownloadProgress(
          imageKey,
          event.currentBytes,
          event.totalBytes,
          done: event.imageBytes != null,
        );
      },
    );
  }

  /// Step 2: Create animated decoder holder from bytes.
  Future<DecoderHolder?> _createAnimatedHolder(
    Uint8List bytes,
    webp.WebPImageInfo info,
  ) async {
    final (tw, th) = _resolveWebPDecodeTarget(info, targetWidth, targetHeight);

    try {
      final decoder = webp.createAnimDecoder(
        bytes,
        targetWidth: tw,
        targetHeight: th,
      );
      if (decoder == null) return null;
      return DecoderManager.instance.getOrCreateHolder(
        _fullKey,
        decoder,
        tw,
        th,
        scale,
      );
    } catch (_) {
      return null;
    }
  }

  /// Step 3: Decode static WebP to ui.Image.
  Future<ui.Image?> _decodeStatic(
    Uint8List bytes,
    webp.WebPImageInfo info,
  ) async {
    final (tw, th) = _resolveWebPDecodeTarget(info, targetWidth, targetHeight);
    final frame = webp.decodeStatic(bytes, targetWidth: tw, targetHeight: th);
    if (frame == null) return null;
    return _rgbaToUiImage(frame.rgba, frame.width, frame.height);
  }

  Future<ui.Image> _rgbaToUiImage(Uint8List rgba, int w, int h) async {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}
