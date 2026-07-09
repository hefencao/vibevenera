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

      return await _decodeLoadedBytes(bytes);
    } catch (e) {
      return _ImageResult.error(e);
    }
  }

  Future<_ProgressiveLoadResult?> _tryLoadAnimatedStreaming({
    StreamController<ImageChunkEvent>? chunkEvents,
  }) =>
      WebPStreamSession(this).loadAnimated(chunkEvents: chunkEvents);

  StreamSubscription<ImageDownloadProgress>? _resumeStreamingIntoHolder(
    DecoderHolder holder, {
    void Function()? onDone,
  }) =>
      WebPStreamSession(this).resumeIntoHolder(holder, onDone: onDone);
}
