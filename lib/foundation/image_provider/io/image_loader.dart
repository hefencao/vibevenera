import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/images.dart';

import 'image_data_validator.dart';
import 'local_file_loader.dart';
import 'network_loader.dart';

export 'local_file_loader.dart' show tryLoadLocalFile;

String imageCacheKey(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid,
) => '$imageKey@$sourceKey@$cid@$eid';

Future<void> evictImageDiskCache(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid,
) => CacheManager().delete(imageCacheKey(imageKey, sourceKey, cid, eid));

/// Unified image byte loader.
///
/// Load order:
///   1. local file path / file:// (delegated unchanged to IOOverride)
///   2. validated disk cache
///   3. network image
Future<Uint8List?> _readValidCacheFile(String cacheKey, File cacheFile) async {
  final validation = await ImageDataValidator.validateFile(cacheFile);
  if (!validation.valid) {
    await CacheManager().delete(cacheKey);
    Log.warning('Image cache rejected', '$cacheKey: ${validation.reason}');
    return null;
  }

  final fileSize = await cacheFile.length();
  final path = cacheFile.path;
  return fileSize > 1024 * 1024
      ? Isolate.run(() => File(path).readAsBytesSync())
      : cacheFile.readAsBytes();
}

Future<Uint8List?> _tryReadDiskCache(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid,
) async {
  final cacheKey = imageCacheKey(imageKey, sourceKey, cid, eid);
  try {
    final cacheFile = await CacheManager().findCache(
      cacheKey,
      cacheClass: CacheClass.readerPage,
    );
    if (cacheFile != null && await cacheFile.exists()) {
      return _readValidCacheFile(cacheKey, cacheFile);
    }
  } catch (error, stackTrace) {
    Log.error('Disk cache check failed for $imageKey', error, stackTrace);
  }
  return null;
}

Future<Uint8List> _validateDownloadedBytes(
  Uint8List bytes, {
  required String imageKey,
  required String? sourceKey,
  required String cid,
  required String eid,
}) async {
  final validation = ImageDataValidator.validateBytes(bytes);
  if (validation.valid) return bytes;

  // ImageDownloader may already have persisted this response. Remove the
  // identity cache immediately so the next attempt cannot decode the same
  // partial/HTML payload again.
  await evictImageDiskCache(imageKey, sourceKey, cid, eid);
  throw InvalidImageDataException(
    '${validation.reason}; key=$imageKey, bytes=${bytes.length}',
  );
}

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
  // Do not strip or convert file://. File(imageKey) is intentionally routed
  // through the application's IOOverride.
  final local = await tryLoadLocalFile(imageKey);
  if (local != null) return local;

  final cached = await _tryReadDiskCache(imageKey, sourceKey, cid, eid);
  if (cached != null) return cached;

  final bytes = await loadNetworkImageBytes(
    imageKey,
    sourceKey,
    cid,
    eid,
    chunkEvents: chunkEvents,
    debugLabel: debugLabel,
    onEvent: onEvent,
    cancelToken: cancelToken,
  );
  return _validateDownloadedBytes(
    bytes,
    imageKey: imageKey,
    sourceKey: sourceKey,
    cid: cid,
    eid: eid,
  );
}

Future<Uint8List> fetchImageBytesRaw(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  String? debugLabel,
}) async {
  final local = await tryLoadLocalFile(imageKey);
  if (local != null) return local;

  final cached = await _tryReadDiskCache(imageKey, sourceKey, cid, eid);
  if (cached != null) return cached;

  final bytes = await loadNetworkImageBytesRaw(
    imageKey,
    sourceKey,
    cid,
    eid,
    debugLabel: debugLabel,
  );
  return _validateDownloadedBytes(
    bytes,
    imageKey: imageKey,
    sourceKey: sourceKey,
    cid: cid,
    eid: eid,
  );
}

Future<Uint8List?> tryReadFromCache(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid,
) async {
  final local = await tryLoadLocalFile(imageKey);
  if (local != null) return local;
  return _tryReadDiskCache(imageKey, sourceKey, cid, eid);
}
