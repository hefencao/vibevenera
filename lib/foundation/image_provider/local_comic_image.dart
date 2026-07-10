import 'dart:async' show Future;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';

import 'base_image.dart';
import 'io/image_data_validator.dart';

class LocalComicImageProvider
    extends BaseImageProvider<LocalComicImageProvider> {
  const LocalComicImageProvider(this.comic);

  final LocalComic comic;

  static const Set<String> _supportedExtensions = <String>{
    '.jpg', '.jpeg', '.jpe', '.png', '.webp', '.gif', '.bmp', '.avif', '.heic', '.heif',
  };

  bool _isImageFile(String? extension) {
    if (extension == null) return false;
    return _supportedExtensions.contains(extension.toLowerCase());
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    File? file = comic.coverFile;

    if (!await file.exists()) {
      file = await _findFallbackCover();
    }

    if (file == null) {
      throw StateError('Cover not found: ${comic.directory}');
    }

    checkStop();
    final data = await file.readAsBytes();
    checkStop();

    if (data.isEmpty) {
      throw StateError('Empty image file: ${file.path}');
    }

    final validation = ImageDataValidator.validateBytes(data);
    if (!validation.valid) {
      throw InvalidImageDataException(
        '${validation.reason}; path=${file.path}',
      );
    }

    return data;
  }

  Future<File?> _findFallbackCover() async {
    final root = Directory(comic.directory);
    if (!await root.exists()) {
      throw StateError('Comic not found: ${comic.directory}');
    }

    Directory? firstDirectory;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File && _isImageFile(entity.extension)) {
        return entity;
      }
      if (entity is Directory) {
        firstDirectory ??= entity;
      }
    }

    final directory = firstDirectory;
    if (directory == null) return null;

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && _isImageFile(entity.extension)) {
        return entity;
      }
    }
    return null;
  }

  @override
  Future<LocalComicImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<LocalComicImageProvider>(this);

  @override
  String get key => 'local${comic.id}${comic.comicType.value}';
}
