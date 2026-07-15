import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/network/images.dart';
import 'package:venera/network/webp_download_artifact.dart';

final class WebPTransportProgress {
  final int currentBytes;
  final int? totalBytes;
  final bool done;

  const WebPTransportProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.done = false,
  });
}

final class WebPTransportCancelled implements Exception {
  final Object? reason;

  const WebPTransportCancelled([this.reason]);

  @override
  String toString() =>
      'WebP transport cancelled${reason == null ? '' : ': $reason'}';
}

abstract interface class WebPTransport {
  Future<File> execute(
    DownloadSession session, {
    CancelToken? cancelToken,
    void Function(WebPTransportProgress progress)? onProgress,
  });
}

typedef WebPDownloadEventSource = Stream<ImageDownloadProgress> Function({
  required int resumeOffset,
  required int? expectedLength,
  CancelToken? cancelToken,
});

/// Adapter around the existing Dart image download stack.
///
/// This transport is the sole consumer of legacy [ImageDownloadProgress]
/// chunk events. Source offsets are derived only from the monotonic ingress
/// cursor; `currentBytes` remains progress metadata and is never used to infer
/// a chunk start offset.
final class ImageDownloaderWebPTransport implements WebPTransport {
  static const int _initialLocalReadSize = 1024 * 1024;
  static const int _localReadSize = 512 * 1024;

  final DownloadIdentity identity;
  final WebPDownloadArtifact Function(String cacheKey) artifactFactory;
  final WebPDownloadEventSource eventSource;

  ImageDownloaderWebPTransport(
    this.identity, {
    WebPDownloadArtifact Function(String cacheKey)? artifactFactory,
    WebPDownloadEventSource? eventSource,
  })  : artifactFactory =
            artifactFactory ?? WebPDownloadArtifact.forCacheKey,
        eventSource = eventSource ??
            (({
              required int resumeOffset,
              required int? expectedLength,
              CancelToken? cancelToken,
            }) {
              return ImageDownloader.loadComicImage(
                identity.imageKey,
                identity.sourceKey,
                identity.cid,
                identity.eid,
                cancelToken: cancelToken,
                debugLabel: 'webp-session:${identity.imageKey}',
                resumeFromBytes: resumeOffset > 0 ? resumeOffset : null,
                resumeExpectedBytes: expectedLength,
                replayPartial: false,
                streamOnly: true,
              );
            });

  @override
  Future<File> execute(
    DownloadSession session, {
    CancelToken? cancelToken,
    void Function(WebPTransportProgress progress)? onProgress,
  }) async {
    final artifact = artifactFactory(identity.cacheKey);
    var activeWriter = session.requireActiveWriter();
    StreamIterator<ImageDownloadProgress>? iterator;

    try {
      final restored = await artifact.restore(
        session,
        activeWriter,
        checkCancelled: () => _throwIfCancelled(cancelToken),
      );
      session.bindArtifact(activeWriter, artifact.file);
      if (restored.kind == WebPArtifactContentKind.webp) {
        session.identifyWebPContent(activeWriter);
      }
      Log.info(
        'WebP.Cache',
        'artifact ${restored.length == 0 ? 'empty' : 'restored'}: '
            'source=${identity.sourceKey} cid=${identity.cid} eid=${identity.eid} '
            'bytes=${restored.length} kind=${restored.kind.name} complete=${restored.complete}',
      );

      var ingress = _WebPIngress(
        session: session,
        writer: activeWriter,
        artifact: artifact,
        restored: restored,
      );

      _throwIfCancelled(cancelToken);

      final localFile = await _localFile();
      if (localFile != null) {
        return await _executeLocalFile(
          localFile,
          session: session,
          writer: activeWriter,
          ingress: ingress,
          artifact: artifact,
          cancelToken: cancelToken,
        );
      }

      final resumeOffset = restored.length;
      iterator = StreamIterator<ImageDownloadProgress>(
        eventSource(
          resumeOffset: resumeOffset,
          expectedLength: _sessionExpectedLength(session),
          cancelToken: cancelToken,
        ),
      );

      while (await _moveNext(iterator, cancelToken)) {
        _throwIfCancelled(cancelToken);
        final event = iterator.current;

        final cachedFile = event.cachedFile;
        if (cachedFile != null) {
          return await _executeCachedFile(
            cachedFile,
            session: session,
            writer: activeWriter,
            artifact: artifact,
            cancelToken: cancelToken,
          );
        }

        session.beginNetworkTransfer(activeWriter);

        if (event.reset) {
          await artifact.reset();
          activeWriter = session.resetSource(
            writer: activeWriter,
            epoch: session.source.epoch + 1,
            expectedLength: _positiveOrZero(event.totalBytes),
          );
          ingress = _WebPIngress.empty(
            session: session,
            writer: activeWriter,
            artifact: artifact,
          );
        } else {
          _updateExpectedLength(
            session,
            activeWriter,
            _normalizeReportedTotal(
              reportedTotal: event.totalBytes,
              currentLength: ingress.receivedLength,
              existingExpectedLength: session.expectedLength,
            ),
          );
        }

        final chunk = event.chunkBytes;
        if (chunk != null && chunk.isNotEmpty) {
          await ingress.append(chunk);
        }

        final finalBytes = event.imageBytes;
        if (finalBytes != null) {
          if (finalBytes.isEmpty && ingress.receivedLength == 0) {
            throw StateError(
              'Image stream completed with an empty final payload: '
              '${identity.imageKey}',
            );
          }

          // A one-shot legacy response is valid when no bytes have yet entered
          // the authoritative ingress. After streaming has started, finalBytes
          // may only confirm the exact final length; it must never repair a gap.
          if (ingress.receivedLength == 0) {
            await ingress.append(finalBytes);
          } else if (finalBytes.length != ingress.receivedLength) {
            throw WebPSourceInvariantError(
              'final payload cannot repair streaming input: final='
              '${finalBytes.length}, committed=${ingress.receivedLength}, '
              'epoch=${session.source.epoch}',
            );
          }

          return await _completeIngress(
            session: session,
            writer: activeWriter,
            ingress: ingress,
            artifact: artifact,
            finalLength: ingress.receivedLength,
            onProgress: onProgress,
          );
        }

        if (event.done) {
          // currentBytes is progress metadata. The ingress cursor is the only
          // authoritative final byte length.
          return await _completeIngress(
            session: session,
            writer: activeWriter,
            ingress: ingress,
            artifact: artifact,
            finalLength: ingress.receivedLength,
            onProgress: onProgress,
          );
        }

        if (chunk == null) {
          _publishProgress(
            onProgress,
            currentBytes: ingress.receivedLength,
            reportedTotal: event.totalBytes,
            session: session,
          );
        }
      }

      _throwIfCancelled(cancelToken);

      // Some stream implementations close after the final chunk without
      // emitting imageBytes or a separate done event. This is safe only when a
      // previously established authoritative expected length is reached.
      final expectedLength = _sessionExpectedLength(session);
      if (expectedLength != null &&
          ingress.receivedLength > 0 &&
          ingress.receivedLength == expectedLength) {
        return await _completeIngress(
          session: session,
          writer: activeWriter,
          ingress: ingress,
          artifact: artifact,
          finalLength: ingress.receivedLength,
          onProgress: onProgress,
        );
      }

      throw StateError(
        'WebP stream ended without a complete payload: '
        '${ingress.receivedLength}/${expectedLength ?? '?'} '
        'for ${identity.imageKey}',
      );
    } finally {
      await iterator?.cancel();
      await artifact.close();
    }
  }

  Future<File> _executeLocalFile(
    File localFile, {
    required DownloadSession session,
    required DownloadWriterLease writer,
    required _WebPIngress ingress,
    required WebPDownloadArtifact artifact,
    required CancelToken? cancelToken,
  }) async {
    var activeWriter = writer;
    var activeIngress = ingress;

    final localLength = await localFile.length();
    if (localLength <= 0) {
      throw StateError('Local image file is empty: ${identity.imageKey}');
    }

    if (activeIngress.receivedLength > localLength) {
      await artifact.reset();
      activeWriter = session.resetSource(
        writer: activeWriter,
        epoch: session.source.epoch + 1,
        expectedLength: localLength,
      );
      activeIngress = _WebPIngress.empty(
        session: session,
        writer: activeWriter,
        artifact: artifact,
      );
    } else {
      session.updateExpectedLength(
        localLength,
        writer: activeWriter,
      );
    }

    final reader = await localFile.open();
    try {
      // Keep the original file:// string untouched. File/IOOverrides resolves
      // the actual local or SAF-backed object.
      await reader.setPosition(activeIngress.receivedLength);

      while (activeIngress.receivedLength < localLength) {
        _throwIfCancelled(cancelToken);

        final remaining = localLength - activeIngress.receivedLength;
        final readSize = activeIngress.receivedLength == 0
            ? _initialLocalReadSize
            : _localReadSize;
        final chunk = await reader.read(
          remaining < readSize ? remaining : readSize,
        );

        if (chunk.isEmpty) {
          throw WebPSourceInvariantError(
            'local file ended at '
            '${activeIngress.receivedLength}/$localLength',
          );
        }

        await activeIngress.append(chunk);
      }
    } finally {
      await reader.close();
    }

    return _completeIngress(
      session: session,
      writer: activeWriter,
      ingress: activeIngress,
      artifact: artifact,
      finalLength: localLength,
      onProgress: null,
    );
  }

  Future<File> _executeCachedFile(
    File file, {
    required DownloadSession session,
    required DownloadWriterLease writer,
    required WebPDownloadArtifact artifact,
    required CancelToken? cancelToken,
  }) async {
    final length = await file.length();
    if (length <= 0) {
      throw StateError('Cached image file is empty: ${identity.imageKey}');
    }
    await artifact.reset();
    var activeWriter = session.resetSource(
      writer: writer,
      epoch: session.source.epoch + 1,
      expectedLength: length,
    );
    final reader = await file.open();
    try {
      final prefix = Uint8List.fromList(await reader.read(12));
      final kind = WebPDownloadArtifact.classifyPrefix(
        prefix,
        completeLength: length,
      );
      if (kind != WebPArtifactContentKind.webp) {
        session.enterFallbackContent(
          activeWriter,
          restoredLength: length,
          contentKind: kind == WebPArtifactContentKind.gif
              ? DownloadContentKind.gif
              : DownloadContentKind.fallback,
        );
        session.updateExpectedLength(length, writer: activeWriter);
        session.sealFallback(activeWriter, file, finalLength: length);
      } else {
        await reader.setPosition(0);
        var offset = 0;
        while (offset < length) {
          _throwIfCancelled(cancelToken);
          final readSize = offset == 0
              ? _initialLocalReadSize
              : _localReadSize;
          final chunk = await reader.read(
            length - offset < readSize ? length - offset : readSize,
          );
          if (chunk.isEmpty) {
            throw WebPSourceInvariantError(
              'cached file ended at $offset/$length',
            );
          }
          session.append(
            Uint8List.fromList(chunk),
            offset: offset,
            writer: activeWriter,
          );
          offset += chunk.length;
        }
        session.seal(activeWriter, file);
      }
    } finally {
      await reader.close();
    }
    Log.info(
      'WebP.Cache',
      'reuse: image=${identity.imageKey} source=${identity.sourceKey} '
          'cid=${identity.cid} eid=${identity.eid} bytes=$length',
    );
    return file;
  }

  Future<File> _completeIngress({
    required DownloadSession session,
    required DownloadWriterLease writer,
    required _WebPIngress ingress,
    required WebPDownloadArtifact artifact,
    required int finalLength,
    required void Function(WebPTransportProgress progress)? onProgress,
  }) async {
    if (finalLength <= 0) {
      throw StateError('Cannot seal an empty image: ${identity.imageKey}');
    }
    if (!writer.active) {
      throw const WebPTransportCancelled('stale writer before seal');
    }
    if (finalLength != ingress.receivedLength) {
      throw WebPSourceInvariantError(
        'seal length $finalLength does not match ingress '
        '${ingress.receivedLength}',
      );
    }

    await ingress.finalizeContent(finalLength: finalLength);
    session.updateExpectedLength(finalLength, writer: writer);
    await artifact.flush();

    if (!writer.active) {
      throw const WebPTransportCancelled('stale writer before promote');
    }

    final file = await artifact.promote(sealedLength: finalLength);
    Log.info(
      'WebP.Cache',
      'promoted: image=${identity.imageKey} source=${identity.sourceKey} '
          'cid=${identity.cid} eid=${identity.eid} bytes=$finalLength exists=${await file.exists()}',
    );

    if (ingress.isFallback) {
      session.sealFallback(
        writer,
        file,
        finalLength: finalLength,
      );
    } else {
      session.seal(writer, file);
    }

    onProgress?.call(
      WebPTransportProgress(
        currentBytes: finalLength,
        totalBytes: finalLength,
        done: true,
      ),
    );
    return file;
  }

  Future<bool> _moveNext(
    StreamIterator<ImageDownloadProgress> iterator,
    CancelToken? cancelToken,
  ) async {
    if (cancelToken == null) return iterator.moveNext();
    _throwIfCancelled(cancelToken);

    final result = await Future.any<bool>([
      iterator.moveNext(),
      cancelToken.whenCancel.then((_) => false),
    ]);

    _throwIfCancelled(cancelToken);
    return result;
  }

  void _throwIfCancelled(CancelToken? token) {
    if (token?.isCancelled == true) {
      throw const WebPTransportCancelled('cancelled');
    }
  }

  Future<File?> _localFile() async {
    final key = identity.imageKey;
    final explicitFileUri = key.startsWith('file://');

    if (!explicitFileUri && key.contains('://')) {
      return null;
    }

    // Do not strip or convert file://. The application's IOOverrides owns the
    // path mapping and may resolve it to SAF or another virtual file backend.
    final file = File(key);

    try {
      if (await file.exists()) return file;
    } on FileSystemException {
      if (explicitFileUri) rethrow;
      return null;
    }

    if (explicitFileUri) {
      throw FileSystemException(
        'Local image file does not exist',
        key,
      );
    }

    // A scheme-less image key can also be a source-specific remote key. Only
    // treat it as local when the corresponding File actually exists.
    return null;
  }

  void _updateExpectedLength(
    DownloadSession session,
    DownloadWriterLease writer,
    int? length,
  ) {
    if (length == null || length <= 0) return;
    session.updateExpectedLength(length, writer: writer);
  }

  void _publishProgress(
    void Function(WebPTransportProgress progress)? onProgress, {
    required int currentBytes,
    required DownloadSession session,
    int? reportedTotal,
  }) {
    if (onProgress == null) return;

    final normalizedReported = _normalizeReportedTotal(
      reportedTotal: reportedTotal,
      currentLength: currentBytes,
      existingExpectedLength: session.expectedLength,
    );
    final sessionExpected = _sessionExpectedLength(session);
    final total = sessionExpected != null && sessionExpected >= currentBytes
        ? sessionExpected
        : normalizedReported != null && normalizedReported >= currentBytes
            ? normalizedReported
            : null;

    onProgress(
      WebPTransportProgress(
        currentBytes: currentBytes,
        totalBytes: total,
      ),
    );
  }

  int? _normalizeReportedTotal({
    required int? reportedTotal,
    required int currentLength,
    required int existingExpectedLength,
  }) {
    // A previously known full length is preferred over per-request metadata.
    // Range responses may report only the remaining Content-Length.
    if (existingExpectedLength > 0 &&
        existingExpectedLength >= currentLength) {
      return existingExpectedLength;
    }

    if (reportedTotal == null ||
        reportedTotal <= 0 ||
        reportedTotal < currentLength) {
      return null;
    }

    return reportedTotal;
  }

  int? _sessionExpectedLength(DownloadSession session) {
    final value = session.expectedLength;
    return value > 0 ? value : null;
  }

  int _positiveOrZero(int? value) => value != null && value > 0 ? value : 0;
}

final class _WebPIngress {
  final DownloadSession session;
  final DownloadWriterLease writer;
  final WebPDownloadArtifact artifact;

  WebPArtifactContentKind _kind;
  Uint8List _pendingPrefix;
  bool _sourceContainsPrefix;
  int _receivedLength;
  int _publishedFallbackLength;
  int _lastGifPublishMs = 0;

  static const int _gifPublishBytes = 64 * 1024;
  static const int _gifPublishIntervalMs = 50;

  _WebPIngress({
    required this.session,
    required this.writer,
    required this.artifact,
    required WebPArtifactRestoreState restored,
  })  : _kind = restored.kind,
        _pendingPrefix = restored.kind == WebPArtifactContentKind.unknown
            ? restored.prefix
            : Uint8List(0),
        _sourceContainsPrefix = restored.sourceContainsPrefix,
        _receivedLength = restored.length,
        _publishedFallbackLength = restored.length;

  _WebPIngress.empty({
    required this.session,
    required this.writer,
    required this.artifact,
  })  : _kind = WebPArtifactContentKind.empty,
        _pendingPrefix = Uint8List(0),
        _sourceContainsPrefix = false,
        _receivedLength = 0,
        _publishedFallbackLength = 0;

  int get receivedLength => _receivedLength;
  bool get isFallback =>
      _kind == WebPArtifactContentKind.gif ||
      _kind == WebPArtifactContentKind.fallback;

  Future<void> append(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    if (!writer.active) {
      throw const WebPTransportCancelled('stale writer');
    }

    final offset = _receivedLength;
    await artifact.append(bytes, offset: offset);

    // Cancellation can arrive while the disk append is pending. In that case
    // leave the durable artifact one chunk ahead and let the next writer's
    // artifact.restore reconcile the exact committed prefix into the source.
    if (!writer.active) {
      throw const WebPTransportCancelled('stale writer');
    }

    _receivedLength += bytes.length;

    switch (_kind) {
      case WebPArtifactContentKind.webp:
        session.append(bytes, offset: offset, writer: writer);
        return;
      case WebPArtifactContentKind.gif:
        final now = DateTime.now().millisecondsSinceEpoch;
        if (_receivedLength - _publishedFallbackLength >= _gifPublishBytes ||
            now - _lastGifPublishMs >= _gifPublishIntervalMs) {
          await _publishGifRange(now);
        }
        return;
      case WebPArtifactContentKind.fallback:
        session.appendFallbackRange(
          writer,
          offset: offset,
          length: bytes.length,
        );
        return;
      case WebPArtifactContentKind.empty:
      case WebPArtifactContentKind.unknown:
        await _classifyAndCommit(bytes, priorOffset: offset);
        return;
    }
  }

  Future<void> finalizeContent({required int finalLength}) async {
    if (!writer.active) {
      throw const WebPTransportCancelled('stale writer');
    }
    if (finalLength != _receivedLength) {
      throw WebPSourceInvariantError(
        'final length $finalLength does not match ingress $_receivedLength',
      );
    }

    if (_kind == WebPArtifactContentKind.empty ||
        _kind == WebPArtifactContentKind.unknown) {
      // Fewer than 12 bytes cannot contain a RIFF/WEBP signature. Preserve the
      // payload through the ordinary Flutter fallback path rather than trying
      // to append it to the native WebP source.
      session.enterFallbackContent(
        writer,
        restoredLength: _receivedLength,
      );
      _kind = WebPArtifactContentKind.fallback;
      _pendingPrefix = Uint8List(0);
      _sourceContainsPrefix = false;
    } else if (_kind == WebPArtifactContentKind.gif) {
      await _publishGifRange(DateTime.now().millisecondsSinceEpoch);
    }
  }

  Future<void> _publishGifRange(int now) async {
    final length = _receivedLength - _publishedFallbackLength;
    if (length <= 0) return;
    await artifact.flush();
    session.appendFallbackRange(
      writer,
      offset: _publishedFallbackLength,
      length: length,
    );
    _publishedFallbackLength = _receivedLength;
    _lastGifPublishMs = now;
  }

  Future<void> _classifyAndCommit(
    Uint8List bytes, {
    required int priorOffset,
  }) async {
    final oldPrefix = _pendingPrefix;
    final headerLength = oldPrefix.length + bytes.length;

    if (headerLength < 12) {
      final next = Uint8List(headerLength)
        ..setRange(0, oldPrefix.length, oldPrefix)
        ..setRange(oldPrefix.length, headerLength, bytes);
      _pendingPrefix = next;
      _kind = WebPArtifactContentKind.unknown;
      return;
    }

    final header = Uint8List(12);
    final prefixCopy = oldPrefix.length < 12 ? oldPrefix.length : 12;
    if (prefixCopy > 0) {
      header.setRange(0, prefixCopy, oldPrefix);
    }

    final remaining = 12 - prefixCopy;
    if (remaining > 0) {
      header.setRange(prefixCopy, 12, bytes, 0);
    }

    final classified = WebPDownloadArtifact.classifyPrefix(
      header,
      completeLength: _receivedLength,
    );

    if (classified == WebPArtifactContentKind.gif ||
        classified == WebPArtifactContentKind.fallback) {
      if (classified == WebPArtifactContentKind.gif) await artifact.flush();
      session.enterFallbackContent(
        writer,
        restoredLength: _receivedLength,
        contentKind: classified == WebPArtifactContentKind.gif
            ? DownloadContentKind.gif
            : DownloadContentKind.fallback,
      );
      _publishedFallbackLength = _receivedLength;
      _lastGifPublishMs = DateTime.now().millisecondsSinceEpoch;
      _kind = classified;
      _pendingPrefix = Uint8List(0);
      _sourceContainsPrefix = false;
      return;
    }

    if (!_sourceContainsPrefix && oldPrefix.isNotEmpty) {
      session.append(oldPrefix, offset: 0, writer: writer);
    }

    session.append(
      bytes,
      offset: session.sourceCommittedLength,
      writer: writer,
    );
    session.identifyWebPContent(writer);

    _kind = WebPArtifactContentKind.webp;
    _pendingPrefix = Uint8List(0);
    _sourceContainsPrefix = true;

    if (session.sourceCommittedLength != _receivedLength) {
      throw WebPSourceInvariantError(
        'classified WebP source length ${session.sourceCommittedLength} '
        'does not match artifact $_receivedLength (prior=$priorOffset)',
      );
    }
  }
}
