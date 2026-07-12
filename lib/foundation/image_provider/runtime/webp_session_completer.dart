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
  // 诊断：本 provider 挂载时刻与各里程碑是否已上报，用于拆解「翻页→首帧」延迟
  // 分别落在下载封口 / 首帧解码就绪 / 首帧显示 哪一段。
  int _attachMs = 0;
  bool _firstFrameReported = false;
  bool _sealedReported = false;
  bool _firstRenderedReported = false;

  void _milestone(String name, bool Function() alreadyReported, void Function() mark) {
    if (_attachMs == 0 || alreadyReported()) return;
    mark();
    WebPPerf.event(name, micros: (DateTime.now().millisecondsSinceEpoch - _attachMs) * 1000);
  }
  ui.Codec? _fallbackCodec;
  bool _reportedTerminalError = false;
  int _lastChunkReportMs = 0;
  int _lastBufferReportMs = 0;
  int _lastBufferedFrames = -1;

  // native texture 播放状态（仅 Android 动图路径）。
  int? _textureId;
  bool _textureCreating = false;

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

  /// 首帧到达时上报「挂载→首帧」延迟一次。这是用户感知「翻页卡」的真正指标：
  /// 帧率没掉，但下一页迟迟不出图。
  void _reportFirstFrameLatency() {
    if (_firstFrameReported || _attachMs == 0) return;
    _firstFrameReported = true;
    final latency = DateTime.now().millisecondsSinceEpoch - _attachMs;
    WebPPerf.event('firstFrameLatency', micros: latency * 1000);
  }

  void _attach() {
    if (_disposed || !hasListeners || _lease != null) return;
    _attachMs = DateTime.now().millisecondsSinceEpoch;
    _firstFrameReported = false;
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
    if (snapshot.renderedFrames > 0) {
      _milestone('lat.firstRendered',
          () => _firstRenderedReported, () => _firstRenderedReported = true);
      _schedulePump();
    }
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
      _milestone('lat.sealed',
          () => _sealedReported, () => _sealedReported = true);
      // 不在封口(final 信号)处启动播放：这是长条进度条重构前的遗留触发。播放已由
      // 帧到达驱动（_onHolderState / _onDecodeState 的 renderedFrames>0 →
      // _schedulePump），且 pump 循环 poll-continue 常驻、每 32ms 自取新帧，流式解出
      // 的首帧一就绪即播，无需等封口。保留封口仅用于 fallback（非 webp/静态兜底）。
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
        // 漫画阅读器只有当前可见页该「动」。PageView 为流畅翻页会保活近邻页的
        // completer（仍 hasListeners），若不门控它们会在屏幕外把自己的动图循环
        // 播起来 → 持续消费帧 → 缓冲见底 → 不停重解 → 抢当前页解码核，把当前页
        // 解码从 <35ms 顶到 ~50ms。这是重构前 WebPPlaybackController._run 里
        // 「_pauseIfInactive → 非当前页 continue、不 consumeFrame」被验证过的行为，
        // 流式重构时丢掉了 → 回归。isCurrent 由策略租约的 current 标志聚合而来
        // （current 页 true / 近邻页 false），visible 与策略租约共享同一 decode
        // session，信号可靠。
        //
        // 关键：循环**不 return 退出**，只 poll 等待再 continue（复刻旧 _run 死循环）。
        // 上一版把它写成 `return` → pump 一停就得靠事件重新 _schedulePump，翻页瞬间
        // 若 current 标志尚未同步就永久冻死。poll 续转则天然自恢复：一旦变当前，下一
        // 轮立即播；缺帧则等解码补上，都无需外部唤醒。
        final isCurrentNow = _lease?.decode.isCurrent == true;
        if (!isCurrentNow && _firstFrameReported) {
          // 非当前页：已present过静态首帧，此后静止——不消费帧、不驱动重解、不抢核。
          await Future<void>.delayed(const Duration(milliseconds: 120));
          continue;
        }

        final frame = holder.consumeFrame();
        if (frame == null) {
          // 播放中途 consumeFrame 拿不到帧 = 缓冲见底（解码没跟上）。这是「播放卡
          // 顿」的直接信号，Flutter jankFrames 抓不到（native texture 原地更新）。
          if (_firstFrameReported && isCurrentNow) WebPPerf.count('pumpStarved');
          // 不退出：短 poll 等解码补帧，避免依赖事件链重启导致翻页后不自恢复。
          await Future<void>.delayed(const Duration(milliseconds: 32));
          continue;
        }

        final duration = frame.durationMs <= 0
            ? 100
            : frame.durationMs.clamp(16, 1000).toInt();
        // 诊断：帧意图显示间隔。与 decodeMs.cur/帧比较即可判定解码是否追得上播放。
        WebPPerf.event('frameDurationMs', micros: duration * 1000);

        // 测「present（含 blit/MethodChannel 往返）」耗时：它被加在每帧 duration 之
        // 上，若不补偿会让播放变慢且节奏不匀 → 感知卡顿。
        final presentSw = Stopwatch()..start();
        if (frame is NativeAddressFrameHandle) {
          await _presentTextureFrame(frame);
        } else if (frame is FlutterImageFrameHandle) {
          final image = frame.detachImage();
          frame.dispose();
          WebPPerf.count('framePresented');
          _reportFirstFrameLatency();
          setImage(ImageInfo(image: image, scale: _provider.scale));
        } else {
          frame.dispose();
          _reportError(
            StateError('Unknown rendered frame type: ${frame.runtimeType}'),
          );
          return;
        }
        presentSw.stop();
        WebPPerf.event('presentMs', micros: presentSw.elapsedMicroseconds);

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
      // JNI 直读：只把 native 帧地址交给平台侧，native（webp_texture_blit.c）用
      // ANativeWindow 直接 memcpy 进 Surface。像素字节不进 Dart、不经 MethodChannel
      // 序列化，UI isolate 不再做 ~10MB/帧的整块拷贝。帧必须存活到 blit 完成，故
      // dispose 放在 await 之后。
      WebPPerf.count('framePresented');
      _reportFirstFrameLatency();
      try {
        await WebPTextureChannel.instance.update(id, w, h, frame.address);
      } finally {
        frame.dispose();
      }
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
      final validation = await ImageDataValidator.validateFile(file);
      // 只在「明显不是可解码图像」时提前否决（空文件、HTML/JSON/文本错误页、未知
      // 签名）。已识别出图像格式却仅因完整性/长度校验不过（如 webp 的 RIFF 声明长
      // 度与文件实际长度不等——尾部填充/元数据、或服务端 size 字段不精确）不应直接
      // 判死：这类文件 Flutter codec 往往能正常解出。交给 codec 做最终裁决，解不出
      // 才在下方 catch 抛错。这修复了合法远程 webp 偶发被误报 invalid image data。
      if (!validation.valid &&
          validation.format == ImageDataFormat.unknown) {
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
        WebPPerf.count('framePresentedFallback');
        _reportFirstFrameLatency();
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
