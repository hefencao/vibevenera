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

  Future<void> restore(DownloadSession session) async {
    if (_initialized) throw StateError('WebP artifact is already initialized');
    _initialized = true;
    final exists = await file.exists();
    _length = exists ? await file.length() : 0;
    final committed = session.source.state.committedLength;
    if (committed > _length) {
      throw StateError('WebP artifact is behind source: $_length/$committed');
    }
    if (_length == committed) return;
    await for (final chunk in file.openRead(committed)) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      session.append(bytes, offset: session.source.state.committedLength);
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

  Future<void> flush() => _sink?.flush() ?? Future.value();

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
    final file = await _promote(this.file);
    _promoted = true;
    return file;
  }

  Future<void> close() => _closeSink();

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
  }
}
