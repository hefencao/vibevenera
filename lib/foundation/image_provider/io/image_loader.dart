import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/images.dart';

import 'local_file_loader.dart';
import 'network_loader.dart';

export 'local_file_loader.dart' show tryLoadLocalFile;

/// Unified image byte loader — eliminates duplicate local/cache/network logic.
///
/// Load order:
///   1. local file path / file://
///   2. disk cache
///   3. network image
///
/// All paths go through [fetchImageBytes] entry, with automatic per-key
/// deduplication in [ImageDownloader]. For independent streams, use
/// [fetchImageBytesRaw].
Future<Uint8List?> _readValidCacheFile(String cacheKey, File cacheFile) async {
  final fileSize = await cacheFile.length();
  final path = cacheFile.path;
  final bytes = fileSize > 1024 * 1024
      ? await Isolate.run(() => File(path).readAsBytesSync())
      : await cacheFile.readAsBytes();
  if (bytes.isEmpty) return null;
  if (ImageDownloader.isIncompleteWebPBytes(bytes)) {
    await CacheManager().delete(cacheKey);
    return null;
  }
  return bytes;
}

Future<Uint8List?> _tryReadDiskCache(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid,
) async {
  final cacheKey = '$imageKey@$sourceKey@$cid@$eid';
  try {
    final cacheFile = await CacheManager().findCache(cacheKey);
    if (cacheFile != null && await cacheFile.exists()) {
      return await _readValidCacheFile(cacheKey, cacheFile);
    }
  } catch (e) {
    Log.error('Disk cache check failed for $imageKey', e);
  }
  return null;
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
  final local = await tryLoadLocalFile(imageKey);
  if (local != null) return local;

  final cached = await _tryReadDiskCache(imageKey, sourceKey, cid, eid);
  if (cached != null) return cached;

  return loadNetworkImageBytes(
    imageKey,
    sourceKey,
    cid,
    eid,
    chunkEvents: chunkEvents,
    debugLabel: debugLabel,
    onEvent: onEvent,
    cancelToken: cancelToken,
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

  return loadNetworkImageBytesRaw(
    imageKey,
    sourceKey,
    cid,
    eid,
    debugLabel: debugLabel,
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