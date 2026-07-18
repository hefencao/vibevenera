import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/network/images.dart';

import 'models.dart';
import 'store.dart';

final class ResolvedComicTranslationInput {
  final File file;
  final int size;
  final int modifiedMilliseconds;
  final String contentDigest;
  final ComicTranslationMediaKind mediaKind;

  const ResolvedComicTranslationInput({
    required this.file,
    required this.size,
    required this.modifiedMilliseconds,
    required this.contentDigest,
    required this.mediaKind,
  });
}

final class ComicTranslationInputResolver {
  const ComicTranslationInputResolver();

  static final Map<String, Future<String>> _digestTasks = {};

  Future<ResolvedComicTranslationInput?> resolve(
    ComicTranslationPageIdentity identity,
  ) async {
    final file = await _findFile(identity);
    if (file == null) return null;
    for (var attempt = 0; attempt < 2; attempt++) {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      final modified = stat.modified.millisecondsSinceEpoch;
      final mediaKind =
          identity.mediaKind == ComicTranslationMediaKind.animatedImage
              ? ComicTranslationMediaKind.animatedImage
              : await Isolate.run(() => _detectMediaKind(file.path));
      var digest = await ComicTranslationStore.instance.findContentDigest(
        identity: identity,
        fileSize: stat.size,
        fileModified: modified,
      );
      digest ??= await _digest(file, stat.size, modified);
      final verified = await file.stat();
      final verifiedModified = verified.modified.millisecondsSinceEpoch;
      if (verified.size != stat.size || verifiedModified != modified) {
        continue;
      }
      await ComicTranslationStore.instance.storeContentDigest(
        identity: identity,
        fileSize: stat.size,
        fileModified: modified,
        contentDigest: digest,
      );
      return ResolvedComicTranslationInput(
        file: file,
        size: stat.size,
        modifiedMilliseconds: modified,
        contentDigest: digest,
        mediaKind: mediaKind,
      );
    }
    throw StateError('Comic image changed while preparing translation input');
  }

  Future<File?> _findFile(ComicTranslationPageIdentity identity) async {
    if (identity.imageKey.startsWith('file://')) {
      final file = File.fromUri(Uri.parse(identity.imageKey));
      return await file.exists() ? file : null;
    }
    var file = await ImageDownloader.findCachedComicImageFile(
      identity.imageKey,
      identity.sourceKey,
      identity.comicId,
      identity.chapterId,
    );
    if (file != null) return file;
    final alias = CacheManager().resolveImageAlias(
      identity.imageKey,
      identity.sourceKey,
      identity.comicId,
      identity.chapterId,
    );
    if (alias == null) return null;
    return ImageDownloader.findCachedComicImageFile(
      alias.imageKey,
      alias.sourceKey,
      alias.cid,
      alias.eid,
    );
  }

  static Future<String> _digest(File file, int size, int modified) {
    final key = '${file.path}\u0000$size\u0000$modified';
    final existing = _digestTasks[key];
    if (existing != null) return existing;
    late final Future<String> task;
    task = Isolate.run(() async =>
        (await sha256.bind(File(file.path).openRead()).first).toString())
      .whenComplete(() {
        if (identical(_digestTasks[key], task)) _digestTasks.remove(key);
      });
    _digestTasks[key] = task;
    return task;
  }
}

ComicTranslationMediaKind _detectMediaKind(String path) {
  final file = File(path).openSync();
  try {
    final length = file.lengthSync();
    if (length < 6) return ComicTranslationMediaKind.staticImage;
    final header = file.readSync(_minInt(12, length));
    final signature = String.fromCharCodes(header.take(6));
    if (signature == 'GIF87a' || signature == 'GIF89a') {
      return ComicTranslationMediaKind.animatedImage;
    }
    if (header.length < 12 ||
        String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(header.sublist(8, 12)) != 'WEBP') {
      return ComicTranslationMediaKind.staticImage;
    }
    var offset = 12;
    while (offset + 8 <= length) {
      file.setPositionSync(offset);
      final chunk = file.readSync(8);
      if (chunk.length < 8) break;
      final type = String.fromCharCodes(chunk.sublist(0, 4));
      final size = ByteData.sublistView(chunk, 4).getUint32(0, Endian.little);
      final dataStart = offset + 8;
      if (size > length - dataStart) break;
      if (type == 'ANIM' || type == 'ANMF') {
        return ComicTranslationMediaKind.animatedImage;
      }
      if (type == 'VP8X' && size > 0) {
        file.setPositionSync(dataStart);
        final flags = file.readByteSync();
        if ((flags & 0x02) != 0) {
          return ComicTranslationMediaKind.animatedImage;
        }
      }
      offset = dataStart + size + (size.isOdd ? 1 : 0);
    }
    return ComicTranslationMediaKind.staticImage;
  } finally {
    file.closeSync();
  }
}

int _minInt(int a, int b) => a < b ? a : b;
