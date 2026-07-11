part of '../webp_image.dart';

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

  static const Duration _detachGrace = Duration(milliseconds: 750);

  Timer? _detachTimer;
  bool _disposed = false;
  bool _pumpScheduled = false;
  bool _pumping = false;
  bool _fallbackStarted = false;
  bool _fallbackPumping = false;
  int _fallbackFramesEmitted = 0;
  ui.Codec? _fallbackCodec;
  bool _reportedTerminalError = false;
  int _lastChunkReportMs = 0;
  int _lastBufferReportMs = 0;
  int _lastBufferedFrames = -1;

  // native texture 播放状态（仅 Android 动图路径）。
  int? _textureId;
  bool _textureCreating = false;
  bool _textureUploading = false;

  _WebPSessionImageStreamCompleter(this._provider)
    : _scopeId =
          'visible:${identityHashCode(_provider)}:'
          '${DateTime.now().microsecondsSinceEpoch}' {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void addListener(ImageStreamListener listener) {
    super.addListener(listener);
    _detachTimer?.cancel();
    _detachTimer = null;
    if (_lease == null) _attach();
    _schedulePump();
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) _scheduleVisibleDetach();
  }

  @override
  void onDisposed() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _detachTimer?.cancel();
    _detachTimer = null;
    _detachVisible();
    _disposeTexture();
    _fallbackCodec?.dispose();
    _fallbackCodec = null;
    super.onDisposed();
  }

  void _disposeTexture() {
    final id = _textureId;
    _textureId = null;
    if (id != null) {
      WebPTextureRegistry.instance.clear(_provider._fullKey);
      unawaited(WebPTextureChannel.instance.dispose(id));
    }
  }

  @override
  void didChangeAppLifecycleState(ui.AppLifecycleState state) {
    if (state == ui.AppLifecycleState.resumed) _schedulePump();
  }

  void _attach() {
    if (_disposed || !hasListeners || _lease != null) return;
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

  void _scheduleVisibleDetach() {
    _detachTimer?.cancel();
    _detachTimer = Timer(_detachGrace, () {
      _detachTimer = null;
      if (!_disposed && !hasListeners) _detachVisible();
    });
  }

  void _detachVisible() {
    final holderSubscription = _holderSubscription;
    final downloadSubscription = _downloadSubscription;
    final decodeSubscription = _decodeSubscription;
    _holderSubscription = null;
    _downloadSubscription = null;
    _decodeSubscription = null;
    unawaited(holderSubscription?.cancel());
    unawaited(downloadSubscription?.cancel());
    unawaited(decodeSubscription?.cancel());
    _lease?.detach();
    _lease = null;
  }

  void _onHolderState(WebPFrameHolderSnapshot snapshot) {
    if (_disposed) return;
    final lease = _lease;
    if (lease?.decode.isCurrent == true) {
      final buffered =
          snapshot.renderedFrames +
          snapshot.rawFrames +
          snapshot.decodeInFlight +
          snapshot.uploadInFlight;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (buffered != _lastBufferedFrames &&
          (buffered == 0 || now - _lastBufferReportMs >= 50)) {
        _lastBufferedFrames = buffered;
        _lastBufferReportMs = now;
        PipelineController.instance.updateCurrentBufferedFrames(buffered);
      }
    }
    if (snapshot.renderedFrames > 0) _schedulePump();
  }

  void _onDownloadState(DownloadSessionSnapshot snapshot) {
    if (_disposed) return;
    final current = snapshot.committedLength;
    final now = DateTime.now().millisecondsSinceEpoch;
    final terminal =
        snapshot.transport == DownloadTransportState.sealed ||
        (snapshot.transport == DownloadTransportState.failed &&
            !snapshot.failureRetryable);
    if (terminal || current == 0 || now - _lastChunkReportMs >= 100) {
      _lastChunkReportMs = now;
      reportImageChunkEvent(
        ImageChunkEvent(
          cumulativeBytesLoaded: current,
          expectedTotalBytes: snapshot.expectedLength > 0
              ? snapshot.expectedLength
              : null,
        ),
      );
    }
    if (snapshot.transport == DownloadTransportState.failed) {
      // Retryable network failures retain source/artifact/cursor state. The
      // coordinator retries after backoff; reporting an ImageStream terminal
      // error here would permanently disable a stream that can still recover.
      if (!snapshot.failureRetryable) {
        _reportError(snapshot.error ?? StateError('WebP download failed'));
      }
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

        final duration = frame.durationMs <= 0
            ? 100
            : frame.durationMs.clamp(16, 1000).toInt();

        if (frame is NativeAddressFrameHandle) {
          await _presentTextureFrame(frame);
        } else if (frame is FlutterImageFrameHandle) {
          final image = frame.detachImage();
          frame.dispose();
          WebPPerf.count('framePresented');
          setImage(ImageInfo(image: image, scale: _provider.scale));
        } else {
          frame.dispose();
          _reportError(
            StateError('Unknown rendered frame type: ${frame.runtimeType}'),
          );
          return;
        }

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

  /// 把一帧 native RGBA 上传到本显示的平台纹理（首帧惰性创建纹理并发布到侧通道）。
  /// 纹理内容原地更新、id 不变，Flutter 每帧只需重绘 Texture，无 ui.Image 分配、
  /// 无 setState。
  Future<void> _presentTextureFrame(NativeAddressFrameHandle frame) async {
    try {
      if (_textureId == null) {
        if (_textureCreating) {
          frame.dispose();
          return;
        }
        _textureCreating = true;
        _textureId = await WebPTextureChannel.instance.create();
        _textureCreating = false;
        if (_disposed || _textureId == null) {
          frame.dispose();
          _disposeTexture();
          return;
        }
      }
      final id = _textureId!;
      final w = frame.width, h = frame.height;
      // Stage 2 已验证的 Uint8List 通路（每帧一次拷贝 + MethodChannel）。后续可换
      // JNI 直读 native 地址消除这层拷贝。
      final pixels = Uint8List.fromList(
        Pointer<Uint8>.fromAddress(frame.address).asTypedList(w * h * 4),
      );
      frame.dispose();
      WebPPerf.count('framePresented');
      _textureUploading = true;
      await WebPTextureChannel.instance.update(id, w, h, pixels);
      _textureUploading = false;
      if (_disposed) {
        _disposeTexture();
        return;
      }
      WebPTextureRegistry.instance.publish(
        _provider._fullKey,
        WebPTextureInfo(textureId: id, width: w, height: h),
      );
    } catch (error, stack) {
      _textureCreating = false;
      _textureUploading = false;
      frame.dispose(); // idempotent
      _reportError(error, stack);
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
    final eligible =
        snapshot.fallbackContent ||
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
      final validation = await ImageDataValidator.validateFile(file);
      if (!validation.valid) {
        throw InvalidImageDataException(
          'Invalid cached image artifact: ${validation.reason}',
        );
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
    if (_disposed || _fallbackPumping || !hasListeners || !_isLifecycleActive) {
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
                milliseconds:
                    (frame.duration.inMilliseconds / webpPlaybackSpeed)
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
