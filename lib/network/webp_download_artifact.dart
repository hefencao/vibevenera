import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';

typedef WebPArtifactPromoter = Future<File> Function(File source);

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

  /// Restores only the range not already present in the native source.
  /// The same writer capability is used for restore and live network bytes, so
  /// cancellation cannot introduce a second authoritative writer.
  Future<void> restore(
    DownloadSession session,
    DownloadWriterLease writer,
  ) async {
    if (_initialized) throw StateError('WebP artifact is already initialized');
    _initialized = true;
    final exists = await file.exists();
    _length = exists ? await file.length() : 0;
    final committed = session.committedLength;
    if (committed > _length) {
      // The process-local native source cannot be reconstructed from a shorter
      // durable artifact. Reset both sides and resume from zero instead of
      // leaving the session permanently failed.
      await reset();
      session.resetSource(
        writer: writer,
        epoch: session.source.epoch + 1,
        expectedLength: session.expectedLength,
      );
      return;
    }
    if (_length == committed) return;

    var offset = committed;
    await for (final chunk in file.openRead(committed)) {
      if (!writer.active) throw StateError('WebP writer became stale on restore');
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      session.append(bytes, offset: offset, writer: writer);
      offset += bytes.length;
    }
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

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
  }
}
