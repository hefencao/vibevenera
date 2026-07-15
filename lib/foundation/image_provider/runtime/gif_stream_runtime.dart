import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/foundation/log.dart';

import 'gif_stream_index.dart';

final class GifCodecBuild {
  final ui.Codec codec;
  final int frameCount;
  final int epoch;

  const GifCodecBuild(this.codec, this.frameCount, this.epoch);
}

/// GIF-specific incremental artifact reader, container index and codec builder.
///
/// It deliberately does not own presentation timing or an active codec. Those
/// belong to the ImageStream adapter, while transport/session ownership stays
/// below this runtime.
final class GifStreamRuntime {
  final int targetWidth;
  final int targetHeight;
  final DownloadSessionSnapshot? Function() currentDownload;
  final Future<void> Function() onUpdated;
  final void Function(Object error, StackTrace stack) onError;

  GifStreamIndexer? _indexer;
  DownloadSessionSnapshot? _pendingSnapshot;
  bool _advancing = false;
  bool _codecBuilding = false;
  bool _disposed = false;
  bool _final = false;
  bool _trailerSeen = false;
  int? _epoch;
  int _readOffset = 0;
  int _availableOffset = 0;
  int _availableFrames = 0;
  int _width = 0;
  int _height = 0;
  int _rejectedOffset = -1;
  File? _artifactFile;

  GifStreamRuntime({
    required this.targetWidth,
    required this.targetHeight,
    required this.currentDownload,
    required this.onUpdated,
    required this.onError,
  });

  bool get hasFrames => _availableFrames > 0;
  bool get isFinal => _final;
  int get availableFrames => _availableFrames;
  int get availableOffset => _availableOffset;
  int? get epoch => _epoch;
  bool get canBuild =>
      !_codecBuilding &&
      _artifactFile != null &&
      _availableOffset > 0 &&
      (_final || _availableOffset != _rejectedOffset);

  void addSnapshot(DownloadSessionSnapshot snapshot) {
    if (_disposed) return;
    _pendingSnapshot = snapshot;
    if (!_advancing) unawaited(_drainSnapshots());
  }

  void dispose() {
    _disposed = true;
    _pendingSnapshot = null;
    _indexer = null;
    _artifactFile = null;
  }

  Future<void> _drainSnapshots() async {
    if (_advancing || _disposed) return;
    _advancing = true;
    try {
      while (!_disposed && _pendingSnapshot != null) {
        final snapshot = _pendingSnapshot!;
        _pendingSnapshot = null;
        await _advance(snapshot);
      }
    } catch (error, stack) {
      onError(error, stack);
    } finally {
      _advancing = false;
      if (!_disposed && _pendingSnapshot != null) unawaited(_drainSnapshots());
    }
  }

  Future<void> _advance(DownloadSessionSnapshot download) async {
    final epoch = download.sourceEpoch;
    if (_epoch != epoch) {
      _epoch = epoch;
      _indexer = GifStreamIndexer();
      _readOffset = 0;
      _availableOffset = 0;
      _availableFrames = 0;
      _width = 0;
      _height = 0;
      _rejectedOffset = -1;
      _trailerSeen = false;
      _final = false;
    }

    final target = download.committedLength;
    final file = await _resolveArtifact(download);
    if (file == null) return;
    _artifactFile = file;
    if (target > _readOffset) {
      final raf = await file.open(mode: FileMode.read);
      try {
        final length = await raf.length();
        if (length < target) {
          throw StateError(
            'GIF artifact is behind session: file=$length session=$target',
          );
        }
        await raf.setPosition(_readOffset);
        while (_readOffset < target) {
          final remaining = target - _readOffset;
          final bytes = await raf.read(math.min(256 * 1024, remaining));
          if (bytes.isEmpty) {
            throw StateError('GIF artifact ended at $_readOffset/$target');
          }
          _indexer!.add(bytes);
          _readOffset += bytes.length;
        }
      } finally {
        await raf.close();
      }
    }

    final indexed = _indexer!.snapshot;
    final previousFrames = _availableFrames;
    _availableFrames = indexed.frameCount;
    _availableOffset = indexed.completeOffset;
    _width = indexed.width;
    _height = indexed.height;
    _trailerSeen = indexed.trailerSeen;
    _final =
        download.transport == DownloadTransportState.sealed &&
        indexed.trailerSeen;
    if (_availableFrames != previousFrames) {
      Log.info(
        'GIF.Stream',
        'indexed frames=$_availableFrames bytes=$_availableOffset '
            'downloaded=$target final=$_final',
      );
    }
    if (_availableFrames > 0) await onUpdated();
  }

  Future<File?> _resolveArtifact(DownloadSessionSnapshot requested) async {
    final file = requested.artifactFile!;
    if (await file.exists()) return file;
    final current = currentDownload();
    final handoff = current?.artifactFile;
    if (current != null &&
        current.contentKind == DownloadContentKind.gif &&
        current.sourceEpoch == requested.sourceEpoch &&
        current.committedLength >= requested.committedLength &&
        handoff != null &&
        await handoff.exists()) {
      return handoff;
    }
    if (current?.transport != DownloadTransportState.sealed) return null;
    throw StateError('GIF artifact missing after promotion: ${file.path}');
  }

  Future<GifCodecBuild?> buildCodec({required int skipFrames}) async {
    if (!canBuild || _disposed) return null;
    _codecBuilding = true;
    final file = _artifactFile!;
    final frameCount = _availableFrames;
    final completeOffset = _availableOffset;
    final trailerSeen = _trailerSeen;
    final epoch = _epoch!;
    final stopwatch = Stopwatch()..start();
    ui.Codec? codec;
    try {
      final bytes = Uint8List(completeOffset + (trailerSeen ? 0 : 1));
      final raf = await file.open(mode: FileMode.read);
      try {
        var offset = 0;
        while (offset < completeOffset) {
          final read = await raf.readInto(bytes, offset, completeOffset);
          if (read == 0) {
            throw StateError('GIF snapshot ended at $offset/$completeOffset');
          }
          offset += read;
        }
      } finally {
        await raf.close();
      }
      if (!trailerSeen) bytes[completeOffset] = 0x3b;
      final (width, height) = _targetSize();
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: width,
        targetHeight: height,
        allowUpscaling: false,
      );
      if (codec.frameCount != frameCount) {
        throw StateError(
          'GIF codec/index frame mismatch: ${codec.frameCount}/$frameCount',
        );
      }
      final skipWatch = Stopwatch()..start();
      for (var i = 0; i < skipFrames; i++) {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      }
      skipWatch.stop();
      if (_disposed || epoch != _epoch) {
        codec.dispose();
        return null;
      }
      Log.warning(
        'GIF.Stream',
        'codec frames=$frameCount bytes=${bytes.length} skip=$skipFrames '
            'build=${stopwatch.elapsedMilliseconds}ms '
            'skipMs=${skipWatch.elapsedMilliseconds}',
      );
      return GifCodecBuild(codec, frameCount, epoch);
    } catch (error) {
      codec?.dispose();
      if (!_final) {
        _rejectedOffset = completeOffset;
        Log.warning(
          'GIF.Stream',
          'partial codec rejected frames=$frameCount bytes=$completeOffset: $error',
        );
        return null;
      }
      rethrow;
    } finally {
      _codecBuilding = false;
    }
  }

  (int?, int?) _targetSize() {
    if (_width <= 0 ||
        _height <= 0 ||
        targetWidth <= 0 ||
        targetHeight <= 0) {
      return (null, null);
    }
    final scale = math.min(targetWidth / _width, targetHeight / _height);
    if (scale >= 1) return (null, null);
    return (
      math.max(1, (_width * scale).round()),
      math.max(1, (_height * scale).round()),
    );
  }
}
