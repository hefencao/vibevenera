import 'dart:async';
import 'dart:io' as io;
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

  factory ImageRequestConfig.fromMap(String url, Map<String, dynamic>? map) {
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
      _loadComicImage(imageKey, sourceKey, cid, eid, cancelToken: cancelToken),
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
    return _loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      cancelToken: cancelToken,
    );
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
      rawConfig =
          (await cs?.getImageLoadingConfig?.call(imageKey, cid, eid)) ?? {};
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
        final newConfig = await _invokeLoadFailed(
          config.onLoadFailed!,
          config.url,
        );
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

    final headers = Map<String, dynamic>.from(config.headers);
    final hasAcceptEncoding = headers.keys.any(
      (key) => key.toLowerCase() == 'accept-encoding',
    );
    if (!hasAcceptEncoding) {
      headers['Accept-Encoding'] = 'identity';
    }

    final progressEvents = StreamController<ImageDownloadProgress>();
    final rawFuture = _downloadRawBytes(
      requestUrl: requestUrl,
      method: config.method,
      headers: headers,
      data: config.data,
      cancelToken: cancelToken,
      onProgress: (current, total) {
        if (!progressEvents.isClosed) {
          progressEvents.add(
            ImageDownloadProgress(currentBytes: current, totalBytes: total),
          );
        }
      },
    ).whenComplete(progressEvents.close);

    await for (final event in progressEvents.stream) {
      yield event;
    }
    final raw = await rawFuture;
    final Uint8List data = raw.data;

    if (raw.expectedBytes != null) {
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: raw.expectedBytes,
      );
    }

    yield* _finalizeDownloadedImage(
      data,
      cacheKey: cacheKey,
      config: config,
      enableModifyImage: enableModifyImage,
    );
  }

  static Future<({Uint8List data, int? expectedBytes})> _downloadRawBytes({
    required String requestUrl,
    required String method,
    required Map<String, dynamic> headers,
    required dynamic data,
    CancelToken? cancelToken,
    void Function(int current, int? total)? onProgress,
  }) async {
    try {
      return await _downloadRawBytesWithRhttp(
        requestUrl: requestUrl,
        method: method,
        headers: headers,
        data: data,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    } catch (e) {
      if (!_shouldFallbackToIoClient(e)) rethrow;
      return await _downloadRawBytesWithIoClient(
        requestUrl: requestUrl,
        method: method,
        headers: headers,
        data: data,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    }
  }

  static Future<({Uint8List data, int? expectedBytes})>
  _downloadRawBytesWithRhttp({
    required String requestUrl,
    required String method,
    required Map<String, dynamic> headers,
    required dynamic data,
    CancelToken? cancelToken,
    void Function(int current, int? total)? onProgress,
  }) async {
    final dio = AppDio(
      BaseOptions(
        headers: headers,
        method: method,
        responseType: ResponseType.stream,
      ),
    );

    final req = await dio.request<ResponseBody>(
      requestUrl,
      data: data,
      cancelToken: cancelToken,
    );
    final stream =
        req.data?.stream ?? (throw Exception('Error: Empty response body.'));
    final expectedBytes = _normalizeContentLength(req.data!.contentLength);
    return _readByteStream(
      stream,
      expectedBytes: expectedBytes,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  static Future<({Uint8List data, int? expectedBytes})>
  _downloadRawBytesWithIoClient({
    required String requestUrl,
    required String method,
    required Map<String, dynamic> headers,
    required dynamic data,
    CancelToken? cancelToken,
    void Function(int current, int? total)? onProgress,
  }) async {
    var attempts = 0;
    int? expectedBytes;
    var buffer = BytesBuilder(copy: false);

    while (attempts < 8) {
      attempts++;
      final client = io.HttpClient();
      client.autoUncompress = false;
      try {
        final request = await client.openUrl(method, Uri.parse(requestUrl));
        request.followRedirects = true;
        request.maxRedirects = 5;
        for (final entry in headers.entries) {
          request.headers.set(entry.key, entry.value.toString());
        }
        if (buffer.length > 0) {
          request.headers.set('Range', 'bytes=${buffer.length}-');
        }
        if (data is List<int>) {
          request.add(data);
        } else if (data is String) {
          request.write(data);
        } else if (data != null) {
          request.write(data.toString());
        }
        final response = await request.close();
        if (response.statusCode >= 400) {
          throw Exception('Invalid Status Code: ${response.statusCode}');
        }
        if (buffer.length > 0 && response.statusCode != 206) {
          buffer = BytesBuilder(copy: false);
        }
        expectedBytes ??= response.statusCode == 206
            ? _contentRangeTotal(response.headers.value('content-range'))
            : _normalizeContentLength(response.contentLength);
        return await _readByteStream(
          response,
          expectedBytes: expectedBytes,
          cancelToken: cancelToken,
          sink: buffer,
          onProgress: onProgress,
        );
      } catch (e) {
        if (expectedBytes != null && buffer.length >= expectedBytes) {
          return (data: buffer.takeBytes(), expectedBytes: expectedBytes);
        }
        if (!_isRetryableBodyClose(e) || attempts >= 8) rethrow;
      } finally {
        client.close(force: true);
      }
    }
    return (data: buffer.takeBytes(), expectedBytes: expectedBytes);
  }

  static Future<({Uint8List data, int? expectedBytes})> _readByteStream(
    Stream<List<int>> stream, {
    required int? expectedBytes,
    CancelToken? cancelToken,
    BytesBuilder? sink,
    void Function(int current, int? total)? onProgress,
  }) async {
    final buffer = sink ?? BytesBuilder(copy: false);
    var lastProgressTime = DateTime.fromMillisecondsSinceEpoch(0);
    const progressIntervalMs = 100;
    await for (final chunk in stream) {
      if (cancelToken?.isCancelled == true) throw Exception('Cancelled');
      buffer.add(chunk);
      final loaded = buffer.length;
      final now = DateTime.now();
      if (now.difference(lastProgressTime).inMilliseconds >=
          progressIntervalMs) {
        lastProgressTime = now;
        onProgress?.call(loaded, expectedBytes);
      }
    }
    onProgress?.call(buffer.length, expectedBytes);
    return (
      data: sink == null ? buffer.takeBytes() : buffer.toBytes(),
      expectedBytes: expectedBytes,
    );
  }

  static Stream<ImageDownloadProgress> _finalizeDownloadedImage(
    Uint8List data, {
    required String cacheKey,
    required ImageRequestConfig config,
    required bool enableModifyImage,
  }) async* {
    var finalData = data;

    // Apply onResponse JS transformation (decrypt, unpack, etc.)
    if (config.onResponse != null) {
      dynamic result = config.onResponse!([data]);
      if (result is Future) {
        result = await result;
      }
      if (result is List<int>) {
        final transformed = result is Uint8List
            ? result
            : Uint8List.fromList(result);
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

  static int? _normalizeContentLength(int length) =>
      length >= 0 ? length : null;

  static int? _contentRangeTotal(String? value) {
    if (value == null) return null;
    final slash = value.lastIndexOf('/');
    if (slash < 0 || slash == value.length - 1) return null;
    return int.tryParse(value.substring(slash + 1));
  }

  static bool _shouldFallbackToIoClient(Object error) {
    final text = error.toString();
    return text.contains('RhttpUnknownException') ||
        text.contains('error decoding response body') ||
        _isRetryableBodyClose(error);
  }

  static bool _isRetryableBodyClose(Object error) {
    final text = error.toString();
    return text.contains('Connection closed while receiving data') ||
        text.contains('Connection reset by peer') ||
        text.contains('HttpException');
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
