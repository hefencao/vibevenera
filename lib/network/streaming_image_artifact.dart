import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/io/image_data_validator.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';

typedef StreamingArtifactPromoter = Future<File> Function(File source);

enum StreamingArtifactContentKind { empty, unknown, webp, gif, fallback }

final class StreamingArtifactRestoreState {
  final StreamingArtifactContentKind kind;
  final int length;
  final Uint8List prefix;
  final bool sourceContainsPrefix;
  final int? declaredLength;
  final bool complete;

  const StreamingArtifactRestoreState({
    required this.kind,
    required this.length,
    required this.prefix,
    this.sourceContainsPrefix = false,
    this.declaredLength,
    this.complete = false,
  });
}

final class StreamingImageArtifact {
  final File file;
  final StreamingArtifactPromoter _promote;
  IOSink? _sink;
  int _length = 0;
  bool _initialized = false;
  bool _promoted = false;

  StreamingImageArtifact(this.file, {required StreamingArtifactPromoter promote})
    : _promote = promote;

  factory StreamingImageArtifact.forCacheKey(String cacheKey) {
    final name = md5.convert(cacheKey.codeUnits).toString();
    return StreamingImageArtifact(
      File('${CacheManager.cachePath}_partial/$name'),
      promote: (file) => CacheManager().promoteFile(cacheKey, file),
    );
  }

  int get length => _length;
  bool get isPromoted => _promoted;

  /// Restores the authoritative contiguous range already persisted.
  ///
  /// A retained native source at the same offset is not replayed. A process-
  /// local source recreated after restart is rebuilt once from the artifact.
  Future<StreamingArtifactRestoreState> restore(
    DownloadSession session,
    DownloadWriterLease writer, {
    void Function()? checkCancelled,
  }) async {
    if (_initialized) throw StateError('Streaming image artifact is already initialized');
    checkCancelled?.call();
    _initialized = true;
    _length = await file.exists() ? await file.length() : 0;
    checkCancelled?.call();

    if (_length == 0) {
      return StreamingArtifactRestoreState(
        kind: StreamingArtifactContentKind.empty,
        length: 0,
        prefix: Uint8List(0),
      );
    }

    final prefix = await _readPrefix();
    checkCancelled?.call();
    final kind = classifyPrefix(prefix, completeLength: _length);
    final declaredLength = kind == StreamingArtifactContentKind.webp
        ? ImageDataValidator.webPDeclaredLength(prefix)
        : null;

    if (declaredLength != null) {
      if (_length > declaredLength) {
        // The file contains an overlap/old response tail. It cannot be repaired
        // by trimming because its source identity/validator is unknown.
        await reset();
        session.resetSource(
          writer: writer,
          epoch: session.sourceEpoch + 1,
          expectedLength: 0,
        );
        return StreamingArtifactRestoreState(
          kind: StreamingArtifactContentKind.empty,
          length: 0,
          prefix: Uint8List(0),
        );
      }
      session.updateExpectedLength(
        declaredLength,
        writer: writer,
        authoritative: true,
      );
    }

    if (kind == StreamingArtifactContentKind.gif ||
        kind == StreamingArtifactContentKind.fallback) {
      session.enterExternalContent(
        writer,
        restoredLength: _length,
        contentKind: kind == StreamingArtifactContentKind.gif
            ? DownloadContentKind.gif
            : DownloadContentKind.fallback,
      );
      return StreamingArtifactRestoreState(
        kind: kind,
        length: _length,
        prefix: prefix,
      );
    }

    if (kind == StreamingArtifactContentKind.unknown) {
      final sourceLength = session.sourceCommittedLength;
      final mustReset =
          session.externalContent ||
          (sourceLength != 0 && sourceLength != _length);
      if (mustReset) {
        session.resetSource(
          writer: writer,
          epoch: session.sourceEpoch + 1,
          expectedLength: 0,
        );
      }
      final sourceContainsPrefix =
          !mustReset &&
          !session.externalContent &&
          session.sourceCommittedLength == _length;
      return StreamingArtifactRestoreState(
        kind: kind,
        length: _length,
        prefix: prefix,
        sourceContainsPrefix: sourceContainsPrefix,
      );
    }

    if (session.externalContent || session.sourceCommittedLength > _length) {
      session.resetSource(
        writer: writer,
        epoch: session.sourceEpoch + 1,
        expectedLength: declaredLength ?? 0,
      );
      if (declaredLength != null) {
        session.updateExpectedLength(
          declaredLength,
          writer: writer,
          authoritative: true,
        );
      }
    }

    final committed = session.sourceCommittedLength;
    if (committed < _length) {
      var offset = committed;
      await for (final chunk in file.openRead(committed)) {
        checkCancelled?.call();
        if (!writer.active) {
          throw StateError('Download writer became stale during artifact restore');
        }
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        session.append(bytes, offset: offset, writer: writer);
        offset += bytes.length;
      }
    }

    final complete = declaredLength != null && _length == declaredLength;
    if (complete) {
      final validation = await ImageDataValidator.validateFile(file);
      if (!validation.valid) {
        await reset();
        session.resetSource(
          writer: writer,
          epoch: session.sourceEpoch + 1,
          expectedLength: 0,
        );
        return StreamingArtifactRestoreState(
          kind: StreamingArtifactContentKind.empty,
          length: 0,
          prefix: Uint8List(0),
        );
      }
    }

    return StreamingArtifactRestoreState(
      kind: kind,
      length: _length,
      prefix: prefix,
      sourceContainsPrefix: true,
      declaredLength: declaredLength,
      complete: complete,
    );
  }

  Future<void> append(Uint8List bytes, {required int offset}) async {
    if (!_initialized) throw StateError('Streaming image artifact is not initialized');
    if (_promoted) throw StateError('Streaming image artifact is already promoted');
    if (offset != _length) {
      throw StateError('Streaming image artifact offset mismatch: $offset/$_length');
    }
    if (bytes.isEmpty) return;
    await file.parent.create(recursive: true);
    (_sink ??= file.openWrite(mode: FileMode.append)).add(bytes);
    _length += bytes.length;
  }

  Future<void> flush() => _sink?.flush() ?? Future<void>.value();

  Future<void> reset() async {
    if (!_initialized) throw StateError('Streaming image artifact is not initialized');
    await _closeSink();
    if (await file.exists()) await file.delete();
    _length = 0;
    _promoted = false;
  }

  Future<void> discard() async {
    if (!_initialized) {
      _initialized = true;
      _length = await file.exists() ? await file.length() : 0;
    }
    await reset();
  }

  /// Validates the durable file before it becomes the shared final cache.
  Future<File> promote({required int sealedLength}) async {
    if (!_initialized) throw StateError('Streaming image artifact is not initialized');
    if (_length != sealedLength) {
      throw StateError(
        'Streaming image artifact final length mismatch: $_length/$sealedLength',
      );
    }
    await _closeSink();

    final validation = await ImageDataValidator.validateFile(file);
    if (!validation.valid) {
      throw InvalidImageDataException(
        'artifact ${file.path}: ${validation.reason}',
      );
    }

    final promoted = await _promote(file);
    final promotedValidation = await ImageDataValidator.validateFile(promoted);
    if (!promotedValidation.valid) {
      try {
        await promoted.delete();
      } on FileSystemException {
        // Best effort cleanup.
      }
      throw InvalidImageDataException(
        'promoted cache ${promoted.path}: ${promotedValidation.reason}',
      );
    }
    _promoted = true;
    return promoted;
  }

  Future<void> close() => _closeSink();

  Future<Uint8List> _readPrefix() async {
    final count = _length < 12 ? _length : 12;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, count)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
  }

  static StreamingArtifactContentKind classifyPrefix(
    Uint8List prefix, {
    required int completeLength,
  }) {
    if (completeLength == 0) return StreamingArtifactContentKind.empty;
    if (prefix.length < 12) return StreamingArtifactContentKind.unknown;
    final isRiff =
        prefix[0] == 0x52 &&
        prefix[1] == 0x49 &&
        prefix[2] == 0x46 &&
        prefix[3] == 0x46;
    final isWebP =
        prefix[8] == 0x57 &&
        prefix[9] == 0x45 &&
        prefix[10] == 0x42 &&
        prefix[11] == 0x50;
    if (isRiff && isWebP) return StreamingArtifactContentKind.webp;
    final isGif =
        prefix[0] == 0x47 &&
        prefix[1] == 0x49 &&
        prefix[2] == 0x46 &&
        prefix[3] == 0x38 &&
        (prefix[4] == 0x37 || prefix[4] == 0x39) &&
        prefix[5] == 0x61;
    return isGif
        ? StreamingArtifactContentKind.gif
        : StreamingArtifactContentKind.fallback;
  }
}
