import 'dart:async' show Future;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';

import 'base_image.dart';
import 'io/atomic_image_file.dart';
import 'io/image_data_validator.dart';

class LocalFavoriteImageProvider
    extends BaseImageProvider<LocalFavoriteImageProvider> {
  const LocalFavoriteImageProvider(this.url, this.id, this.intKey);

  final String url;
  final String id;
  final int intKey;

  static File _cacheFile(String id, int intKey) {
    final fileName = (id + intKey.toString()).hashCode.toString();
    return File(FilePath.join(App.dataPath, 'favorite_cover', fileName));
  }

  static Future<void> delete(String id, int intKey) async {
    final file = _cacheFile(id, intKey);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    final sourceKey = ComicSource.fromIntKey(intKey)?.key;
    final file = _cacheFile(id, intKey);
    final cached = await readValidImageFile(file);
    if (cached != null) return cached;

    checkStop();
    await for (final progress in ImageDownloader.loadThumbnail(
      url,
      sourceKey,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      final data = progress.imageBytes;
      if (data == null) continue;
      final validation = ImageDataValidator.validateBytes(data);
      if (!validation.valid) {
        throw InvalidImageDataException(validation.reason);
      }
      await writeImageBytesAtomically(file, data);
      return data;
    }
    throw Exception('Empty response body');
  }

  @override
  Future<void> evictInvalidCache() => delete(id, intKey);

  @override
  Future<LocalFavoriteImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture(this);

  @override
  String get key => id + intKey.toString();
}
