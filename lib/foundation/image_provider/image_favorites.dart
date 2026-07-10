import 'dart:async' show Future, StreamController;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';

import '../history.dart';
import 'base_image.dart';
import 'io/atomic_image_file.dart';
import 'io/image_data_validator.dart';

class ImageFavoritesProvider extends BaseImageProvider<ImageFavoritesProvider> {
  const ImageFavoritesProvider(this.imageFavorite);

  final ImageFavorite imageFavorite;

  int get page => imageFavorite.page;
  String get sourceKey => imageFavorite.sourceKey;
  String get cid => imageFavorite.id;
  String get eid => imageFavorite.eid;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    var imageKey = imageFavorite.imageKey;

    final localImage = await getImageFromLocal();
    checkStop?.call();
    if (localImage != null) return localImage;

    final cacheImage = await readFromCache();
    checkStop?.call();
    if (cacheImage != null) return cacheImage;

    var refreshedImageKey = false;
    if (imageKey.isEmpty) {
      imageKey = await getImageKey();
      checkStop?.call();
      refreshedImageKey = true;
    }

    Uint8List image;
    try {
      image = await getImageFromNetwork(imageKey, chunkEvents, checkStop);
    } catch (_) {
      if (refreshedImageKey) rethrow;
      imageKey = await getImageKey();
      checkStop?.call();
      image = await getImageFromNetwork(imageKey, chunkEvents, checkStop);
    }

    await writeToCache(image);
    return image;
  }

  static String _providerKey(ImageFavorite favorite) =>
      'ImageFavorites ${favorite.imageKey}@${favorite.sourceKey}@'
      '${favorite.id}@${favorite.eid}@${favorite.page}';

  static File _cacheFile(ImageFavorite favorite) {
    final fileName = md5.convert(_providerKey(favorite).codeUnits).toString();
    return File(FilePath.join(App.cachePath, 'image_favorites', fileName));
  }

  Future<void> writeToCache(Uint8List image) =>
      writeImageBytesAtomically(_cacheFile(imageFavorite), image);

  Future<Uint8List?> readFromCache() =>
      readValidImageFile(_cacheFile(imageFavorite));

  static Future<void> deleteFromCache(ImageFavorite imageFavorite) async {
    final file = _cacheFile(imageFavorite);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> evictInvalidCache() => deleteFromCache(imageFavorite);

  Future<Uint8List?> getImageFromLocal() async {
    final type = ComicType.fromKey(sourceKey);
    final localComic = LocalManager().find(cid, type);
    if (localComic == null) return null;

    final epIndex = localComic.chapters?.ids.toList().indexOf(eid) ?? -1;
    if (epIndex == -1 && localComic.hasChapters) return null;

    final images = await LocalManager().getImages(cid, type, epIndex);
    final index = page - 1;
    if (index < 0 || index >= images.length) return null;

    final file = File(images[index]);
    if (!await file.exists()) return null;
    final data = await file.readAsBytes();
    return data.isEmpty ? null : data;
  }

  Future<Uint8List> getImageFromNetwork(
    String imageKey,
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    await for (final progress in ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      debugLabel: 'favorite',
    )) {
      checkStop?.call();
      if (chunkEvents != null && !chunkEvents.isClosed) {
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: progress.currentBytes,
            expectedTotalBytes: progress.totalBytes,
          ),
        );
      }
      final bytes = progress.imageBytes;
      if (bytes == null) continue;
      final validation = ImageDataValidator.validateBytes(bytes);
      if (!validation.valid) {
        throw InvalidImageDataException(validation.reason);
      }
      return bytes;
    }
    throw Exception('Empty response body');
  }

  Future<String> getImageKey() async {
    final comicSource = ComicSource.find(sourceKey);
    if (comicSource == null) throw Exception('Comic source not found');
    final response = await comicSource.loadComicPages!(cid, eid);
    final index = page - 1;
    if (index < 0 || index >= response.data.length) {
      throw RangeError.index(index, response.data, 'page');
    }
    return response.data[index];
  }

  @override
  Future<ImageFavoritesProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => _providerKey(imageFavorite);
}
