import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
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

class _DownloadResumeState {
  BytesBuilder _buffer = BytesBuilder(copy: false);
  int? expectedBytes;

  int get downloadedBytes => _buffer.length;

  bool get isComplete =>
      expectedBytes != null && downloadedBytes >= expectedBytes!;

  void add(List<int> chunk) => _buffer.add(chunk);

  void resetDownloadedBytes() {
    _buffer = BytesBuilder(copy: false);
  }

  Uint8List takeBytes() => _buffer.takeBytes();
}

class _RangeNotSupportedException implements Exception {
  _RangeNotSupportedException(this.offset, this.statusCode, this.url);

  final int offset;
  final int statusCode;
  final String url;

  @override
  String toString() =>
      'Range request ignored: offset=$offset status=$statusCode url=$url';
}

// ═══════════════════════════════════════════════════════════════
// ImageDownloader
// ═══════════════════════════════════════════════════════════════

abstract class ImageDownloader {
  static final Map<String, _SharedStream> _loadingImages = {};
  static const _rhttpMaxAttempts = 3;
  static const _ioMaxAttempts = 3;

  static String _shortDownloadKey(String key) {
    if (key.length <= 96) return key;
    return '${key.substring(0, 48)}...${key.substring(key.length - 36)}';
  }

  static void _warnDownload(String? debugLabel, String message) {
    Log.warning(
      'ImageDownloader',
      '[ImageDownload][${debugLabel ?? 'unknown'}] $message',
    );
  }

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
    String? debugLabel,
  }) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";

    final existing = _loadingImages[cacheKey];
    if (existing != null) {
      return existing.stream;
    }

    final shared = _SharedStream(
      _loadComicImage(
        imageKey,
        sourceKey,
        cid,
        eid,
        cancelToken: cancelToken,
        debugLabel: debugLabel,
      ),
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
    String? debugLabel,
  }) {
    return _loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      cancelToken: cancelToken,
      debugLabel: debugLabel ?? 'raw',
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
    String? debugLabel,
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
        await for (final event in _executeDownload(
          config: config,
          cacheKey: cacheKey,
          enableModifyImage: true,
          cancelToken: cancelToken,
          debugLabel: debugLabel,
        )) {
          yield event;
        }
        config.onLoadFailed?.free();
        return;
      } catch (e) {
        _warnDownload(
          debugLabel,
          'FAIL retryLeft=$retry url=${_shortDownloadKey(config.url)} error=$e',
        );
        while (true) {
          retry--;
          if (retry < 0 || config.onLoadFailed == null) {
            config.onLoadFailed?.free();
            rethrow;
          }
          final oldUrl = config.url;
          final newConfig = await _invokeLoadFailed(
            config.onLoadFailed!,
            oldUrl,
          );
          if (newConfig == null) {
            rethrow;
          }
          final sameUrl = _sameRequestUrl(oldUrl, newConfig.url);
          _warnDownload(
            debugLabel,
            'LOAD_FAILED ${sameUrl ? 'sameUrl-skip' : 'newUrl'} '
                'retryLeft=$retry url=${_shortDownloadKey(newConfig.url)}',
          );
          config = newConfig;
          if (!sameUrl) break;
        }
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

  static bool _sameRequestUrl(String a, String b) =>
      _normalizeRequestUrl(a) == _normalizeRequestUrl(b);

  static String _normalizeRequestUrl(String url) =>
      url.startsWith('//') ? 'https:$url' : url;

  // Downloads image bytes as a stream, reports throttled progress,
  // and resumes interrupted large bodies with HTTP Range requests.

  static Stream<ImageDownloadProgress> _executeDownload({
    required ImageRequestConfig config,
    required String cacheKey,
    bool enableModifyImage = false,
    CancelToken? cancelToken,
    String? debugLabel,
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
      debugLabel: debugLabel,
      preferLoadFailedOnRangeIgnored: config.onLoadFailed != null,
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
    String? debugLabel,
    required bool preferLoadFailedOnRangeIgnored,
    void Function(int current, int? total)? onProgress,
  }) async {
    final state = _DownloadResumeState();
    try {
      return await _downloadRawBytesWithRhttp(
        requestUrl: requestUrl,
        method: method,
        headers: headers,
        data: data,
        cancelToken: cancelToken,
        debugLabel: debugLabel,
        onProgress: onProgress,
        state: state,
      );
    } catch (e) {
      if (!_shouldFallbackToIoClient(
        e,
        preferLoadFailedOnRangeIgnored: preferLoadFailedOnRangeIgnored,
      )) {
        rethrow;
      }
      Log.warning(
        'ImageDownloader',
        'Dio/rhttp failed, fallback to HttpClient '
            'label=${debugLabel ?? 'unknown'}; '
            'downloaded=${state.downloadedBytes} '
            'expected=${state.expectedBytes}; $e',
      );
      return await _downloadRawBytesWithIoClient(
        requestUrl: requestUrl,
        method: method,
        headers: headers,
        data: data,
        cancelToken: cancelToken,
        debugLabel: debugLabel,
        onProgress: onProgress,
        state: state,
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
    String? debugLabel,
    void Function(int current, int? total)? onProgress,
    required _DownloadResumeState state,
  }) async {
    var attempts = 0;

    while (attempts < _rhttpMaxAttempts) {
      attempts++;
      final requestHeaders = Map<String, dynamic>.from(headers);
      final resumeOffset = _canResume(method) ? state.downloadedBytes : 0;
      if (resumeOffset > 0) {
        requestHeaders['Range'] = 'bytes=$resumeOffset-';
      }

      try {
        final dio = AppDio(
          BaseOptions(
            headers: requestHeaders,
            method: method,
            responseType: ResponseType.stream,
            extra: const {'disableReceiveTimeout': true},
          ),
        );

        final response = await dio.request<ResponseBody>(
          requestUrl,
          data: data,
          cancelToken: cancelToken,
        );

        final statusCode = response.statusCode ?? 0;
        if (statusCode >= 400) {
          throw Exception('Invalid Status Code: $statusCode');
        }

        final rangeAccepted = resumeOffset == 0 || statusCode == 206;
        if (!rangeAccepted) {
          Log.warning(
            'ImageDownloader',
            'Dio/rhttp Range ignored: offset=$resumeOffset '
                'status=$statusCode url=$requestUrl',
          );
          throw _RangeNotSupportedException(
            resumeOffset,
            statusCode,
            requestUrl,
          );
        }

        final effectiveOffset = rangeAccepted ? resumeOffset : 0;
        final contentRange = response.headers.value('content-range');
        final contentRangeStart = _contentRangeStart(contentRange);
        if (resumeOffset > 0 &&
            statusCode == 206 &&
            contentRangeStart != null &&
            contentRangeStart != resumeOffset) {
          throw Exception(
            'Invalid Content-Range start: $contentRangeStart '
            '(expected $resumeOffset)',
          );
        }

        state.expectedBytes = _expectedBytesFromResponse(
          statusCode: statusCode,
          contentRange: contentRange,
          contentLength: response.data?.contentLength ?? -1,
          resumeOffset: effectiveOffset,
          fallback: state.expectedBytes,
        );

        final stream =
            response.data?.stream ??
            (throw Exception('Error: Empty response body.'));
        return await _readByteStream(
          stream,
          state: state,
          cancelToken: cancelToken,
          onProgress: onProgress,
        );
      } catch (e) {
        if (state.isComplete) {
          return (data: state.takeBytes(), expectedBytes: state.expectedBytes);
        }
        if (!_isResumableDownloadError(e) || attempts >= _rhttpMaxAttempts) {
          rethrow;
        }
        Log.warning(
          'ImageDownloader',
          'Dio/rhttp resume attempt $attempts failed '
              'label=${debugLabel ?? 'unknown'}; '
              'downloaded=${state.downloadedBytes} '
              'expected=${state.expectedBytes} '
              'nextRange=${state.downloadedBytes > 0 ? state.downloadedBytes : null}; '
              '$e',
        );
      }
    }
    return (data: state.takeBytes(), expectedBytes: state.expectedBytes);
  }

  static Future<({Uint8List data, int? expectedBytes})>
  _downloadRawBytesWithIoClient({
    required String requestUrl,
    required String method,
    required Map<String, dynamic> headers,
    required dynamic data,
    CancelToken? cancelToken,
    String? debugLabel,
    void Function(int current, int? total)? onProgress,
    required _DownloadResumeState state,
  }) async {
    var attempts = 0;

    while (attempts < _ioMaxAttempts) {
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
        final resumeOffset = _canResume(method) ? state.downloadedBytes : 0;
        if (resumeOffset > 0) {
          request.headers.set('Range', 'bytes=$resumeOffset-');
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
        final rangeAccepted = resumeOffset == 0 || response.statusCode == 206;
        if (!rangeAccepted) {
          Log.warning(
            'ImageDownloader',
            'HttpClient Range ignored: offset=$resumeOffset '
                'status=${response.statusCode} url=$requestUrl',
          );
          state.resetDownloadedBytes();
        }
        final effectiveOffset = rangeAccepted ? resumeOffset : 0;
        state.expectedBytes = _expectedBytesFromResponse(
          statusCode: response.statusCode,
          contentRange: response.headers.value('content-range'),
          contentLength: response.contentLength,
          resumeOffset: effectiveOffset,
          fallback: state.expectedBytes,
        );
        return await _readByteStream(
          response,
          state: state,
          cancelToken: cancelToken,
          onProgress: onProgress,
        );
      } catch (e) {
        if (state.isComplete) {
          return (data: state.takeBytes(), expectedBytes: state.expectedBytes);
        }
        if (!_isResumableDownloadError(e) || attempts >= _ioMaxAttempts) rethrow;
        Log.warning(
          'ImageDownloader',
          'HttpClient resume attempt $attempts failed '
              'label=${debugLabel ?? 'unknown'}; '
              'downloaded=${state.downloadedBytes} '
              'expected=${state.expectedBytes}; $e',
        );
      } finally {
        client.close(force: true);
      }
    }
    return (data: state.takeBytes(), expectedBytes: state.expectedBytes);
  }

  static Future<({Uint8List data, int? expectedBytes})> _readByteStream(
    Stream<List<int>> stream, {
    required _DownloadResumeState state,
    CancelToken? cancelToken,
    void Function(int current, int? total)? onProgress,
  }) async {
    var lastProgressTime = DateTime.fromMillisecondsSinceEpoch(0);
    const progressIntervalMs = 100;
    await for (final chunk in stream) {
      if (cancelToken?.isCancelled == true) throw Exception('Cancelled');
      state.add(chunk);
      final loaded = state.downloadedBytes;
      final now = DateTime.now();
      if (now.difference(lastProgressTime).inMilliseconds >=
          progressIntervalMs) {
        lastProgressTime = now;
        onProgress?.call(loaded, state.expectedBytes);
      }
    }
    onProgress?.call(state.downloadedBytes, state.expectedBytes);
    return (data: state.takeBytes(), expectedBytes: state.expectedBytes);
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

  static bool _canResume(String method) => method.toUpperCase() == 'GET';

  static int? _expectedBytesFromResponse({
    required int? statusCode,
    required String? contentRange,
    required int contentLength,
    required int resumeOffset,
    required int? fallback,
  }) {
    if (statusCode == 206) {
      return _contentRangeTotal(contentRange) ??
          (contentLength >= 0 ? resumeOffset + contentLength : fallback);
    }
    return _normalizeContentLength(contentLength) ?? fallback;
  }

  static int? _contentRangeTotal(String? value) {
    if (value == null) return null;
    final slash = value.lastIndexOf('/');
    if (slash < 0 || slash == value.length - 1) return null;
    return int.tryParse(value.substring(slash + 1));
  }

  static int? _contentRangeStart(String? value) {
    if (value == null) return null;
    final space = value.indexOf(' ');
    final dash = value.indexOf('-');
    if (space < 0 || dash <= space + 1) return null;
    return int.tryParse(value.substring(space + 1, dash));
  }

  static bool _shouldFallbackToIoClient(
    Object error, {
    required bool preferLoadFailedOnRangeIgnored,
  }) {
    if (_isCancelledDownloadError(error)) return false;
    if (error is _RangeNotSupportedException) {
      return !preferLoadFailedOnRangeIgnored;
    }
    return _isResumableDownloadError(error);
  }

  static bool _isResumableDownloadError(Object error) {
    if (_isCancelledDownloadError(error)) return false;
    if (error is DioException) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.connectionError ||
        DioExceptionType.unknown => true,
        _ => false,
      };
    }
    final text = error.toString();
    return text.contains('Connection closed while receiving data') ||
        text.contains('Connection reset by peer') ||
        text.contains('HttpException') ||
        text.contains('receive timeout') ||
        text.contains('Receive Timeout') ||
        text.contains('Connection Timeout') ||
        text.contains('RhttpUnknownException') ||
        text.contains('error decoding response body');
  }

  static bool _isCancelledDownloadError(Object error) {
    if (error is DioException) {
      return error.type == DioExceptionType.cancel;
    }
    return error.toString().contains('Cancelled');
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
