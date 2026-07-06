import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
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
    String defaultUrl,
    Map<String, dynamic>? map,
  ) {
    map ??= {};

    final headers = Map<String, dynamic>.from(map['headers'] ?? {});
    headers.putIfAbsent('user-agent', () => webUA);

    return ImageRequestConfig(
      url: map['url'] ?? defaultUrl,
      method: map['method'] ?? 'GET',
      headers: headers,
      data: map['data'],
      onResponse:
          map['onResponse'] is JSInvokable ? map['onResponse'] as JSInvokable : null,
      onLoadFailed:
          map['onLoadFailed'] is JSInvokable ? map['onLoadFailed'] as JSInvokable : null,
      modifyImage: map['modifyImage'],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// _SharedStream — ref-counted broadcast stream manager
// Replaces _StreamWrapper (manual List<StreamController>).
//
// Key design decision (from original _StreamWrapper):
//   - Upstream download KEEPS RUNNING even when all listeners unsubscribe.
//   - This ensures the download completes and populates the disk cache.
//   - Only explicit cancelAllLoadingImages() or natural completion/error
//     stops the upstream.
//
// Single StreamController.broadcast() instead of N controllers.
// ═══════════════════════════════════════════════════════════════

class _SharedStream {
  late final StreamController<ImageDownloadProgress> _controller;
  final void Function() _onDispose;
  StreamSubscription? _upstreamSub;
  int _listenerCount = 0;
  bool _disposed = false;

  _SharedStream(
    Stream<ImageDownloadProgress> source,
    this._onDispose,
  ) {
    _controller = StreamController<ImageDownloadProgress>.broadcast(
      onListen: () {
        _listenerCount++;
        _upstreamSub ??= source.listen(
          _controller.add,
          onError: (Object e, StackTrace st) {
            _controller.addError(e, st);
            _close();
          },
          onDone: _close,
        );
      },
      onCancel: () {
        _listenerCount--;
        if (_listenerCount < 0) {
          _listenerCount = 0;
        }
        // IMPORTANT: Do NOT cancel upstream here.
        // The original _StreamWrapper kept the download alive even when
        // all listeners disappeared — this ensures the file gets cached
        // on disk for subsequent requests.
      },
    );
  }

  Stream<ImageDownloadProgress> get stream => _controller.stream;

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

  /// Force-cancel upstream and close all listeners (used by cancelAllLoadingImages).
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

  /// Cancel all in-flight image loads.
  static void cancelAllLoadingImages() {
    // Copy values first — each cancel() calls _onDispose which removes from map.
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

    // 1. Check disk cache — yield immediately if found, then return
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

    // 2. Build config from comic source
    Map<String, dynamic>? rawConfig;
    if (sourceKey != null) {
      final cs = ComicSource.find(sourceKey);
      rawConfig = cs?.getThumbnailLoadingConfig?.call(url) ?? {};
    }

    // 3. Handle indirect "cover.xxx" URLs
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
  /// Multiple simultaneous calls for the same [imageKey]+[sourceKey]+[cid]+[eid]
  /// share a single network request. Uses [_SharedStream] for automatic cleanup
  /// when all listeners unsubscribe.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";

    final existing = _loadingImages[cacheKey];
    if (existing != null) {
      return existing.stream;
    }

    final shared = _SharedStream(
      _loadComicImage(imageKey, sourceKey, cid, eid),
      () => _loadingImages.remove(cacheKey),
    );
    _loadingImages[cacheKey] = shared;
    return shared.stream;
  }

  /// Load a comic image without deduplication.
  ///
  /// Each call creates an independent download stream. Used when the caller
  /// needs its own retry/error path (e.g., download manager).
  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return _loadComicImage(imageKey, sourceKey, cid, eid);
  }

  // ─────────────────────────────────────────────────────────────
  // Private: Comic image loader (with retry loop)
  // ─────────────────────────────────────────────────────────────

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";

    // Cache hit → yield immediately and return (no network request)
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

    // Build initial config
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
        );
        // Success — free unused onLoadFailed JS handle
        config.onLoadFailed?.free();
        return;
      } catch (e) {
        retry--;
        if (retry < 0 || config.onLoadFailed == null) {
          config.onLoadFailed?.free();
          rethrow;
        }
        // Invoke retry callback → get new config
        final newConfig = await _invokeLoadFailed(config.onLoadFailed!, config.url);
        // _invokeLoadFailed frees the JS handle
        if (newConfig == null) {
          rethrow;
        }
        config = newConfig;
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Private: Retry helper
  // ─────────────────────────────────────────────────────────────

  /// Invokes the onLoadFailed JS callback and returns a new config.
  /// Frees the [callback] JS handle after invocation.
  /// [originalUrl] is used as fallback when the retry result doesn't include a url field.
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

  // ─────────────────────────────────────────────────────────────
  // Private: Unified download executor
  //
  // Shared flow for both thumbnail and comic image loading:
  //   build request → stream bytes (yield progress) →
  //   apply onResponse → [optional modifyImage] → write cache →
  //   yield complete
  // ─────────────────────────────────────────────────────────────

  static Stream<ImageDownloadProgress> _executeDownload({
    required ImageRequestConfig config,
    required String cacheKey,
    bool enableModifyImage = false,
  }) async* {
    String requestUrl = config.url;
    if (requestUrl.isEmpty) {
      throw Exception('Empty request URL');
    }
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    // Validate: bare filenames without scheme → error
    if (!requestUrl.contains('://')) {
      throw Exception('Not a valid URL: "$requestUrl"');
    }

    final dio = AppDio(BaseOptions(
      headers: config.headers,
      method: config.method,
      responseType: ResponseType.stream,
    ));

    final req = await dio.request<ResponseBody>(requestUrl, data: config.data);
    final stream = req.data?.stream ?? (throw Exception('Error: Empty response body.'));

    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }

    // Collect bytes while yielding progress events
    var buffer = <int>[];
    await for (final chunk in stream) {
      buffer.addAll(chunk);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    // Apply onResponse JS transformation (decrypt, unpack, etc.)
    if (config.onResponse != null) {
      dynamic result = config.onResponse!([Uint8List.fromList(buffer)]);
      if (result is Future) {
        result = await result;
      }
      if (result is List<int>) {
        buffer = result;
      } else {
        throw Exception('Error: Invalid onResponse result.');
      }
      config.onResponse!.free();
    }

    // Convert to Uint8List (avoid copy if already correct type)
    final Uint8List data;
    if (buffer is Uint8List) {
      data = buffer;
    } else {
      data = Uint8List.fromList(buffer);
      buffer.clear();
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
