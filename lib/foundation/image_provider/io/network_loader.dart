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
  Uint8List? result;
  await for (final event in stream) {
    if (event.imageBytes != null) {
      result = event.imageBytes!;
      break;
    }
  }
  if (result == null) throw Exception('Load failed: $imageKey');
  return result;
}

Future<Uint8List?> listenImageDownloadStream(
  Stream<ImageDownloadProgress> stream, {
  StreamController<ImageChunkEvent>? chunkEvents,
  void Function(ImageDownloadProgress event)? onEvent,
  CancelToken? cancelToken,
  required String imageKey,
}) {
  final c = Completer<Uint8List?>();
  late StreamSubscription<ImageDownloadProgress> sub;
  sub = stream.listen((event) {
    onEvent?.call(event);
    if (chunkEvents != null && !chunkEvents.isClosed) {
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: event.currentBytes,
          expectedTotalBytes: event.totalBytes ?? 0,
        ),
      );
    }
    if (event.imageBytes != null) {
      if (!c.isCompleted) c.complete(event.imageBytes!);
      sub.cancel();
    }
  }, onError: (e, s) {
    if (!c.isCompleted) c.completeError(e, s);
  }, onDone: () {
    if (!c.isCompleted) c.complete(null);
  });
  cancelToken?.whenCancel.then((_) {
    sub.cancel();
    if (!c.isCompleted) c.completeError(Exception('Cancelled: $imageKey'));
  });
  return c.future;
}