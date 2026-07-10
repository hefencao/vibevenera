import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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

/// Adapter around the existing Dart network stack.
///
/// It owns one monotonic ingress cursor and is the only consumer of legacy
/// ImageDownloadProgress chunk events. `currentBytes` is progress metadata;
/// source offsets are never inferred from `currentBytes - chunk.length`.
final class ImageDownloaderWebPTransport implements WebPTransport {
  static const _localReadSize = 256 * 1024;

  final DownloadIdentity identity;
  final WebPDownloadArtifact Function(String cacheKey) artifactFactory;
  final WebPDownloadEventSource eventSource;

  ImageDownloaderWebPTransport(
    this.identity, {
    WebPDownloadArtifact Function(String cacheKey)? artifactFactory,
    WebPDownloadEventSource? eventSource,
  })  : artifactFactory = artifactFactory ?? WebPDownloadArtifact.forCacheKey,
        eventSource = eventSource ??
            (({
              required int resumeOffset,
              required int? expectedLength,
              CancelToken? cancelToken,
            }) =>
                ImageDownloader.loadComicImage(
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
                ));

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
      var ingress = _WebPIngress(
        session: session,
        writer: activeWriter,
        artifact: artifact,
        restored: restored,
      );
      _throwIfCancelled(cancelToken);

      final localFile = await _localFile();
      if (localFile != null) {
        final localLength = await localFile.length();
        if (localLength <= 0) throw StateError('Local image file is empty');
        if (ingress.receivedLength > localLength) {
          await artifact.reset();
          activeWriter = session.resetSource(
            writer: activeWriter,
            epoch: session.source.epoch + 1,
            expectedLength: localLength,
          );
          ingress = _WebPIngress.empty(
            session: session,
            writer: activeWriter,
            artifact: artifact,
          );
        } else {
          session.updateExpectedLength(localLength, writer: activeWriter);
        }
        final reader = await localFile.open();
        try {
          await reader.setPosition(ingress.receivedLength);
          while (ingress.receivedLength < localLength) {
            _throwIfCancelled(cancelToken);
            final remaining = localLength - ingress.receivedLength;
            final chunk = await reader.read(
              remaining < _localReadSize ? remaining : _localReadSize,
            );
            if (chunk.isEmpty) {
              throw WebPSourceInvariantError(
                'local file ended at ${ingress.receivedLength}/$localLength',
              );
            }
            await ingress.append(chunk);
            onProgress?.call(
              WebPTransportProgress(
                currentBytes: ingress.receivedLength,
                totalBytes: localLength,
              ),
            );
          }
        } finally {
          await reader.close();
        }
        await ingress.finalizeContent(finalLength: localLength);
        await artifact.flush();
        final file = await artifact.promote(sealedLength: localLength);
        if (ingress.isFallback) {
          session.sealFallback(
            activeWriter,
            file,
            finalLength: localLength,
          );
        } else {
          session.seal(activeWriter, file);
        }
        onProgress?.call(
          WebPTransportProgress(
            currentBytes: localLength,
            totalBytes: localLength,
            done: true,
          ),
        );
        return file;
      }

      final resumeOffset = restored.length;
      onProgress?.call(
        WebPTransportProgress(
          currentBytes: resumeOffset,
          totalBytes:
              session.expectedLength > 0 ? session.expectedLength : null,
        ),
      );

      iterator = StreamIterator<ImageDownloadProgress>(
        eventSource(
          resumeOffset: resumeOffset,
          expectedLength:
              session.expectedLength > 0 ? session.expectedLength : null,
          cancelToken: cancelToken,
        ),
      );

      while (await _moveNext(iterator, cancelToken)) {
        _throwIfCancelled(cancelToken);
        final event = iterator.current;

        if (event.reset) {
          await artifact.reset();
          activeWriter = session.resetSource(
            writer: activeWriter,
            epoch: session.source.epoch + 1,
            expectedLength: event.totalBytes ?? 0,
          );
          ingress = _WebPIngress.empty(
            session: session,
            writer: activeWriter,
            artifact: artifact,
          );
        } else {
          session.updateExpectedLength(
            event.totalBytes,
            writer: activeWriter,
          );
        }

        final chunk = event.chunkBytes;
        if (chunk != null && chunk.isNotEmpty) {
          await ingress.append(chunk);
        }

        final finalBytes = event.imageBytes;
        if (finalBytes != null) {
          // One-shot legacy responses are valid initial input. Once any range
          // has been committed, the final payload is only a completion/length
          // signal and may not repair a discontinuous stream.
          if (ingress.receivedLength == 0 && finalBytes.isNotEmpty) {
            await ingress.append(finalBytes);
          } else if (finalBytes.length != ingress.receivedLength) {
            throw WebPSourceInvariantError(
              'final payload cannot repair streaming input: final='
              '${finalBytes.length}, committed=${ingress.receivedLength}, '
              'epoch=${session.source.epoch}',
            );
          }

          await ingress.finalizeContent(finalLength: finalBytes.length);
          session.updateExpectedLength(
            finalBytes.length,
            writer: activeWriter,
          );
          await artifact.flush();
          final file = await artifact.promote(
            sealedLength: ingress.receivedLength,
          );
          if (ingress.isFallback) {
            session.sealFallback(
              activeWriter,
              file,
              finalLength: ingress.receivedLength,
            );
          } else {
            session.seal(activeWriter, file);
          }
          onProgress?.call(
            WebPTransportProgress(
              currentBytes: ingress.receivedLength,
              totalBytes: ingress.receivedLength,
              done: true,
            ),
          );
          return file;
        }

        if (event.done) {
          await ingress.finalizeContent(finalLength: event.currentBytes);
          session.updateExpectedLength(
            event.currentBytes,
            writer: activeWriter,
          );
          await artifact.flush();
          final file = await artifact.promote(
            sealedLength: ingress.receivedLength,
          );
          if (ingress.isFallback) {
            session.sealFallback(
              activeWriter,
              file,
              finalLength: ingress.receivedLength,
            );
          } else {
            session.seal(activeWriter, file);
          }
          onProgress?.call(
            WebPTransportProgress(
              currentBytes: ingress.receivedLength,
              totalBytes: ingress.receivedLength,
              done: true,
            ),
          );
          return file;
        }

        onProgress?.call(
          WebPTransportProgress(
            currentBytes: ingress.receivedLength,
            totalBytes: event.totalBytes,
          ),
        );
      }

      _throwIfCancelled(cancelToken);
      throw StateError('WebP stream ended without final bytes');
    } finally {
      await iterator?.cancel();
      await artifact.close();
    }
  }

  Future<bool> _moveNext(
    StreamIterator<ImageDownloadProgress> iterator,
    CancelToken? cancelToken,
  ) async {
    if (cancelToken == null) return iterator.moveNext();
    if (cancelToken.isCancelled) {
      throw WebPTransportCancelled('cancelled');
    }
    final result = await Future.any<bool>([
      iterator.moveNext(),
      cancelToken.whenCancel.then((_) => false),
    ]);
    if (cancelToken.isCancelled) {
      throw WebPTransportCancelled('cancelled');
    }
    return result;
  }

  void _throwIfCancelled(CancelToken? token) {
    if (token?.isCancelled == true) {
      throw WebPTransportCancelled('cancelled');
    }
  }

  Future<File?> _localFile() async {
    final key = identity.imageKey;
    final explicitFileUri = key.startsWith('file://');

    // Keep file:// untouched. The project's IOOverrides implementation is
    // responsible for resolving it to the actual local/SAF file.
    if (!explicitFileUri && key.contains('://')) {
      return null;
    }

    final file = File(key);
    if (await file.exists()) {
      return file;
    }

    if (explicitFileUri) {
      throw FileSystemException(
        'Local image file does not exist',
        key,
      );
    }

    return null;
  }
}

final class _WebPIngress {
  final DownloadSession session;
  final DownloadWriterLease writer;
  final WebPDownloadArtifact artifact;

  WebPArtifactContentKind _kind;
  Uint8List _pendingPrefix;
  bool _sourceContainsPrefix;
  int _receivedLength;

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
        _receivedLength = restored.length;

  _WebPIngress.empty({
    required this.session,
    required this.writer,
    required this.artifact,
  })  : _kind = WebPArtifactContentKind.empty,
        _pendingPrefix = Uint8List(0),
        _sourceContainsPrefix = false,
        _receivedLength = 0;

  int get receivedLength => _receivedLength;
  bool get isFallback => _kind == WebPArtifactContentKind.fallback;

  Future<void> append(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    if (!writer.active) throw const WebPTransportCancelled('stale writer');

    final offset = _receivedLength;
    await artifact.append(bytes, offset: offset);
    // Cancellation is requested asynchronously. Do not let a writer that was
    // retired while disk I/O was in progress mutate the native source. The
    // durable artifact may be one chunk ahead and will be reconciled from its
    // exact length by the next transport writer.
    if (!writer.active) throw const WebPTransportCancelled('stale writer');
    _receivedLength += bytes.length;

    switch (_kind) {
      case WebPArtifactContentKind.webp:
        session.append(bytes, offset: offset, writer: writer);
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
    if (finalLength != _receivedLength) {
      throw WebPSourceInvariantError(
        'final length $finalLength does not match ingress $_receivedLength',
      );
    }
    if (_kind == WebPArtifactContentKind.empty ||
        _kind == WebPArtifactContentKind.unknown) {
      // Fewer than 12 bytes cannot be a RIFF/WEBP payload.
      session.enterFallbackContent(
        writer,
        restoredLength: _receivedLength,
      );
      _kind = WebPArtifactContentKind.fallback;
      _pendingPrefix = Uint8List(0);
      _sourceContainsPrefix = false;
    }
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

    if (classified == WebPArtifactContentKind.fallback) {
      session.enterFallbackContent(
        writer,
        restoredLength: _receivedLength,
      );
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
