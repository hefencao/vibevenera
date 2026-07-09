import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
  _SharedStream(this._source, this._onDispose, this._cancelToken)
    : _controller = StreamController<ImageDownloadProgress>.broadcast();

  final Stream<ImageDownloadProgress> _source;
  final void Function() _onDispose;
  final CancelToken _cancelToken;
  final StreamController<ImageDownloadProgress> _controller;
  final List<ImageDownloadProgress> _history = [];
  StreamSubscription<ImageDownloadProgress>? _upstreamSub;
  int _listeners = 0;
  bool _disposed = false;

  Stream<ImageDownloadProgress> get stream async* {
    _listeners++;
    _ensureStarted();
    try {
      var replayed = 0;
      for (final event in _coalescedHistory()) {
        yield event;
        replayed++;
        if (replayed % 8 == 0) await Future<void>.delayed(Duration.zero);
      }
      yield* _controller.stream;
    } finally {
      _listeners--;
      if (_listeners <= 0 && !_disposed) {
        cancel();
      }
    }
  }

  void _ensureStarted() {
    _upstreamSub ??= _source.listen(
      (event) {
        if (event.reset) {
          _history
            ..clear()
            ..add(event);
        } else if (event.chunkBytes != null || event.imageBytes != null) {
          _history.add(event);
        }
        _controller.add(event);
      },
      onError: _controller.addError,
      onDone: _close,
    );
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
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('Shared download disposed');
    }
    _upstreamSub?.cancel();
    _upstreamSub = null;
    if (!_controller.isClosed) {
      _controller.close();
    }
    _onDispose();
  }

  List<ImageDownloadProgress> _coalescedHistory() {
    const maxReplayChunk = 256 * 1024;
    final result = <ImageDownloadProgress>[];
    var builder = BytesBuilder(copy: false);
    var current = 0;
    int? total;

    void flush() {
      if (builder.length == 0) return;
      result.add(
        ImageDownloadProgress(
          currentBytes: current,
          totalBytes: total,
          chunkBytes: builder.takeBytes(),
        ),
      );
      builder = BytesBuilder(copy: false);
    }

    for (final event in _history) {
      if (event.reset) {
        flush();
        result.add(event);
        continue;
      }
      final chunk = event.chunkBytes;
      if (chunk != null) {
        builder.add(chunk);
        current = event.currentBytes;
        total = event.totalBytes;
        if (builder.length >= maxReplayChunk) flush();
        continue;
      }
      flush();
      if (event.imageBytes != null) result.add(event);
    }
    flush();
    return result;
  }
}

class _DownloadResumeState {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int _baseBytes = 0;
  int? expectedBytes;
  final _PartialImageCache? partialCache;
  final String? debugLabel;
  bool hasReplayedPartial = false;
  List<Uint8List>? _replayChunks;
  bool _checkedDeclaredBytes = false;
  int _pendingPartialBytes = 0;
  static const _partialFlushBytes = 1024 * 1024;

  _DownloadResumeState([this.partialCache, this.debugLabel]);

  int get downloadedBytes =>
      partialCache?.memoryLength ?? _baseBytes + _buffer.length;

  bool get isComplete =>
      expectedBytes != null && downloadedBytes >= expectedBytes!;

  Future<void> initFromPartial() async {
    final chunks = await partialCache?.readChunks();
    if (chunks == null || chunks.isEmpty) return;
    var len = 0;
    for (final chunk in chunks) {
      len += chunk.length;
    }
    _baseBytes = len;
    _replayChunks = chunks;
    setExpectedBytes(partialCache?.memoryExpectedBytes);
    setExpectedBytes(_declaredWebPBytesFromChunks(chunks));
    _checkedDeclaredBytes = downloadedBytes >= 12;
  }

  void setExpectedBytes(int? value) {
    expectedBytes = ImageDownloader._maxExpected(expectedBytes, value);
    partialCache?.setExpected(expectedBytes);
  }

  int? _declaredWebPBytesFromChunks(List<Uint8List> chunks) {
    if (downloadedBytes < 12) return null;
    final header = Uint8List(12);
    var copied = 0;
    for (final chunk in chunks) {
      final n = math.min(12 - copied, chunk.length);
      header.setRange(copied, copied + n, chunk);
      copied += n;
      if (copied >= 12) break;
    }
    return ImageDownloader._declaredWebPBytes(header);
  }

  Future<void> replayPartial({
    int fromBytes = 0,
    void Function(int current, int? total)? onProgress,
    void Function(int current, int? total, List<int> chunk)? onChunk,
  }) async {
    if (hasReplayedPartial || downloadedBytes <= fromBytes) return;
    hasReplayedPartial = true;
    final chunks = _replayChunks;
    const chunkSize = 256 * 1024;
    if (chunks != null) {
      var builder = BytesBuilder(copy: false);
      var current = fromBytes;
      var emitted = 0;
      Future<void> flush() async {
        if (builder.length == 0) return;
        emitted++;
        onChunk?.call(current, expectedBytes, builder.takeBytes());
        builder = BytesBuilder(copy: false);
        if (emitted == 1 || current == downloadedBytes) {
          onProgress?.call(current, expectedBytes);
        }
        if (emitted <= 4 || emitted % 4 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      var offset = 0;
      for (final chunk in chunks) {
        final end = offset + chunk.length;
        if (end <= fromBytes) {
          offset = end;
          continue;
        }
        final start = math.max(0, fromBytes - offset);
        final data = start == 0 ? chunk : Uint8List.sublistView(chunk, start);
        builder.add(data);
        current += data.length;
        offset = end;
        if (builder.length >= chunkSize) await flush();
      }
      await flush();
      return;
    }
    final bytes = _buffer.toBytes();
    for (var offset = fromBytes; offset < bytes.length; offset += chunkSize) {
      final end = math.min(offset + chunkSize, bytes.length);
      onChunk?.call(end, expectedBytes, Uint8List.sublistView(bytes, offset, end));
      if (offset == 0 || end == bytes.length) onProgress?.call(end, expectedBytes);
      if (offset <= chunkSize * 4 || offset % (chunkSize * 4) == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  Future<void> add(List<int> chunk) async {
    final cache = partialCache;
    if (chunk.isEmpty) return;
    if (cache == null) {
      _buffer.add(chunk);
      if (_baseBytes == 0 && !_checkedDeclaredBytes && _buffer.length >= 12) {
        _checkedDeclaredBytes = true;
        setExpectedBytes(ImageDownloader._declaredWebPBytes(_buffer.toBytes()));
      }
      return;
    }
    await cache.append(chunk);
    if (!_checkedDeclaredBytes && downloadedBytes >= 12) {
      _checkedDeclaredBytes = true;
      setExpectedBytes(_declaredWebPBytesFromChunks(cache._mem.chunks));
    }
    _pendingPartialBytes += chunk.length;
    if (_pendingPartialBytes >= _partialFlushBytes) await flushPartial();
  }

  Future<void> flushPartial() async {
    _pendingPartialBytes = 0;
    await partialCache?.flush();
  }

  Future<void> closePartial() async {
    _pendingPartialBytes = 0;
    await partialCache?.close();
  }

  Future<Uint8List> takeBytes() async {
    if (partialCache != null) {
      await closePartial();
      final bytes = await partialCache?.read();
      if (bytes != null && bytes.length >= downloadedBytes) {
        return bytes.length == downloadedBytes
            ? bytes
            : Uint8List.sublistView(bytes, 0, downloadedBytes);
      }
      throw io.HttpException(
        'Partial cache missing while assembling resumed body: '
        '${bytes?.length ?? 0}/$downloadedBytes',
      );
    }
    return _buffer.takeBytes();
  }
}

class _PartialImageCache {
  static final Map<String, _PartialImageMemory> _memory = {};

  _PartialImageCache(String cacheKey)
      : file = io.File(
          '${CacheManager.cachePath}_partial/${md5.convert(cacheKey.codeUnits)}',
        ),
        _memoryKey = cacheKey;

  final io.File file;
  final String _memoryKey;
  io.IOSink? _sink;
  bool _dirReady = false;
  _PartialImageMemory get _mem =>
      _memory.putIfAbsent(_memoryKey, _PartialImageMemory.new);
  int get memoryLength => _memory[_memoryKey]?.length ?? 0;

  Future<Uint8List?> read() async {
    final chunks = await readChunks();
    if (chunks == null || chunks.isEmpty) return null;
    if (chunks.length == 1) return chunks.first;
    final builder = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<List<Uint8List>?> readChunks() async {
    final mem = _mem;
    if (mem.length > 0) return mem.snapshot();
    if (!await file.exists()) return null;
    final len = await file.length();
    if (len <= 0) return null;
    final bytes = await file.readAsBytes();
    mem.reset();
    mem.add(bytes);
    return [bytes];
  }

  int? get memoryExpectedBytes => _mem.expectedBytes;

  void setExpected(int? expected) {
    if (expected != null) _mem.expectedBytes = expected;
  }

  Future<int> length() async {
    final memLen = _mem.length;
    if (memLen > 0) return memLen;
    return await file.exists() ? await file.length() : 0;
  }

  Future<void> append(List<int> chunk) async {
    if (chunk.isEmpty) return;
    _mem.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    if (!_dirReady) {
      await file.parent.create(recursive: true);
      _dirReady = true;
    }
    (_sink ??= file.openWrite(mode: io.FileMode.append)).add(chunk);
  }

  Future<void> flush() async {
    await _sink?.flush();
  }

  Future<void> close() async {
    final sink = _sink;
    if (sink == null) return;
    _sink = null;
    await sink.close();
  }

  Future<void> clear() async {
    await close();
    _memory.remove(_memoryKey);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class _PartialImageMemory {
  final chunks = <Uint8List>[];
  int length = 0;
  int? expectedBytes;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    chunks.add(chunk);
    length += chunk.length;
  }

  List<Uint8List> snapshot() => List<Uint8List>.unmodifiable(chunks);

  void reset() {
    chunks.clear();
    length = 0;
    expectedBytes = null;
  }
}

class _IncompleteWebPException implements Exception {
  _IncompleteWebPException(this.actual, this.expected);
  final int actual;
  final int expected;

  @override
  String toString() => 'Incomplete WebP body: $actual/$expected bytes';
}

// ═══════════════════════════════════════════════════════════════
// ImageDownloader
// ═══════════════════════════════════════════════════════════════

abstract class ImageDownloader {
  static final Map<String, _SharedStream> _loadingImages = {};
  static const _rhttpMaxAttempts = 3;
  static const _ioMaxAttempts = 3;

  static Uint8List _joinBytes(Iterable<Uint8List> chunks) {
    final builder = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

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

  static bool isIncompleteWebPBytes(List<int> data) {
    final declared = _declaredWebPBytes(data);
    return declared != null && data.length < declared;
  }

  static int? _declaredWebPBytes(List<int> data) {
    if (data.length < 12) return null;
    if (data[0] != 0x52 || data[1] != 0x49 || data[2] != 0x46 ||
        data[3] != 0x46 || data[8] != 0x57 || data[9] != 0x45 ||
        data[10] != 0x42 || data[11] != 0x50) {
      return null;
    }
    final payload = data[4] |
        (data[5] << 8) |
        (data[6] << 16) |
        (data[7] << 24);
    return payload + 8;
  }

  static void _validateCompleteImageBytes(List<int> data) {
    final declared = _declaredWebPBytes(data);
    if (declared != null && data.length < declared) {
      throw _IncompleteWebPException(data.length, declared);
    }
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
    int? resumeFromBytes,
    int? resumeExpectedBytes,
    bool replayPartial = true,
  }) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final joined = joinLoadingComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      debugLabel: debugLabel,
    );
    if (joined != null) return joined;

    final requestCancel = CancelToken();
    final shared = _SharedStream(
      _loadComicImage(
        imageKey,
        sourceKey,
        cid,
        eid,
        cancelToken: requestCancel,
        debugLabel: debugLabel,
        resumeFromBytes: resumeFromBytes,
        resumeExpectedBytes: resumeExpectedBytes,
        replayPartial: replayPartial,
      ),
      () => _loadingImages.remove(cacheKey),
      requestCancel,
    );
    _loadingImages[cacheKey] = shared;
    return shared.stream;
  }

  static Stream<ImageDownloadProgress>? joinLoadingComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    String? debugLabel,
  }) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final existing = _loadingImages[cacheKey];
    if (existing == null) return null;
    return existing.stream;
  }

  static bool isLoadingComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    return _loadingImages.containsKey(cacheKey);
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
    int? resumeFromBytes,
    int? resumeExpectedBytes,
    bool replayPartial = true,
  }) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    _throwIfCancelled(cancelToken);

    // Cache hit → yield immediately
    final cached = await CacheManager().findCache(cacheKey);
    _throwIfCancelled(cancelToken);
    if (cached != null) {
      final data = await cached.readAsBytes();
      _throwIfCancelled(cancelToken);
      if (isIncompleteWebPBytes(data)) {
        await CacheManager().delete(cacheKey);
      } else {
        unawaited(_PartialImageCache(cacheKey).clear());
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      }
    }

    Map<String, dynamic>? rawConfig;
    if (sourceKey != null) {
      final cs = ComicSource.find(sourceKey);
      rawConfig =
          (await cs?.getImageLoadingConfig?.call(imageKey, cid, eid)) ?? {};
    }
    _throwIfCancelled(cancelToken);

    var config = ImageRequestConfig.fromMap(imageKey, rawConfig);
    var retry = 5;
    var sameUrlRetry = 1;
    var shouldReplayPartial = replayPartial;
    var resumeOffset = resumeFromBytes;
    var resumeExpected = resumeExpectedBytes;

    while (true) {
      try {
        _throwIfCancelled(cancelToken);
        await for (final event in _executeDownload(
          config: config,
          cacheKey: cacheKey,
          enableModifyImage: true,
          cancelToken: cancelToken,
          debugLabel: debugLabel,
          replayPartial: shouldReplayPartial,
          resumeFromBytes: resumeOffset,
          resumeExpectedBytes: resumeExpected,
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
        if (sameUrlRetry > 0 && _isSameUrlRetryable(e)) {
          sameUrlRetry--;
          shouldReplayPartial = false;
          resumeOffset = null;
          resumeExpected = null;
          _warnDownload(
            debugLabel,
            'RETRY sameUrl left=$sameUrlRetry url=${_shortDownloadKey(config.url)}',
          );
          continue;
        }
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
          _throwIfCancelled(cancelToken);
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
          if (!sameUrl) {
            shouldReplayPartial = false;
            resumeOffset = null;
            resumeExpected = null;
            break;
          }
        }
      }
    }
  }

  static void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled == true) throw Exception('Cancelled');
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
    bool replayPartial = true,
    int? resumeFromBytes,
    int? resumeExpectedBytes,
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
    final canStreamDecode = config.modifyImage == null && config.onResponse == null;
    var streamChunkCount = 0;
    var pendingChunks = <Uint8List>[];
    var pendingLength = 0;
    var pendingCurrent = 0;
    int? pendingTotal;

    final progressEvents = StreamController<ImageDownloadProgress>();
    void flushPendingChunk() {
      if (pendingLength == 0 || progressEvents.isClosed) return;
      final chunk = pendingChunks.length == 1
          ? pendingChunks.first
          : _joinBytes(pendingChunks);
      pendingChunks = <Uint8List>[];
      pendingLength = 0;
      streamChunkCount++;
      progressEvents.add(
        ImageDownloadProgress(
          currentBytes: pendingCurrent,
          totalBytes: pendingTotal,
          chunkBytes: chunk,
        ),
      );
    }

    final rawFuture = (() async {
      try {
        return await _downloadRawBytes(
          requestUrl: requestUrl,
          cacheKey: cacheKey,
          method: config.method,
          headers: headers,
          data: config.data,
          cancelToken: cancelToken,
          debugLabel: debugLabel,
          replayPartial: replayPartial,
          resumeFromBytes: resumeFromBytes,
          resumeExpectedBytes: resumeExpectedBytes,
          onProgress: (current, total) {
            if (!progressEvents.isClosed) {
              progressEvents.add(
                ImageDownloadProgress(currentBytes: current, totalBytes: total),
              );
            }
          },
          onChunk: (current, total, chunk) {
            if (!canStreamDecode) return;
            final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
            pendingChunks.add(data);
            pendingLength += data.length;
            pendingCurrent = current;
            pendingTotal = total;
            final threshold = streamChunkCount == 0 ? 64 * 1024 : 256 * 1024;
            if (pendingLength >= threshold) flushPendingChunk();
          },
        );
      } finally {
        flushPendingChunk();
        await progressEvents.close();
      }
    })();

    await for (final event in progressEvents.stream) {
      yield event;
    }
    final raw = await rawFuture;
    final Uint8List data = raw.data;
    final declared = _declaredWebPBytes(data);
    if (declared != null && data.length < declared) {
      throw io.HttpException(
        'Connection closed while receiving data: ${data.length}/$declared',
      );
    }
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
    required String cacheKey,
    required String method,
    required Map<String, dynamic> headers,
    required dynamic data,
    CancelToken? cancelToken,
    String? debugLabel,
    required bool replayPartial,
    int? resumeFromBytes,
    int? resumeExpectedBytes,
    void Function(int current, int? total)? onProgress,
    void Function(int current, int? total, List<int> chunk)? onChunk,
  }) async {
    final state = _DownloadResumeState(
      _PartialImageCache(cacheKey),
      debugLabel,
    );
    await state.initFromPartial();
    state.setExpectedBytes(resumeExpectedBytes);
    if (replayPartial) {
      await state.replayPartial(onProgress: onProgress, onChunk: onChunk);
    } else if (resumeFromBytes != null) {
      if (state.downloadedBytes < resumeFromBytes) {
        Log.warning(
          'WebP.Stream.Partial',
          'miss ${debugLabel ?? ''} '
              'cache=${state.downloadedBytes} holder=$resumeFromBytes',
        );
      } else if (state.downloadedBytes > resumeFromBytes) {
        await state.replayPartial(
          fromBytes: resumeFromBytes,
          onProgress: onProgress,
          onChunk: onChunk,
        );
      } else {
        onProgress?.call(state.downloadedBytes, state.expectedBytes);
      }
    } else {
      onProgress?.call(state.downloadedBytes, state.expectedBytes);
    }
    if (state.isComplete) {
      await state.closePartial();
      return (data: await state.takeBytes(), expectedBytes: state.expectedBytes);
    }
    try {
      return await _downloadRawBytesWithRhttp(
        requestUrl: requestUrl,
        method: method,
        headers: headers,
        data: data,
        cancelToken: cancelToken,
        debugLabel: debugLabel,
        onProgress: onProgress,
        onChunk: onChunk,
        state: state,
      );
    } catch (e) {
      if (!_isResumableDownloadError(e)) rethrow;
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
        onChunk: onChunk,
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
    void Function(int current, int? total, List<int> chunk)? onChunk,
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
                'status=$statusCode skip-prefix url=$requestUrl',
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
          skipPrefixBytes: rangeAccepted ? 0 : resumeOffset,
          onProgress: onProgress,
          onChunk: onChunk,
        );
      } catch (e) {
        if (state.isComplete) {
          return (data: await state.takeBytes(), expectedBytes: state.expectedBytes);
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
    return (data: await state.takeBytes(), expectedBytes: state.expectedBytes);
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
    void Function(int current, int? total, List<int> chunk)? onChunk,
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
                'status=${response.statusCode} skip-prefix url=$requestUrl',
          );
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
          skipPrefixBytes: rangeAccepted ? 0 : resumeOffset,
          onProgress: onProgress,
          onChunk: onChunk,
        );
      } catch (e) {
        if (state.isComplete) {
          return (data: await state.takeBytes(), expectedBytes: state.expectedBytes);
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
    return (data: await state.takeBytes(), expectedBytes: state.expectedBytes);
  }

  static Future<({Uint8List data, int? expectedBytes})> _readByteStream(
    Stream<List<int>> stream, {
    required _DownloadResumeState state,
    CancelToken? cancelToken,
    int skipPrefixBytes = 0,
    void Function(int current, int? total)? onProgress,
    void Function(int current, int? total, List<int> chunk)? onChunk,
  }) async {
    var lastProgressTime = DateTime.fromMillisecondsSinceEpoch(0);
    var skip = skipPrefixBytes;
    const progressIntervalMs = 100;
    try {
      await for (final chunk in stream) {
        if (cancelToken?.isCancelled == true) throw Exception('Cancelled');
        Uint8List data;
        if (skip > 0) {
          if (chunk.length <= skip) {
            skip -= chunk.length;
            onProgress?.call(state.downloadedBytes, state.expectedBytes);
            continue;
          }
          final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          data = Uint8List.sublistView(bytes, skip);
          skip = 0;
        } else {
          data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        }
        await state.add(data);
        final loaded = state.downloadedBytes;
        onChunk?.call(loaded, state.expectedBytes, data);
        final now = DateTime.now();
        if (now.difference(lastProgressTime).inMilliseconds >=
            progressIntervalMs) {
          lastProgressTime = now;
          onProgress?.call(loaded, state.expectedBytes);
        }
      }
    } finally {
      await state.closePartial();
    }
    if (state.expectedBytes != null &&
        state.downloadedBytes < state.expectedBytes!) {
      throw io.HttpException(
        'Connection closed while receiving data: '
        '${state.downloadedBytes}/${state.expectedBytes}',
      );
    }
    onProgress?.call(state.downloadedBytes, state.expectedBytes);
    return (data: await state.takeBytes(), expectedBytes: state.expectedBytes);
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
        _validateCompleteImageBytes(transformed);
        config.onResponse!.free();
        _writeCacheInBackground(cacheKey, transformed);
        await _PartialImageCache(cacheKey).clear();
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
      _validateCompleteImageBytes(data);
      finalData = await modifyImageWithScript(data, config.modifyImage);
    }

    _validateCompleteImageBytes(finalData);
    _writeCacheInBackground(cacheKey, finalData);
    await _PartialImageCache(cacheKey).clear();

    // Yield final complete event with image bytes
    yield ImageDownloadProgress(
      currentBytes: finalData.length,
      totalBytes: finalData.length,
      imageBytes: finalData,
    );
  }

  static void _writeCacheInBackground(String cacheKey, List<int> data) {
    unawaited(
      CacheManager().writeCache(cacheKey, data).catchError((e, s) {
        Log.warning('ImageDownloader', 'Cache write failed: $cacheKey; $e');
      }),
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
      final total = _contentRangeTotal(contentRange) ??
          (contentLength >= 0 ? resumeOffset + contentLength : null);
      return _maxExpected(total, fallback);
    }
    return _maxExpected(_normalizeContentLength(contentLength), fallback);
  }

  static int? _maxExpected(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
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

  static bool _isSameUrlRetryable(Object error) =>
      error is _IncompleteWebPException ||
      (error is io.HttpException &&
          error.message.contains('Connection closed while receiving data'));

  static bool _isResumableDownloadError(Object error) {
    if (_isCancelledDownloadError(error)) return false;
    if (error is _IncompleteWebPException) return true;
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
  final Uint8List? chunkBytes;
  final bool reset;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
    this.chunkBytes,
    this.reset = false,
  });
}
