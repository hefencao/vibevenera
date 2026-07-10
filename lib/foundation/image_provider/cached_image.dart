import 'dart:async' show Future;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';

import 'base_image.dart';
import 'io/image_data_validator.dart';
import 'io/image_loader.dart';

class CachedImageProvider extends BaseImageProvider<CachedImageProvider> {
  const CachedImageProvider(
    this.url, {
    this.headers,
    this.sourceKey,
    this.cid,
    this.fallbackToLocalCover = false,
  });

  final String url;
  final Map<String, String>? headers;
  final String? sourceKey;
  final String? cid;
  final bool fallbackToLocalCover;

  static int loadingCount = 0;
  static const int _kMaxLoadingCount = 8;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    while (loadingCount >= _kMaxLoadingCount) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      checkStop();
    }
    loadingCount++;
    try {
      // Preserve file:// and let IOOverride handle it.
      final local = await tryLoadLocalFile(url);
      if (local != null) return local;

      await for (final progress in ImageDownloader.loadThumbnail(
        url,
        sourceKey,
        cid,
      )) {
        checkStop();
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: progress.currentBytes,
            expectedTotalBytes: progress.totalBytes,
          ),
        );
        final bytes = progress.imageBytes;
        if (bytes == null) continue;
        final validation = ImageDataValidator.validateBytes(bytes);
        if (!validation.valid) {
          await evictInvalidCache();
          throw InvalidImageDataException(validation.reason);
        }
        return bytes;
      }
      throw Exception('Empty response body');
    } catch (_) {
      if (fallbackToLocalCover && sourceKey != null && cid != null) {
        final localComic = LocalManager().find(
          cid!,
          ComicType.fromKey(sourceKey!),
        );
        if (localComic != null) {
          final file = localComic.coverFile;
          if (await file.exists()) {
            final data = await file.readAsBytes();
            if (data.isNotEmpty) return data;
          }
        }
      }
      rethrow;
    } finally {
      loadingCount--;
    }
  }

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => url + (sourceKey ?? '') + (cid ?? '');
}
