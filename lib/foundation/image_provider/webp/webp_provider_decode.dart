part of '../webp_image_provider.dart';

extension _WebPImageProviderDecode on WebPImageProvider {
  Future<_ImageResult> _decodeLoadedBytes(Uint8List bytes) async {
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
    }
    final image = await _decodeStatic(bytes, info);
    if (image != null) {
      if (cache != null) cache!.putL1(_fullKey, image);
      return _ImageResult.static(ImageInfo(image: image, scale: scale));
    }
    return _ImageResult.error('WebP static decode failed');
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
