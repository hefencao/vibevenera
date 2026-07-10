import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:venera/network/images.dart';

Future<Uint8List> loadNetworkImageBytes(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  StreamController<ImageChunkEvent>? chunkEvents,
  String? debugLabel,
  void Function(ImageDownloadProgress event)? onEvent,
  CancelToken? cancelToken,
}) async {
  final stream = ImageDownloader.loadComicImage(
    imageKey,
    sourceKey,
    cid,
    eid,
    debugLabel: debugLabel,
    cancelToken: cancelToken,
  );
  final result = await listenImageDownloadStream(
    stream,
    chunkEvents: chunkEvents,
    onEvent: onEvent,
    cancelToken: cancelToken,
    imageKey: imageKey,
  );
  if (result == null) throw Exception('Load failed: $imageKey');
  return result;
}

Future<Uint8List> loadNetworkImageBytesRaw(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  String? debugLabel,
}) async {
  final stream = ImageDownloader.loadComicImageUnwrapped(
    imageKey,
    sourceKey,
    cid,
    eid,
    debugLabel: debugLabel ?? 'raw',
  );
  await for (final event in stream) {
    final bytes = event.imageBytes;
    if (bytes != null) return bytes;
  }
  throw Exception('Load failed: $imageKey');
}

Future<Uint8List?> listenImageDownloadStream(
  Stream<ImageDownloadProgress> stream, {
  StreamController<ImageChunkEvent>? chunkEvents,
  void Function(ImageDownloadProgress event)? onEvent,
  CancelToken? cancelToken,
  required String imageKey,
}) {
  final completer = Completer<Uint8List?>();
  StreamSubscription<ImageDownloadProgress>? subscription;

  void cancelSubscription() {
    final current = subscription;
    if (current != null) unawaited(current.cancel());
  }

  subscription = stream.listen(
    (event) {
      if (completer.isCompleted) return;
      onEvent?.call(event);
      if (chunkEvents != null && !chunkEvents.isClosed) {
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.currentBytes,
            expectedTotalBytes: event.totalBytes,
          ),
        );
      }
      final bytes = event.imageBytes;
      if (bytes != null) {
        completer.complete(bytes);
        // A synchronous stream may emit from onListen before the assignment to
        // [subscription] has completed. Cancel in a microtask to avoid a late-
        // initialization race.
        scheduleMicrotask(cancelSubscription);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    },
    cancelOnError: false,
  );

  final cancellation = cancelToken?.whenCancel;
  if (cancellation != null) {
    unawaited(
      cancellation.then((_) {
        cancelSubscription();
        if (!completer.isCompleted) {
          completer.completeError(Exception('Cancelled: $imageKey'));
        }
      }),
    );
  }
  return completer.future;
}
