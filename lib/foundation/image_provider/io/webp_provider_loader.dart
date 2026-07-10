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
          if (existingHolder.streamFailed) {
            existingHolder.dispose();
          } else if (existingHolder.streamNeedsResume) {
            final cachedBytes =
                await tryReadFromCache(imageKey, sourceKey, cid, eid);
            if (cachedBytes != null && webp.isWebP(cachedBytes)) {
              existingHolder.dispose();
            } else {
              return _ImageResult.animated(existingHolder);
            }
          } else {
            return _ImageResult.animated(existingHolder);
          }
        } else {
          return _ImageResult.animated(existingHolder);
        }
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
    final pipeline = PipelineController.instance;
    if (pipeline.isManagingFullKey(_fullKey)) {
      final pipelineResult = pipeline.waitForStreamResult(_fullKey);
      pipeline.ensureStreamWork(_fullKey);
      final result = await pipelineResult;
      if (result is DecoderHolder && !result.disposed) {
        return _ProgressiveLoadResult.animated(result);
      }
      if (result is Uint8List) return _ProgressiveLoadResult.bytes(result);
      return null;
    }
    return _WebPStreamSession(this).loadAnimated(chunkEvents: chunkEvents);
  }

  StreamSubscription<ImageDownloadProgress>? _resumeStreamingIntoHolder(
    DecoderHolder holder, {
    void Function()? onDone,
  }) =>
      _WebPStreamSession(this).resumeIntoHolder(holder, onDone: onDone);

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
