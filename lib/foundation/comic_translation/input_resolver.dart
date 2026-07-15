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

  Future<ResolvedComicTranslationInput?> resolve(
    ComicTranslationPageIdentity identity,
  ) async {
    final file = await _findFile(identity);
    if (file == null) return null;
    final stat = await file.stat();
    final mediaKind = identity.mediaKind == ComicTranslationMediaKind.animatedImage
        ? ComicTranslationMediaKind.animatedImage
        : await Isolate.run(() => _detectMediaKind(file.path));
    var digest = await ComicTranslationStore.instance.findContentDigest(
      identity: identity,
      fileSize: stat.size,
      fileModified: stat.modified.millisecondsSinceEpoch,
    );
    if (digest == null) {
      digest = await Isolate.run(() async =>
          (await sha256.bind(File(file.path).openRead()).first).toString());
      await ComicTranslationStore.instance.storeContentDigest(
        identity: identity,
        fileSize: stat.size,
        fileModified: stat.modified.millisecondsSinceEpoch,
        contentDigest: digest!,
      );
    }
    return ResolvedComicTranslationInput(
      file: file,
      size: stat.size,
      modifiedMilliseconds: stat.modified.millisecondsSinceEpoch,
      contentDigest: digest,
      mediaKind: mediaKind,
    );
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
}

ComicTranslationMediaKind _detectMediaKind(String path) {
  final file = File(path).openSync();
  try {
    final length = file.lengthSync();
    if (length < 6) return ComicTranslationMediaKind.staticImage;
    final header = file.readSync(12);
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
      final type = String.fromCharCodes(chunk.sublist(0, 4));
      final size = ByteData.sublistView(chunk, 4).getUint32(0, Endian.little);
      if (type == 'ANIM' || type == 'ANMF') {
        return ComicTranslationMediaKind.animatedImage;
      }
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    return ComicTranslationMediaKind.staticImage;
  } finally {
    file.closeSync();
  }
}
