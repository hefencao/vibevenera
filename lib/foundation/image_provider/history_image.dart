import 'dart:async' show Future;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';

import '../history.dart';
import 'base_image.dart';
import 'io/image_data_validator.dart';

class HistoryImageProvider extends BaseImageProvider<HistoryImageProvider> {
  const HistoryImageProvider(this.history);

  final History history;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;
    if (!url.contains('/')) {
      final localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) return localComic.coverFile.readAsBytes();

      final comicSource =
          history.type.comicSource ??
          (throw Exception('Comic source not found'));
      final comic = await comicSource.loadComicInfo!(history.id);
      checkStop();
      url = comic.data.cover;
      history.cover = url;
      HistoryManager().addHistory(history);
    }

    await for (final progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
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
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => 'history${history.id}${history.type.value}';
}
