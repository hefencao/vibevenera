import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';

typedef WebPArtifactPromoter = Future<File> Function(File source);

enum WebPArtifactContentKind { empty, unknown, webp, fallback }

final class WebPArtifactRestoreState {
  final WebPArtifactContentKind kind;
  final int length;
  final Uint8List prefix;
  final bool sourceContainsPrefix;

  const WebPArtifactRestoreState({
    required this.kind,
    required this.length,
    required this.prefix,
    this.sourceContainsPrefix = false,
  });
}

final class WebPDownloadArtifact {
  final File file;
  final WebPArtifactPromoter _promote;
  IOSink? _sink;
  int _length = 0;
  bool _initialized = false;
  bool _promoted = false;

  WebPDownloadArtifact(this.file, {required WebPArtifactPromoter promote})
      : _promote = promote;

  factory WebPDownloadArtifact.forCacheKey(String cacheKey) {
    final name = md5.convert(cacheKey.codeUnits).toString();
    return WebPDownloadArtifact(
      File('${CacheManager.cachePath}_partial/$name'),
      promote: (file) => CacheManager().promoteFile(cacheKey, file),
    );
  }

  int get length => _length;
  bool get isPromoted => _promoted;

  /// Restores the authoritative range already persisted for this identity.
  ///
  /// WebP bytes are replayed only when reconstructing a process-local native
  /// source after process/session creation. A retained native source at the
  /// same committed offset is never replayed. Generic fallback content remains
  /// artifact-owned and restores only its contiguous length.
  Future<WebPArtifactRestoreState> restore(
    DownloadSession session,
    DownloadWriterLease writer, {
    void Function()? checkCancelled,
  }) async {
    if (_initialized) throw StateError('WebP artifact is already initialized');
    checkCancelled?.call();
    _initialized = true;
    final exists = await file.exists();
    _length = exists ? await file.length() : 0;
    checkCancelled?.call();
    if (_length == 0) {
      return WebPArtifactRestoreState(
        kind: WebPArtifactContentKind.empty,
        length: 0,
        prefix: Uint8List(0),
      );
    }

    final prefix = await _readPrefix();
    checkCancelled?.call();
    final kind = classifyPrefix(prefix, completeLength: _length);

    if (kind == WebPArtifactContentKind.fallback) {
      session.enterFallbackContent(writer, restoredLength: _length);
      return WebPArtifactRestoreState(
        kind: kind,
        length: _length,
        prefix: prefix,
      );
    }

    if (kind == WebPArtifactContentKind.unknown) {
      final sourceLength = session.sourceCommittedLength;
      final mustReset = session.fallbackContent ||
          (sourceLength != 0 && sourceLength != _length);
      if (mustReset) {
        session.resetSource(
          writer: writer,
          epoch: session.source.epoch + 1,
          expectedLength: session.expectedLength,
        );
      }
      final sourceContainsPrefix = !mustReset &&
          !session.fallbackContent &&
          session.sourceCommittedLength == _length;
      return WebPArtifactRestoreState(
        kind: kind,
        length: _length,
        prefix: prefix,
        sourceContainsPrefix: sourceContainsPrefix,
      );
    }

    if (session.fallbackContent || session.sourceCommittedLength > _length) {
      session.resetSource(
        writer: writer,
        epoch: session.source.epoch + 1,
        expectedLength: session.expectedLength,
      );
    }

    final committed = session.sourceCommittedLength;
    if (committed < _length) {
      var offset = committed;
      await for (final chunk in file.openRead(committed)) {
        checkCancelled?.call();
        if (!writer.active) {
          throw StateError('WebP writer became stale during artifact restore');
        }
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        session.append(bytes, offset: offset, writer: writer);
        offset += bytes.length;
        checkCancelled?.call();
      }
    }

    return WebPArtifactRestoreState(
      kind: kind,
      length: _length,
      prefix: prefix,
      sourceContainsPrefix: true,
    );
  }

  Future<void> append(Uint8List bytes, {required int offset}) async {
    if (!_initialized) throw StateError('WebP artifact is not initialized');
    if (_promoted) throw StateError('WebP artifact is already promoted');
    if (offset != _length) {
      throw StateError('WebP artifact offset mismatch: $offset/$_length');
    }
    if (bytes.isEmpty) return;
    await file.parent.create(recursive: true);
    (_sink ??= file.openWrite(mode: FileMode.append)).add(bytes);
    _length += bytes.length;
  }

  Future<void> flush() => _sink?.flush() ?? Future<void>.value();

  Future<void> reset() async {
    if (!_initialized) throw StateError('WebP artifact is not initialized');
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

  Future<File> promote({required int sealedLength}) async {
    if (!_initialized) throw StateError('WebP artifact is not initialized');
    if (_length != sealedLength) {
      throw StateError(
        'WebP artifact final length mismatch: $_length/$sealedLength',
      );
    }
    await _closeSink();
    final promoted = await _promote(file);
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

  static WebPArtifactContentKind classifyPrefix(
    Uint8List prefix, {
    required int completeLength,
  }) {
    if (completeLength == 0) return WebPArtifactContentKind.empty;
    if (prefix.length < 12) return WebPArtifactContentKind.unknown;
    final isRiff = prefix[0] == 0x52 &&
        prefix[1] == 0x49 &&
        prefix[2] == 0x46 &&
        prefix[3] == 0x46;
    final isWebP = prefix[8] == 0x57 &&
        prefix[9] == 0x45 &&
        prefix[10] == 0x42 &&
        prefix[11] == 0x50;
    return isRiff && isWebP
        ? WebPArtifactContentKind.webp
        : WebPArtifactContentKind.fallback;
  }
}
