part of '../webp_image_provider.dart';

/// ImageProvider adapter for the Phase 3 session pipeline.
///
/// It subscribes to an existing WebPDecodeSession/holder and never opens a
/// second network stream, never replays chunk history, and never owns the
/// NativeWebPSource.
final class _WebPSessionImageStreamCompleter extends ImageStreamCompleter
    with WidgetsBindingObserver {
  final WebPImageProvider _provider;
  final String _scopeId;

  WebPResourceLease? _lease;
  StreamSubscription<WebPFrameHolderSnapshot>? _holderSubscription;
  StreamSubscription<DownloadSessionSnapshot>? _downloadSubscription;
  StreamSubscription<WebPDecodeSessionSnapshot>? _decodeSubscription;

  bool _disposed = false;
  bool _pumpScheduled = false;
  bool _pumping = false;
  bool _fallbackStarted = false;
  bool _fallbackPumping = false;
  int _fallbackFramesEmitted = 0;
  ui.Codec? _fallbackCodec;
  bool _reportedTerminalError = false;

  _WebPSessionImageStreamCompleter(this._provider)
      : _scopeId = 'visible:${identityHashCode(_provider)}:'
            '${DateTime.now().microsecondsSinceEpoch}' {
    WidgetsBinding.instance.addObserver(this);
    scheduleMicrotask(_attach);
  }

  @override
  void addListener(ImageStreamListener listener) {
    super.addListener(listener);
    _schedulePump();
  }

  @override
  void onDisposed() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_holderSubscription?.cancel());
    unawaited(_downloadSubscription?.cancel());
    unawaited(_decodeSubscription?.cancel());
    _fallbackCodec?.dispose();
    _fallbackCodec = null;
    _lease?.detach();
    _lease = null;
    super.onDisposed();
  }

  @override
  void didChangeAppLifecycleState(ui.AppLifecycleState state) {
    if (state == ui.AppLifecycleState.resumed) _schedulePump();
  }

  void _attach() {
    if (_disposed) return;
    try {
      final lease = PipelineController.instance.acquireVisibleWebP(
        imageKey: _provider.imageKey,
        sourceKey: _provider.sourceKey,
        cid: _provider.cid,
        eid: _provider.eid,
        fullKey: _provider._fullKey,
        targetWidth: _provider.targetWidth,
        targetHeight: _provider.targetHeight,
        scopeId: _scopeId,
      );
      _lease = lease;
      _holderSubscription = lease.decode.holder.watch().listen(
        _onHolderState,
        onError: _reportError,
      );
      _downloadSubscription = lease.download.watch().listen(
        _onDownloadState,
        onError: _reportError,
      );
      _decodeSubscription = lease.decode.watch().listen(
        _onDecodeState,
        onError: _reportError,
      );
    } catch (error, stack) {
      _reportError(error, stack);
    }
  }

  void _onHolderState(WebPFrameHolderSnapshot snapshot) {
    if (_disposed) return;
    final lease = _lease;
    if (lease?.decode.isCurrent == true) {
      PipelineController.instance.updateCurrentBufferedFrames(
        snapshot.renderedFrames +
            snapshot.rawFrames +
            snapshot.decodeInFlight +
            snapshot.uploadInFlight,
      );
    }
    if (snapshot.renderedFrames > 0) _schedulePump();
  }

  void _onDownloadState(DownloadSessionSnapshot snapshot) {
    if (_disposed) return;
    final current = snapshot.committedLength;
    reportImageChunkEvent(
      ImageChunkEvent(
        cumulativeBytesLoaded: current,
        expectedTotalBytes:
            snapshot.expectedLength > 0 ? snapshot.expectedLength : null,
      ),
    );
    if (snapshot.transport == DownloadTransportState.failed) {
      _reportError(snapshot.error ?? StateError('WebP download failed'));
      return;
    }
    if (snapshot.transport == DownloadTransportState.sealed) {
      _schedulePump();
      if (snapshot.fallbackContent) {
        unawaited(_maybeDecodeFallback(snapshot));
      }
    }
  }

  void _onDecodeState(WebPDecodeSessionSnapshot snapshot) {
    if (_disposed) return;
    if (snapshot.decodeError != null) {
      // An incomplete ANMF payload may make the current decode pass fail until
      // more source bytes arrive. WebPDecodeSession clears that error when
      // committedLength advances, so only a sealed-source failure is terminal.
      if (snapshot.download.transport == DownloadTransportState.sealed) {
        unawaited(
          _maybeDecodeFallback(
            snapshot.download,
            nativeError: snapshot.decodeError,
          ),
        );
      }
      return;
    }
    if (snapshot.uploadError != null) {
      _reportError(snapshot.uploadError!);
      return;
    }
    if (snapshot.download.transport == DownloadTransportState.sealed &&
        snapshot.nativeExhaustedWithoutFrames) {
      unawaited(_maybeDecodeFallback(snapshot.download));
      return;
    }
    if (snapshot.frames.renderedFrames > 0) _schedulePump();
  }

  void _schedulePump() {
    if (_disposed || _pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      if (_fallbackCodec != null) {
        unawaited(_pumpFallback());
      } else {
        unawaited(_pump());
      }
    });
  }

  Future<void> _pump() async {
    if (_disposed ||
        _fallbackStarted ||
        _pumping ||
        !hasListeners ||
        !_isLifecycleActive) {
      return;
    }
    final holder = _lease?.decode.holder;
    if (holder == null || holder.isDisposed) return;

    _pumping = true;
    try {
      while (!_disposed && hasListeners && _isLifecycleActive) {
        final frame = holder.consumeFrame();
        if (frame == null) return;
        if (frame is! FlutterImageFrameHandle) {
          frame.dispose();
          _reportError(
            StateError('Current ImageStreamCompleter requires Flutter images'),
          );
          return;
        }

        final duration = frame.durationMs <= 0
            ? 100
            : frame.durationMs.clamp(16, 200).toInt();
        final image = frame.detachImage();
        frame.dispose();
        setImage(ImageInfo(image: image, scale: _provider.scale));
        await Future<void>.delayed(
          Duration(
            milliseconds: (duration / webpPlaybackSpeed)
                .round()
                .clamp(8, 1000)
                .toInt(),
          ),
        );
      }
    } finally {
      _pumping = false;
      if (!_disposed && holder.hasRenderedFrames) _schedulePump();
    }
  }

  bool get _isLifecycleActive {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != ui.AppLifecycleState.paused &&
        state != ui.AppLifecycleState.hidden &&
        state != ui.AppLifecycleState.detached;
  }

  Future<void> _maybeDecodeFallback(
    DownloadSessionSnapshot snapshot, {
    Object? nativeError,
  }) async {
    if (_fallbackStarted || _disposed) return;
    final lease = _lease;
    if (lease == null) return;
    final eligible = snapshot.fallbackContent ||
        nativeError != null ||
        lease.decode.nativeExhaustedWithoutFrames;
    if (!eligible) return;
    final file = snapshot.artifactFile;
    if (file == null) {
      if (nativeError != null) _reportError(nativeError);
      return;
    }

    _fallbackStarted = true;
    try {
      // Source sealing performs the final native parse synchronously. Give the
      // decode reconciler one turn before falling back to Flutter's generic
      // codec for a non-WebP/static image.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_disposed) return;
      if (!snapshot.fallbackContent &&
          nativeError == null &&
          lease.decode.hasProducedFrame) {
        _fallbackStarted = false;
        _schedulePump();
        return;
      }
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      if (_disposed) {
        codec.dispose();
        return;
      }
      _fallbackCodec?.dispose();
      _fallbackCodec = codec;
      _fallbackFramesEmitted = 0;
      _schedulePump();
    } catch (error, stack) {
      _reportError(
        nativeError == null
            ? error
            : StateError(
                'Native WebP decode failed ($nativeError); '
                'fallback decode also failed ($error)',
              ),
        stack,
      );
    }
  }

  Future<void> _pumpFallback() async {
    if (_disposed ||
        _fallbackPumping ||
        !hasListeners ||
        !_isLifecycleActive) {
      return;
    }
    final codec = _fallbackCodec;
    if (codec == null) return;

    _fallbackPumping = true;
    try {
      while (!_disposed &&
          hasListeners &&
          _isLifecycleActive &&
          identical(_fallbackCodec, codec)) {
        final repetitionCount = codec.repetitionCount;
        final totalFrames = repetitionCount < 0
            ? null
            : codec.frameCount * (repetitionCount + 1);
        if (totalFrames != null && _fallbackFramesEmitted >= totalFrames) {
          codec.dispose();
          if (identical(_fallbackCodec, codec)) _fallbackCodec = null;
          return;
        }

        final frame = await codec.getNextFrame();
        if (_disposed || !identical(_fallbackCodec, codec)) {
          frame.image.dispose();
          return;
        }
        setImage(ImageInfo(image: frame.image, scale: _provider.scale));
        _fallbackFramesEmitted++;

        if (codec.frameCount <= 1) {
          codec.dispose();
          if (identical(_fallbackCodec, codec)) _fallbackCodec = null;
          return;
        }

        final delay = frame.duration.inMicroseconds <= 0
            ? const Duration(milliseconds: 100)
            : Duration(
                milliseconds: (frame.duration.inMilliseconds /
                        webpPlaybackSpeed)
                    .round()
                    .clamp(8, 1000)
                    .toInt(),
              );
        await Future<void>.delayed(delay);
      }
    } catch (error, stack) {
      codec.dispose();
      if (identical(_fallbackCodec, codec)) _fallbackCodec = null;
      _reportError(error, stack);
    } finally {
      _fallbackPumping = false;
    }
  }

  void _reportError(Object error, [StackTrace? stack]) {
    if (_disposed || _reportedTerminalError) return;
    _reportedTerminalError = true;
    reportError(exception: error, stack: stack);
  }
}
