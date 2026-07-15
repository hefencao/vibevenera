part of 'streaming_image_transport.dart';

final class _StreamingImageIngress {
  final DownloadSession session;
  final DownloadWriterLease writer;
  final StreamingImageArtifact artifact;

  StreamingArtifactContentKind _kind;
  Uint8List _pendingPrefix;
  bool _sourceContainsPrefix;
  int _receivedLength;
  int _publishedFallbackLength;
  int _lastGifPublishMs = 0;

  static const int _gifPublishBytes = 64 * 1024;
  static const int _gifPublishIntervalMs = 50;

  _StreamingImageIngress({
    required this.session,
    required this.writer,
    required this.artifact,
    required StreamingArtifactRestoreState restored,
  })  : _kind = restored.kind,
        _pendingPrefix = restored.kind == StreamingArtifactContentKind.unknown
            ? restored.prefix
            : Uint8List(0),
        _sourceContainsPrefix = restored.sourceContainsPrefix,
        _receivedLength = restored.length,
        _publishedFallbackLength = restored.length;

  _StreamingImageIngress.empty({
    required this.session,
    required this.writer,
    required this.artifact,
  })  : _kind = StreamingArtifactContentKind.empty,
        _pendingPrefix = Uint8List(0),
        _sourceContainsPrefix = false,
        _receivedLength = 0,
        _publishedFallbackLength = 0;

  int get receivedLength => _receivedLength;
  bool get isFallback =>
      _kind == StreamingArtifactContentKind.gif ||
      _kind == StreamingArtifactContentKind.fallback;

  Future<void> append(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    if (!writer.active) {
      throw const StreamingTransportCancelled('stale writer');
    }

    final offset = _receivedLength;
    await artifact.append(bytes, offset: offset);

    // Cancellation can arrive while the disk append is pending. In that case
    // leave the durable artifact one chunk ahead and let the next writer's
    // artifact.restore reconcile the exact committed prefix into the source.
    if (!writer.active) {
      throw const StreamingTransportCancelled('stale writer');
    }

    _receivedLength += bytes.length;

    switch (_kind) {
      case StreamingArtifactContentKind.webp:
        session.append(bytes, offset: offset, writer: writer);
        return;
      case StreamingArtifactContentKind.gif:
        final now = DateTime.now().millisecondsSinceEpoch;
        if (_receivedLength - _publishedFallbackLength >= _gifPublishBytes ||
            now - _lastGifPublishMs >= _gifPublishIntervalMs) {
          await _publishGifRange(now);
        }
        return;
      case StreamingArtifactContentKind.fallback:
        session.appendExternalRange(
          writer,
          offset: offset,
          length: bytes.length,
        );
        return;
      case StreamingArtifactContentKind.empty:
      case StreamingArtifactContentKind.unknown:
        await _classifyAndCommit(bytes, priorOffset: offset);
        return;
    }
  }

  Future<void> finalizeContent({required int finalLength}) async {
    if (!writer.active) {
      throw const StreamingTransportCancelled('stale writer');
    }
    if (finalLength != _receivedLength) {
      throw DownloadSourceInvariantError(
        'final length $finalLength does not match ingress $_receivedLength',
      );
    }

    if (_kind == StreamingArtifactContentKind.empty ||
        _kind == StreamingArtifactContentKind.unknown) {
      // Fewer than 12 bytes cannot contain a RIFF/WEBP signature. Preserve the
      // payload through the ordinary Flutter fallback path rather than trying
      // to append it to the native WebP source.
      session.enterExternalContent(
        writer,
        restoredLength: _receivedLength,
      );
      _kind = StreamingArtifactContentKind.fallback;
      _pendingPrefix = Uint8List(0);
      _sourceContainsPrefix = false;
    } else if (_kind == StreamingArtifactContentKind.gif) {
      await _publishGifRange(DateTime.now().millisecondsSinceEpoch);
    }
  }

  Future<void> _publishGifRange(int now) async {
    final length = _receivedLength - _publishedFallbackLength;
    if (length <= 0) return;
    await artifact.flush();
    session.appendExternalRange(
      writer,
      offset: _publishedFallbackLength,
      length: length,
    );
    _publishedFallbackLength = _receivedLength;
    _lastGifPublishMs = now;
  }

  Future<void> _classifyAndCommit(
    Uint8List bytes, {
    required int priorOffset,
  }) async {
    final oldPrefix = _pendingPrefix;
    final headerLength = oldPrefix.length + bytes.length;

    if (headerLength < 12) {
      final next = Uint8List(headerLength)
        ..setRange(0, oldPrefix.length, oldPrefix)
        ..setRange(oldPrefix.length, headerLength, bytes);
      _pendingPrefix = next;
      _kind = StreamingArtifactContentKind.unknown;
      return;
    }

    final header = Uint8List(12);
    final prefixCopy = oldPrefix.length < 12 ? oldPrefix.length : 12;
    if (prefixCopy > 0) {
      header.setRange(0, prefixCopy, oldPrefix);
    }

    final remaining = 12 - prefixCopy;
    if (remaining > 0) {
      header.setRange(prefixCopy, 12, bytes, 0);
    }

    final classified = StreamingImageArtifact.classifyPrefix(
      header,
      completeLength: _receivedLength,
    );

    if (classified == StreamingArtifactContentKind.gif ||
        classified == StreamingArtifactContentKind.fallback) {
      if (classified == StreamingArtifactContentKind.gif) await artifact.flush();
      session.enterExternalContent(
        writer,
        restoredLength: _receivedLength,
        contentKind: classified == StreamingArtifactContentKind.gif
            ? DownloadContentKind.gif
            : DownloadContentKind.fallback,
      );
      _publishedFallbackLength = _receivedLength;
      _lastGifPublishMs = DateTime.now().millisecondsSinceEpoch;
      _kind = classified;
      _pendingPrefix = Uint8List(0);
      _sourceContainsPrefix = false;
      return;
    }

    if (!_sourceContainsPrefix && oldPrefix.isNotEmpty) {
      session.append(oldPrefix, offset: 0, writer: writer);
    }

    session.append(
      bytes,
      offset: session.sourceCommittedLength,
      writer: writer,
    );
    session.identifyWebPContent(writer);

    _kind = StreamingArtifactContentKind.webp;
    _pendingPrefix = Uint8List(0);
    _sourceContainsPrefix = true;

    if (session.sourceCommittedLength != _receivedLength) {
      throw DownloadSourceInvariantError(
        'classified WebP source length ${session.sourceCommittedLength} '
        'does not match artifact $_receivedLength (prior=$priorOffset)',
      );
    }
  }
}
