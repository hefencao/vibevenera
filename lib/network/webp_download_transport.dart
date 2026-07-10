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
  String toString() => 'WebP transport cancelled${reason == null ? '' : ': $reason'}';
}

abstract interface class WebPTransport {
  Future<File> execute(
    DownloadSession session, {
    CancelToken? cancelToken,
    void Function(WebPTransportProgress progress)? onProgress,
  });
}

/// Adapter around the existing Dart network stack.
///
/// It is the only place that translates legacy ImageDownloadProgress events
/// into explicit [offset, bytes] writes. Downstream consumers never infer an
/// offset from a broadcast event and never replay chunk history.
final class ImageDownloaderWebPTransport implements WebPTransport {
  final DownloadIdentity identity;
  final WebPDownloadArtifact Function(String cacheKey) artifactFactory;

  ImageDownloaderWebPTransport(
    this.identity, {
    WebPDownloadArtifact Function(String cacheKey)? artifactFactory,
  }) : artifactFactory = artifactFactory ?? WebPDownloadArtifact.forCacheKey;

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
      await artifact.restore(session, activeWriter);
      _throwIfCancelled(cancelToken);

      final resumeOffset = session.committedLength;
      onProgress?.call(
        WebPTransportProgress(
          currentBytes: resumeOffset,
          totalBytes: session.expectedLength > 0
              ? session.expectedLength
              : null,
        ),
      );

      iterator = StreamIterator<ImageDownloadProgress>(
        ImageDownloader.loadComicImage(
          identity.imageKey,
          identity.sourceKey,
          identity.cid,
          identity.eid,
          debugLabel: 'webp-session:${identity.imageKey}',
          resumeFromBytes: resumeOffset > 0 ? resumeOffset : null,
          resumeExpectedBytes:
              session.expectedLength > 0 ? session.expectedLength : null,
          // A restored NativeWebPSource is already authoritative. Replaying the
          // Dart-side partial history would create a second input path.
          replayPartial: false,
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
        } else {
          session.updateExpectedLength(
            event.totalBytes,
            writer: activeWriter,
          );
        }

        final chunk = event.chunkBytes;
        if (chunk != null && chunk.isNotEmpty) {
          final end = event.currentBytes;
          final start = end - chunk.length;
          await _appendNormalized(
            session,
            activeWriter,
            artifact,
            chunk,
            offset: start,
          );
        }

        final finalBytes = event.imageBytes;
        if (finalBytes != null) {
          await _appendFinalTail(
            session,
            activeWriter,
            artifact,
            finalBytes,
          );
          session.updateExpectedLength(
            finalBytes.length,
            writer: activeWriter,
          );
          await artifact.flush();
          final file = await artifact.promote(
            sealedLength: session.committedLength,
          );
          session.seal(activeWriter, file);
          onProgress?.call(
            WebPTransportProgress(
              currentBytes: finalBytes.length,
              totalBytes: finalBytes.length,
              done: true,
            ),
          );
          return file;
        }

        onProgress?.call(
          WebPTransportProgress(
            currentBytes: session.committedLength,
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

  Future<void> _appendNormalized(
    DownloadSession session,
    DownloadWriterLease writer,
    WebPDownloadArtifact artifact,
    Uint8List bytes, {
    required int offset,
  }) async {
    final committed = session.committedLength;
    final end = offset + bytes.length;
    if (end <= committed) return;
    if (offset > committed) {
      throw StateError(
        'Network chunk gap: committed=$committed, chunk=$offset..$end',
      );
    }

    final trim = committed - offset;
    final tail = trim == 0 ? bytes : Uint8List.sublistView(bytes, trim);
    await artifact.append(tail, offset: committed);
    session.append(tail, offset: committed, writer: writer);
  }

  Future<void> _appendFinalTail(
    DownloadSession session,
    DownloadWriterLease writer,
    WebPDownloadArtifact artifact,
    Uint8List bytes,
  ) async {
    final committed = session.committedLength;
    if (bytes.length < committed) {
      throw StateError(
        'Final WebP bytes are shorter than committed source: '
        '${bytes.length}/$committed',
      );
    }
    if (bytes.length == committed) return;
    final tail = Uint8List.sublistView(bytes, committed);
    await artifact.append(tail, offset: committed);
    session.append(tail, offset: committed, writer: writer);
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
}
