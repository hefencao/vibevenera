import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/image_provider/io/webp_download_artifact.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';

import 'app_dio.dart';
import 'images.dart';

final class WebPTransportProgress {
  final int committedBytes;
  final int? expectedBytes;

  const WebPTransportProgress(this.committedBytes, this.expectedBytes);
}

final class WebPDirectTransportUnsupported implements Exception {
  final String reason;
  const WebPDirectTransportUnsupported(this.reason);

  @override
  String toString() => 'WebP direct transport unsupported: $reason';
}

abstract interface class WebPTransport {
  Future<File> execute(
    DownloadSession session, {
    CancelToken? cancelToken,
    void Function(WebPTransportProgress progress)? onProgress,
  });
}

final class WebPDownloadTransport implements WebPTransport {
  final DownloadIdentity identity;
  final WebPDownloadArtifact artifact;

  WebPDownloadTransport({
    required this.identity,
    required this.artifact,
  });

  factory WebPDownloadTransport.forIdentity(DownloadIdentity identity) =>
      WebPDownloadTransport(
        identity: identity,
        artifact: WebPDownloadArtifact.forCacheKey(_cacheKey(identity)),
      );

  @override
  Future<File> execute(
    DownloadSession session, {
    CancelToken? cancelToken,
    void Function(WebPTransportProgress progress)? onProgress,
  }) async {
    if (session.identity != identity) {
      throw StateError('Download transport identity mismatch');
    }
    session.markQueued();
    try {
      final cached = await CacheManager().findCache(_cacheKey(identity));
      if (cached != null) {
        await artifact.discard();
        await _appendFile(session, cached, onProgress);
        session.seal();
        return cached;
      }

      var config = await _resolveConfig();
      _requireDirect(config);
      await artifact.restore(session);
      onProgress?.call(_progress(session));
      var sourceChanges = 0;
      while (true) {
        Object? lastError;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await _request(
              session,
              config,
              cancelToken: cancelToken,
              onProgress: onProgress,
            );
            await artifact.flush();
            session.seal();
            return artifact.promote(
              sealedLength: session.source.state.committedLength,
            );
          } catch (error) {
            if (_isCancelled(error, cancelToken)) {
              session.markPaused();
              await artifact.close();
              rethrow;
            }
            lastError = error;
            if (session.source.state.failed) break;
          }
        }
        final next = await _nextConfig(config);
        if (next == null || ++sourceChanges > 5) {
          session.markFailed(lastError!);
          await artifact.close();
          throw lastError;
        }
        config = next;
        _requireDirect(config);
        await artifact.reset();
        session.resetSource(epoch: session.source.epoch + 1);
        onProgress?.call(_progress(session));
      }
    } catch (error) {
      if (session.transport != DownloadTransportState.paused &&
          session.transport != DownloadTransportState.failed) {
        session.markFailed(error);
      }
      rethrow;
    }
  }

  Future<void> _request(
    DownloadSession session,
    ImageRequestConfig config, {
    CancelToken? cancelToken,
    void Function(WebPTransportProgress progress)? onProgress,
  }) async {
    if (cancelToken?.isCancelled == true) throw StateError('Cancelled');
    final offset = session.source.state.committedLength;
    final headers = Map<String, dynamic>.from(config.headers);
    if (!headers.keys.any((key) => key.toLowerCase() == 'accept-encoding')) {
      headers['Accept-Encoding'] = 'identity';
    }
    if (offset > 0) headers['Range'] = 'bytes=$offset-';
    final url = config.url.startsWith('//') ? 'https:${config.url}' : config.url;
    final dio = AppDio(BaseOptions(
      headers: headers,
      method: config.method,
      responseType: ResponseType.stream,
      extra: const {'disableReceiveTimeout': true},
    ));
    final response = await dio.request<ResponseBody>(
      url,
      data: config.data,
      cancelToken: cancelToken,
    );
    final status = response.statusCode ?? 0;
    if (status >= 400) throw StateError('Invalid status code: $status');
    final body = response.data ?? (throw StateError('Empty response body'));
    if (offset > 0 && status != 206) {
      await body.stream.listen(null).cancel();
      await artifact.reset();
      session.resetSource(epoch: session.source.epoch + 1);
      throw StateError('Range request rejected at $offset');
    }
    final contentRange = response.headers.value('content-range');
    final rangeStart = _contentRangeStart(contentRange);
    if (status == 206 && rangeStart != offset) {
      await body.stream.listen(null).cancel();
      throw StateError('Invalid Content-Range start: $rangeStart/$offset');
    }
    final expected = _expectedLength(
      status,
      contentRange,
      body.contentLength,
      offset,
    );
    session.markReceiving();
    var committed = offset;
    await for (final chunk in body.stream) {
      if (cancelToken?.isCancelled == true) throw StateError('Cancelled');
      session.append(chunk, offset: committed);
      await artifact.append(chunk, offset: committed);
      committed += chunk.length;
      onProgress?.call(WebPTransportProgress(committed, expected));
    }
    final source = session.source.state;
    final requiredLength = source.declaredLength > 0
        ? source.declaredLength
        : expected;
    if (requiredLength != null && committed < requiredLength) {
      throw HttpException(
        'Connection closed while receiving WebP: $committed/$requiredLength',
      );
    }
  }

  Future<void> _appendFile(
    DownloadSession session,
    File file,
    void Function(WebPTransportProgress progress)? onProgress,
  ) async {
    final length = await file.length();
    var committed = session.source.state.committedLength;
    if (committed > length) {
      throw StateError('Cached WebP is behind source: $length/$committed');
    }
    await for (final chunk in file.openRead(committed)) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      session.append(bytes, offset: committed);
      committed += bytes.length;
      onProgress?.call(WebPTransportProgress(committed, length));
    }
  }

  Future<ImageRequestConfig> _resolveConfig() async {
    Map<String, dynamic>? raw;
    final sourceKey = identity.sourceKey;
    if (sourceKey != null) {
      raw = (await ComicSource.find(sourceKey)?.getImageLoadingConfig?.call(
        identity.imageKey,
        identity.cid,
        identity.eid,
      )) ?? <String, dynamic>{};
    }
    return ImageRequestConfig.fromMap(identity.imageKey, raw);
  }

  Future<ImageRequestConfig?> _nextConfig(ImageRequestConfig current) async {
    final callback = current.onLoadFailed;
    if (callback == null) return null;
    dynamic result = callback([]);
    callback.free();
    if (result is Future) result = await result;
    if (result is! Map<String, dynamic>) return null;
    return ImageRequestConfig.fromMap(current.url, result);
  }

  static void _requireDirect(ImageRequestConfig config) {
    if (config.onResponse != null || config.modifyImage != null) {
      throw const WebPDirectTransportUnsupported('response transformation');
    }
    if (config.method.toUpperCase() != 'GET') {
      throw WebPDirectTransportUnsupported('method ${config.method}');
    }
  }

  static WebPTransportProgress _progress(DownloadSession session) {
    final state = session.source.state;
    final expected = state.declaredLength > 0
        ? state.declaredLength
        : state.expectedLength > 0
            ? state.expectedLength
            : null;
    return WebPTransportProgress(state.committedLength, expected);
  }

  static int? _expectedLength(
    int status,
    String? contentRange,
    int contentLength,
    int offset,
  ) {
    if (status == 206) {
      final slash = contentRange?.lastIndexOf('/') ?? -1;
      if (slash >= 0) return int.tryParse(contentRange!.substring(slash + 1));
      return contentLength >= 0 ? offset + contentLength : null;
    }
    return contentLength >= 0 ? contentLength : null;
  }

  static int? _contentRangeStart(String? value) {
    if (value == null) return null;
    final space = value.indexOf(' ');
    final dash = value.indexOf('-');
    if (space < 0 || dash <= space + 1) return null;
    return int.tryParse(value.substring(space + 1, dash));
  }

  static bool _isCancelled(Object error, CancelToken? token) =>
      token?.isCancelled == true ||
      error is DioException && error.type == DioExceptionType.cancel;

  static String _cacheKey(DownloadIdentity identity) =>
      '${identity.imageKey}@${identity.sourceKey}@${identity.cid}@${identity.eid}';
}
