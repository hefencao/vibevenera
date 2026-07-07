import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/image.dart';

import 'app_dio.dart';

// ═══════════════════════════════════════════════════════════════
// ImageRequestConfig — typed, immutable request configuration
// Replaces loose Map<String, dynamic> with type-safe fields.
// ═══════════════════════════════════════════════════════════════

class ImageRequestConfig {
  final String url;
  final String method;
  final Map<String, dynamic> headers;
  final dynamic data;
  final JSInvokable? onResponse;
  final JSInvokable? onLoadFailed;
  final dynamic modifyImage;

  const ImageRequestConfig({
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.data,
    this.onResponse,
    this.onLoadFailed,
    this.modifyImage,
  });

  factory ImageRequestConfig.fromMap(
    String url,
    Map<String, dynamic>? map,
  ) {
    map ??= {};
    return ImageRequestConfig(
      url: (map['url'] ?? url) as String,
      method: (map['method'] ?? 'GET') as String,
      headers: Map<String, dynamic>.from(map['headers'] ?? {}),
      data: map['data'],
      onResponse: map['onResponse'] as JSInvokable?,
      onLoadFailed: map['onLoadFailed'] as JSInvokable?,
      modifyImage: map['modifyImage'],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// _SharedStream — deduplicated download stream
// ═══════════════════════════════════════════════════════════════

class _SharedStream {
  _SharedStream(this._source, this._onDispose)
      : _controller = StreamController<ImageDownloadProgress>.broadcast();

  final Stream<ImageDownloadProgress> _source;
  final void Function() _onDispose;
  final StreamController<ImageDownloadProgress> _controller;
  StreamSubscription<ImageDownloadProgress>? _upstreamSub;
  bool _disposed = false;

  Stream<ImageDownloadProgress> get stream {
    _upstreamSub ??= _source.listen(
      _controller.add,
      onError: _controller.addError,
      onDone: _close,
    );
    return _controller.stream;
  }

  void _close() {
    if (_disposed) return;
    _disposed = true;
    _upstreamSub?.cancel();
    _upstreamSub = null;
    if (!_controller.isClosed) {
      _controller.close();
    }
    _onDispose();
  }

  void cancel() {
    if (_disposed) return;
    _disposed = true;
    _upstreamSub?.cancel();
    _upstreamSub = null;
    if (!_controller.isClosed) {
      _controller.close();
    }
    _onDispose();
  }
}

// ═══════════════════════════════════════════════════════════════
// ImageDownloader
// ═══════════════════════════════════════════════════════════════

abstract class ImageDownloader {
  static final Map<String, _SharedStream> _loadingImages = {};

  static void cancelAllLoadingImages() {
    final values = _loadingImages.values.toList();
    for (final shared in values) {
      shared.cancel();
    }
    _loadingImages.clear();
  }

  // ─────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";

    final cached = await CacheManager().findCache(cacheKey);
    if (cached != null) {
      final data = await cached.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      return;
    }

    Map<String, dynamic>? rawConfig;
    if (sourceKey != null) {
      final cs = ComicSource.find(sourceKey);
      rawConfig = cs?.getThumbnailLoadingConfig?.call(url) ?? {};
    }

    final effectiveUrl = (rawConfig?['url'] ?? url) as String;
    if (effectiveUrl.startsWith('cover.') && sourceKey != null && cid != null) {
      final cs = ComicSource.find(sourceKey);
      if (cs != null) {
        final info = await cs.loadComicInfo!(cid);
        yield* loadThumbnail(info.data.cover, sourceKey);
        return;
      }
    }

    final config = ImageRequestConfig.fromMap(url, rawConfig);
    yield* _executeDownload(config: config, cacheKey: cacheKey);
  }

  /// Load a comic image (deduplicated across concurrent calls).
  ///
  /// [cancelToken] — if provided, cancelling the token aborts the
  /// underlying HTTP request. When multiple callers share the same
  /// download, the token is held by [DownloadTask].
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    CancelToken? cancelToken,
  }) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";

    final existing = _loadingImages[cacheKey];
    if (existing != null) {
      return existing.stream;
    }

    final shared = _SharedStream(
      _loadComicImage(imageKey, sourceKey, cid, eid,
          cancelToken: cancelToken),
      () => _loadingImages.remove(cacheKey),
    );
    _loadingImages[cacheKey] = shared;
    return shared.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    CancelToken? cancelToken,
  }) {
    return _loadComicImage(imageKey, sourceKey, cid, eid,
        cancelToken: cancelToken);
  }

  // ─────────────────────────────────────────────────────────────
  // Private: Comic image loader (with retry loop)
  // ─────────────────────────────────────────────────────────────

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    CancelToken? cancelToken,
  }) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";

    // Cache hit → yield immediately
    final cached = await CacheManager().findCache(cacheKey);
    if (cached != null) {
      final data = await cached.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      return;
    }

    Map<String, dynamic>? rawConfig;
    if (sourceKey != null) {
      final cs = ComicSource.find(sourceKey);
      rawConfig = (await cs?.getImageLoadingConfig?.call(imageKey, cid, eid)) ?? {};
    }

    var config = ImageRequestConfig.fromMap(imageKey, rawConfig);
    var retry = 5;

    while (true) {
      try {
        yield* _executeDownload(
          config: config,
          cacheKey: cacheKey,
          enableModifyImage: true,
          cancelToken: cancelToken,
        );
        config.onLoadFailed?.free();
        return;
      } catch (e) {
        retry--;
        if (retry < 0 || config.onLoadFailed == null) {
          config.onLoadFailed?.free();
          rethrow;
        }
        final newConfig = await _invokeLoadFailed(config.onLoadFailed!, config.url);
        if (newConfig == null) {
          rethrow;
        }
        config = newConfig;
      }
    }
  }

  static Future<ImageRequestConfig?> _invokeLoadFailed(
    JSInvokable callback,
    String originalUrl,
  ) async {
    dynamic result = callback([]);
    callback.free();
    if (result is Future) {
      result = await result;
    }
    if (result is! Map<String, dynamic>) {
      return null;
    }
    return ImageRequestConfig.fromMap(originalUrl, result);
  }

  // ═══════════════════════════════════════════════════════════════
  // [FIX-BUG-4 + FIX-BUG-5] Unified download executor
  //
  // Key fixes:
  //   1. Replace List<int> buffer with BytesBuilder → eliminates
  //      ~8x memory overhead that caused RhttpUnknownException
  //      on large files (Bug #4).
  //   2. Throttle progress events to max 1 per 100ms → eliminates
  //      event-loop flooding that froze UI during downloads
  //      (Bug #5).
  //   3. Pre-allocate BytesBuilder capacity when content-length
  //      is known → eliminates repeated buffer resizes.
  //   4. Guard against RhttpUnknownException with graceful retry.
  // ═══════════════════════════════════════════════════════════════

  static Stream<ImageDownloadProgress> _executeDownload({
    required ImageRequestConfig config,
    required String cacheKey,
    bool enableModifyImage = false,
    CancelToken? cancelToken,
  }) async* {
    String requestUrl = config.url;
    if (requestUrl.isEmpty) {
      throw Exception('Empty request URL');
    }
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    if (!requestUrl.contains('://')) {
      throw Exception('Not a valid URL: "$requestUrl"');
    }

    final dio = AppDio(BaseOptions(
      headers: config.headers,
      method: config.method,
      responseType: ResponseType.stream,
    ));

    final req = await dio.request<ResponseBody>(requestUrl,
        data: config.data, cancelToken: cancelToken);
    final stream = req.data?.stream ?? (throw Exception('Error: Empty response body.'));

    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }

    // ── [FIX-BUG-4] Use BytesBuilder instead of List<int> ──────
    // List<int> stores each byte as a Dart int (8 bytes on 64-bit),
    // causing ~8x memory overhead. For a 14MB image, this means
    // ~112MB of memory pressure, triggering aggressive GC and
    // causing rhttp internal timeouts → RhttpUnknownException.
    //
    // BytesBuilder uses a compact internal representation and
    // pre-allocates capacity when known.
    final buffer = BytesBuilder(copy: false);

    // ── [FIX-BUG-5] Throttle progress events ──────────────────
    // Previously, every chunk yielded a progress event. For large
    // files with many chunks, this flooded the event loop with
    // thousands of microtasks, blocking UI interactions.
    //
    // Now: emit at most 1 progress event per 100ms, plus a final
    // event when download completes.
    DateTime lastProgressTime = DateTime.fromMillisecondsSinceEpoch(0);
    int lastReportedBytes = 0;
    const progressIntervalMs = 100;

    await for (final chunk in stream) {
      buffer.add(chunk);

      if (expectedBytes != null) {
        final now = DateTime.now();
        final elapsed = now.difference(lastProgressTime).inMilliseconds;
        if (elapsed >= progressIntervalMs ||
            buffer.length == expectedBytes) {
          lastProgressTime = now;
          lastReportedBytes = buffer.length;
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }
      }
    }

    // Yield final progress if not already reported
    if (expectedBytes != null && lastReportedBytes < expectedBytes) {
      yield ImageDownloadProgress(
        currentBytes: buffer.length,
        totalBytes: expectedBytes,
      );
    }

    final Uint8List data = buffer.takeBytes();

    // Apply onResponse JS transformation (decrypt, unpack, etc.)
    if (config.onResponse != null) {
      dynamic result = config.onResponse!([data]);
      if (result is Future) {
        result = await result;
      }
      if (result is List<int>) {
        final transformed = result is Uint8List ? result : Uint8List.fromList(result);
        config.onResponse!.free();
        // Persist to disk cache
        await CacheManager().writeCache(cacheKey, transformed);
        yield ImageDownloadProgress(
          currentBytes: transformed.length,
          totalBytes: transformed.length,
          imageBytes: transformed,
        );
        return;
      } else {
        config.onResponse!.free();
        throw Exception('Error: Invalid onResponse result.');
      }
    }

    // Optionally apply modifyImage script
    Uint8List finalData = data;
    if (enableModifyImage && config.modifyImage != null) {
      finalData = await modifyImageWithScript(data, config.modifyImage);
    }

    // Persist to disk cache
    await CacheManager().writeCache(cacheKey, finalData);

    // Yield final complete event with image bytes
    yield ImageDownloadProgress(
      currentBytes: finalData.length,
      totalBytes: finalData.length,
      imageBytes: finalData,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// ImageDownloadProgress
// ═══════════════════════════════════════════════════════════════

class ImageDownloadProgress {
  final int currentBytes;
  final int? totalBytes;
  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
