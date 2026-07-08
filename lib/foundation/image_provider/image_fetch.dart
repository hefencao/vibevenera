import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/images.dart';

/// Unified image byte loader — eliminates 4 duplicate three-path logic.
///
/// Load order:
///   1. No protocol but local file exists → direct read
///   2. `file://` protocol → direct file read
///   3. Disk cache → direct return
///   4. Network image → [ImageDownloader] download
///
/// All paths go through [fetchImageBytes] entry, with automatic
/// per-key deduplication.
/// For independent streams (like download managers), use
/// [fetchImageBytesRaw].

/// Handles both `file://` protocol paths and direct file paths.
/// Delegates to `File()` — on Android, `_IOOverrides.createFile`
/// transparently handles SAF paths.
///
/// Returns null if not a local file, needs network loading.
///
/// For files larger than 1MB, use Isolate.run to avoid blocking
/// the main isolate during synchronous filesystem work.
Future<Uint8List?> tryLoadLocalFile(String imageKey) async {
  // 1. Network URL (https://, http://, etc.) → not local
  if (imageKey.contains('://') && !imageKey.startsWith('file://')) {
    return null;
  }

  // 2. Direct File() read — IOOverrides transparently handles
  //    Android SAF paths on Android.
  try {
    final file = File(imageKey);
    if (!await file.exists()) return null;

    final fileSize = await file.length();
    final isFileScheme = imageKey.startsWith('file://');

    if (fileSize > 1024 * 1024 && !isFileScheme) {
      // Large file with a plain filesystem path → offload to
      // isolate. IOOverrides is NOT active in spawned isolates,
      // so file:// URIs must stay on the main isolate.
      final path = file.path;
      return await Isolate.run(() => File(path).readAsBytesSync());
    }

    // Small file, or file:// URI needing IOOverrides → main isolate.
    return await file.readAsBytes();
  } catch (e) {
    Log.error('Local file load failed for $imageKey', e);
    return null;
  }
}

/// Fetch image bytes from network with per-key deduplication.
///
/// If multiple requests come in for the same imageKey while a
/// download is in progress, they share the same stream.
Future<Uint8List> fetchImageBytes(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  StreamController<ImageChunkEvent>? chunkEvents,
  String? debugLabel,
  void Function(ImageDownloadProgress event)? onEvent,
  CancelToken? cancelToken,
}) async {
  // Check local file first
  final local = await tryLoadLocalFile(imageKey);
  if (local != null) return local;

  // Check disk cache
  final cacheKey = '$imageKey@$sourceKey@$cid@$eid';
  try {
    final cacheFile = await CacheManager().findCache(cacheKey);
    if (cacheFile != null && await cacheFile.exists()) {
      final fileSize = await cacheFile.length();

      if (fileSize > 1024 * 1024) {
        final path = cacheFile.path;
        return await Isolate.run(() => File(path).readAsBytesSync());
      }

      final bytes = await cacheFile.readAsBytes();
      if (bytes.isNotEmpty) return bytes;
    }
  } catch (e) {
    Log.error('Disk cache check failed for $imageKey', e);
  }

  // Network download
  final stream = ImageDownloader.loadComicImage(
    imageKey,
    sourceKey,
    cid,
    eid,
    debugLabel: debugLabel,
    cancelToken: cancelToken,
  );

  final result = await _listenImageStream(
    stream,
    chunkEvents: chunkEvents,
    onEvent: onEvent,
    cancelToken: cancelToken,
    imageKey: imageKey,
  );
  if (result == null) throw Exception('Load failed: $imageKey');
  return result;
}

Future<Uint8List?> _listenImageStream(
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

/// Fetch image bytes without deduplication (raw stream).
///
/// Use this when you need an independent download stream,
/// e.g., for download managers.
Future<Uint8List> fetchImageBytesRaw(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  String? debugLabel,
}) async {
  // Check local file first
  final local = await tryLoadLocalFile(imageKey);
  if (local != null) return local;

  // Check disk cache
  final cacheKey = '$imageKey@$sourceKey@$cid@$eid';
  try {
    final cacheFile = await CacheManager().findCache(cacheKey);
    if (cacheFile != null && await cacheFile.exists()) {
      final fileSize = await cacheFile.length();

      if (fileSize > 1024 * 1024) {
        final path = cacheFile.path;
        return await Isolate.run(() => File(path).readAsBytesSync());
      }

      final bytes = await cacheFile.readAsBytes();
      if (bytes.isNotEmpty) return bytes;
    }
  } catch (e) {
    Log.error('Disk cache check failed for $imageKey', e);
  }

  // Network download (unwrapped, no dedup)
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

/// Try to read bytes from disk cache without triggering network.
///
/// Checks local file first, then disk cache. Returns null if miss.
Future<Uint8List?> tryReadFromCache(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid,
) async {
  final local = await tryLoadLocalFile(imageKey);
  if (local != null) return local;

  final cacheKey = '$imageKey@$sourceKey@$cid@$eid';
  try {
    final cacheFile = await CacheManager().findCache(cacheKey);
    if (cacheFile != null && await cacheFile.exists()) {
      final fileSize = await cacheFile.length();

      if (fileSize > 1024 * 1024) {
        final path = cacheFile.path;
        return await Isolate.run(() => File(path).readAsBytesSync());
      }

      final bytes = await cacheFile.readAsBytes();
      if (bytes.isNotEmpty) return bytes;
    }
  } catch (e) {
    Log.error('Disk cache check failed for $imageKey', e);
  }
  return null;
}
