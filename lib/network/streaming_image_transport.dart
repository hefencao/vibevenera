import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/network/images.dart';
import 'package:venera/network/streaming_image_artifact.dart';

part 'streaming_image_ingress.dart';

final class StreamingTransportProgress {
  final int currentBytes;
  final int? totalBytes;
  final bool done;

  const StreamingTransportProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.done = false,
  });
}

final class StreamingTransportCancelled implements Exception {
  final Object? reason;

  const StreamingTransportCancelled([this.reason]);

  @override
  String toString() =>
      'Streaming image transport cancelled${reason == null ? '' : ': $reason'}';
}

abstract interface class StreamingImageTransport {
  Future<File> execute(
    DownloadSession session, {
    CancelToken? cancelToken,
    void Function(StreamingTransportProgress progress)? onProgress,
  });
}

typedef StreamingDownloadEventSource = Stream<ImageDownloadProgress> Function({
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
final class ImageDownloaderStreamingTransport implements StreamingImageTransport {
  static const int _initialLocalReadSize = 1024 * 1024;
  static const int _localReadSize = 512 * 1024;

  final DownloadIdentity identity;
  final StreamingImageArtifact Function(String cacheKey) artifactFactory;
  final StreamingDownloadEventSource eventSource;

  ImageDownloaderStreamingTransport(
    this.identity, {
    StreamingImageArtifact Function(String cacheKey)? artifactFactory,
    StreamingDownloadEventSource? eventSource,
  })  : artifactFactory =
            artifactFactory ?? StreamingImageArtifact.forCacheKey,
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
                debugLabel: 'streaming-image:${identity.imageKey}',
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
    void Function(StreamingTransportProgress progress)? onProgress,
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
      if (restored.kind == StreamingArtifactContentKind.webp) {
        session.identifyWebPContent(activeWriter);
      }
      Log.info(
        'Streaming.Cache',
        'artifact ${restored.length == 0 ? 'empty' : 'restored'}: '
            'source=${identity.sourceKey} cid=${identity.cid} eid=${identity.eid} '
            'bytes=${restored.length} kind=${restored.kind.name} complete=${restored.complete}',
      );

      var ingress = _StreamingImageIngress(
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
            epoch: session.sourceEpoch + 1,
            expectedLength: _positiveOrZero(event.totalBytes),
          );
          ingress = _StreamingImageIngress.empty(
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
            throw DownloadSourceInvariantError(
              'final payload cannot repair streaming input: final='
              '${finalBytes.length}, committed=${ingress.receivedLength}, '
              'epoch=${session.sourceEpoch}',
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
        'Streaming image download ended without a complete payload: '
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
    required _StreamingImageIngress ingress,
    required StreamingImageArtifact artifact,
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
        epoch: session.sourceEpoch + 1,
        expectedLength: localLength,
      );
      activeIngress = _StreamingImageIngress.empty(
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
          throw DownloadSourceInvariantError(
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
    required StreamingImageArtifact artifact,
    required CancelToken? cancelToken,
  }) async {
    final length = await file.length();
    if (length <= 0) {
      throw StateError('Cached image file is empty: ${identity.imageKey}');
    }
    await artifact.reset();
    var activeWriter = session.resetSource(
      writer: writer,
      epoch: session.sourceEpoch + 1,
      expectedLength: length,
    );
    final reader = await file.open();
    try {
      final prefix = Uint8List.fromList(await reader.read(12));
      final kind = StreamingImageArtifact.classifyPrefix(
        prefix,
        completeLength: length,
      );
      if (kind != StreamingArtifactContentKind.webp) {
        session.enterExternalContent(
          activeWriter,
          restoredLength: length,
          contentKind: kind == StreamingArtifactContentKind.gif
              ? DownloadContentKind.gif
              : DownloadContentKind.fallback,
        );
        session.updateExpectedLength(length, writer: activeWriter);
        session.sealExternalContent(activeWriter, file, finalLength: length);
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
            throw DownloadSourceInvariantError(
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
      'Streaming.Cache',
      'reuse: image=${identity.imageKey} source=${identity.sourceKey} '
          'cid=${identity.cid} eid=${identity.eid} bytes=$length',
    );
    return file;
  }

  Future<File> _completeIngress({
    required DownloadSession session,
    required DownloadWriterLease writer,
    required _StreamingImageIngress ingress,
    required StreamingImageArtifact artifact,
    required int finalLength,
    required void Function(StreamingTransportProgress progress)? onProgress,
  }) async {
    if (finalLength <= 0) {
      throw StateError('Cannot seal an empty image: ${identity.imageKey}');
    }
    if (!writer.active) {
      throw const StreamingTransportCancelled('stale writer before seal');
    }
    if (finalLength != ingress.receivedLength) {
      throw DownloadSourceInvariantError(
        'seal length $finalLength does not match ingress '
        '${ingress.receivedLength}',
      );
    }

    await ingress.finalizeContent(finalLength: finalLength);
    session.updateExpectedLength(finalLength, writer: writer);
    await artifact.flush();

    if (!writer.active) {
      throw const StreamingTransportCancelled('stale writer before promote');
    }

    final file = await artifact.promote(sealedLength: finalLength);
    Log.info(
      'Streaming.Cache',
      'promoted: image=${identity.imageKey} source=${identity.sourceKey} '
          'cid=${identity.cid} eid=${identity.eid} bytes=$finalLength exists=${await file.exists()}',
    );

    if (ingress.isFallback) {
      session.sealExternalContent(
        writer,
        file,
        finalLength: finalLength,
      );
    } else {
      session.seal(writer, file);
    }

    onProgress?.call(
      StreamingTransportProgress(
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
      throw const StreamingTransportCancelled('cancelled');
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
    void Function(StreamingTransportProgress progress)? onProgress, {
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
      StreamingTransportProgress(
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