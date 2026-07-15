part of '../streaming_image.dart';

enum _PlaybackGate { present, prepare, wait }

/// ImageProvider adapter for the Phase 3 session pipeline.
///
/// It subscribes to an existing WebPDecodeSession/holder and never opens a
/// second network stream, never replays chunk history, and never owns the
/// NativeWebPSource.
final class _StreamingImageCompleter extends ImageStreamCompleter
    with WidgetsBindingObserver {
  final StreamingImageProvider _provider;
  final String _scopeId;

  StreamingResourceLease? _lease;
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
  int _playbackRevision = 0;
  Completer<void>? _playbackWaiter;
  bool _playbackWakeDeferred = false;
  ViewportTransitionPhase _observedTransitionPhase =
      ViewportTransitionPhase.idle;
  // 诊断：本 provider 挂载时刻与各里程碑是否已上报，用于拆解「翻页→首帧」延迟
  // 分别落在下载封口 / 首帧解码就绪 / 首帧显示 哪一段。
  int _attachMs = 0;
  bool _firstFrameReported = false;
  bool _sealedReported = false;
  bool _firstRenderedReported = false;

  void _milestone(String name, bool Function() alreadyReported, void Function() mark) {
    if (_attachMs == 0 || alreadyReported()) return;
    mark();
    ImagePipelinePerf.event(name, micros: (DateTime.now().millisecondsSinceEpoch - _attachMs) * 1000);
  }
  ui.Codec? _fallbackCodec;
  late final GifStreamRuntime _gifRuntime;
  bool _gifCodecReplacing = false;
  int? _gifCodecEpoch;
  int _gifCodecFrames = 0;
  bool _reportedTerminalError = false;
  int _lastChunkReportMs = 0;
  int _lastBufferReportMs = 0;
  int _lastBufferedFrames = -1;

  // native texture 播放状态（仅 Android 动图路径）。
  int? _textureId;
  Future<int>? _textureCreation;

  _StreamingImageCompleter(this._provider)
    : _scopeId =
          'visible:${identityHashCode(_provider)}:'
          '${DateTime.now().microsecondsSinceEpoch}' {
    _gifRuntime = GifStreamRuntime(
      targetWidth: _provider.targetWidth,
      targetHeight: _provider.targetHeight,
      currentDownload: () => _lease?.download.snapshot,
      onUpdated: _onGifUpdated,
      onError: _reportError,
    );
    PipelineController.instance.playbackPolicyChanges.addListener(
      _signalPlayback,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void addListener(ImageStreamListener listener) {
    super.addListener(listener);
    _detachTimer?.cancel();
    _detachTimer = null;
    if (_lease == null) _attach();
    _signalPlayback();
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) _scheduleVisibleDetach();
  }

  @override
  void onDisposed() {
    _disposed = true;
    PipelineController.instance.playbackPolicyChanges.removeListener(
      _signalPlayback,
    );
    _signalPlayback();
    WidgetsBinding.instance.removeObserver(this);
    _detachTimer?.cancel();
    _detachTimer = null;
    _detachVisible();
    _disposeTexture();
    _fallbackCodec?.dispose();
    _fallbackCodec = null;
    _gifRuntime.dispose();
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
    if (state == ui.AppLifecycleState.resumed) _signalPlayback();
  }

  /// 首帧到达时上报「挂载→首帧」延迟一次。这是用户感知「翻页卡」的真正指标：
  /// 帧率没掉，但下一页迟迟不出图。
  void _reportFirstFrameLatency() {
    if (_firstFrameReported || _attachMs == 0) return;
    _firstFrameReported = true;
    final latency = DateTime.now().millisecondsSinceEpoch - _attachMs;
    ImagePipelinePerf.event('firstFrameLatency', micros: latency * 1000);
  }

  void _attach() {
    if (_disposed || !hasListeners || _lease != null) return;
    _attachMs = DateTime.now().millisecondsSinceEpoch;
    _firstFrameReported = false;
    try {
      final lease = PipelineController.instance.acquireVisibleStreaming(
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
      _signalPlayback();
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
    if (snapshot.contentKind == DownloadContentKind.gif &&
        snapshot.artifactFile != null) {
      _queueGifSnapshot(snapshot);
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
      // 帧到达驱动（_onHolderState / _onDecodeState → revision wake signal），流式
      // 解出的首帧一就绪即播，无需等封口。保留封口仅用于 fallback（非 webp/静态兜底）。
      if (snapshot.externalContent &&
          snapshot.contentKind != DownloadContentKind.gif) {
        unawaited(_maybeDecodeFallback(snapshot));
      }
    }
  }

  void _onDecodeState(WebPDecodeSessionSnapshot snapshot) {
    if (_disposed) return;
    _signalPlayback();
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

  void _signalPlayback() {
    if (_canPreparePlayback &&
        _lease?.decode.holder.hasRenderedFrames == true) {
      unawaited(_prepareTexture());
    }
    final pipeline = PipelineController.instance;
    final phase = pipeline.viewportTransition.phase;
    final resumedTransition =
        _observedTransitionPhase == ViewportTransitionPhase.overlap &&
        phase != ViewportTransitionPhase.overlap;
    _observedTransitionPhase = phase;
    final deferResume =
        (resumedTransition ||
            phase == ViewportTransitionPhase.dominant &&
                (pipeline.interactionState == InteractionState.dragging ||
                    pipeline.interactionState == InteractionState.settling)) &&
        WidgetsBinding.instance.schedulerPhase != SchedulerPhase.idle;
    if (deferResume) {
      if (_playbackWakeDeferred) return;
      _playbackWakeDeferred = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _playbackWakeDeferred = false;
        if (!_disposed) _wakePlayback();
      });
      return;
    }
    _wakePlayback();
  }

  void _wakePlayback() {
    _playbackRevision++;
    final waiter = _playbackWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _schedulePump();
  }

  Future<void> _waitForPlaybackSignal(int revision) {
    if (_disposed || revision != _playbackRevision) return Future<void>.value();
    final waiter = Completer<void>();
    _playbackWaiter = waiter;
    if (_disposed || revision != _playbackRevision) waiter.complete();
    return waiter.future.whenComplete(() {
      if (identical(_playbackWaiter, waiter)) _playbackWaiter = null;
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
        // 非当前、viewport overlap 或缺帧时挂起到 session/policy 的下一次状态信号。
        // revision 消除“状态在建立 waiter 前变化”的丢唤醒竞态，不再用 32/120ms poll。
        final playbackRevision = _playbackRevision;
        final isCurrentNow = _lease?.decode.isCurrent == true;
        final gate = _playbackGate(isCurrentNow);
        if (gate != _PlaybackGate.present) {
          await _waitForPlaybackSignal(playbackRevision);
          continue;
        }

        final frame = holder.consumeFrame();
        if (frame == null) {
          // 播放中途 consumeFrame 拿不到帧 = 缓冲见底（解码没跟上）。这是「播放卡
          // 顿」的直接信号，Flutter jankFrames 抓不到（native texture 原地更新）。
          if (_firstFrameReported && isCurrentNow) ImagePipelinePerf.count('pumpStarved');
          await _waitForPlaybackSignal(playbackRevision);
          continue;
        }

        final duration = frame.durationMs <= 0
            ? 100
            : frame.durationMs.clamp(16, 1000).toInt();
        // 诊断：帧意图显示间隔。与 decodeMs.cur/帧比较即可判定解码是否追得上播放。
        ImagePipelinePerf.event('frameDurationMs', micros: duration * 1000);

        // 测「present（含 blit/MethodChannel 往返）」耗时：它被加在每帧 duration 之
        // 上，若不补偿会让播放变慢且节奏不匀 → 感知卡顿。
        final presentSw = Stopwatch()..start();
        if (frame is NativeAddressFrameHandle) {
          await _presentTextureFrame(frame);
        } else if (frame is FlutterImageFrameHandle) {
          final image = frame.detachImage();
          frame.dispose();
          ImagePipelinePerf.count('framePresented');
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
        ImagePipelinePerf.event('presentMs', micros: presentSw.elapsedMicroseconds);

        await Future<void>.delayed(
          Duration(
            milliseconds: (duration / animatedPlaybackSpeed)
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
      final id = await _ensureTexture();
      while (!_disposed &&
          _playbackGate(_lease?.decode.isCurrent == true) !=
              _PlaybackGate.present) {
        final revision = _playbackRevision;
        await _waitForPlaybackSignal(revision);
      }
      if (_disposed) {
        frame.dispose();
        _disposeTexture();
        return;
      }
      final w = frame.width, h = frame.height;
      // JNI 直读：只把 native 帧地址交给平台侧，native（webp_texture_blit.c）用
      // ANativeWindow 直接 memcpy 进 Surface。像素字节不进 Dart、不经 MethodChannel
      // 序列化，UI isolate 不再做 ~10MB/帧的整块拷贝。帧必须存活到 blit 完成，故
      // dispose 放在 await 之后。
      final bool presented;
      try {
        presented = await WebPTextureChannel.instance.update(
          id,
          w,
          h,
          frame.address,
        );
      } finally {
        frame.dispose();
      }
      if (!presented) {
        ImagePipelinePerf.count('texturePresentRejected');
        return;
      }
      if (_disposed) {
        _disposeTexture();
        return;
      }
      ImagePipelinePerf.count('framePresented');
      _reportFirstFrameLatency();
      WebPTextureRegistry.instance.publish(
        _provider._fullKey,
        WebPTextureInfo(textureId: id, width: w, height: h),
      );
    } catch (error, stack) {
      frame.dispose(); // idempotent
      _reportError(error, stack);
    }
  }

  Future<int> _ensureTexture() async {
    final existing = _textureId;
    if (existing != null) return existing;
    final creating = _textureCreation;
    if (creating != null) return creating;
    final future = () async {
      final id = await WebPTextureChannel.instance.create();
      if (id == null) throw StateError('Failed to create WebP texture');
      if (_disposed) {
        await WebPTextureChannel.instance.dispose(id);
        throw StateError('WebP texture owner was disposed during creation');
      }
      _textureId = id;
      return id;
    }();
    _textureCreation = future;
    try {
      return await future;
    } finally {
      if (identical(_textureCreation, future)) _textureCreation = null;
    }
  }

  Future<void> _prepareTexture() async {
    if (!WebPTextureChannel.instance.isSupported || _textureId != null) return;
    try {
      await _ensureTexture();
    } catch (error, stack) {
      _reportError(error, stack);
    }
  }

  bool get _isLifecycleActive {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != ui.AppLifecycleState.paused &&
        state != ui.AppLifecycleState.hidden &&
        state != ui.AppLifecycleState.detached;
  }

  bool get _shouldFreezePlayback {
    final pipeline = PipelineController.instance;
    final transition = pipeline.viewportTransition;
    if (transition.phase != ViewportTransitionPhase.idle) {
      return transition.shouldFreezePlayback;
    }
    // continuous/custom slider 没有离散 PageMetrics，保留 scroll 期间冻结；
    // Gallery 则由覆盖度状态接管，不能再一直等到 ScrollEnd。
    return pipeline.interactionState == InteractionState.scroll;
  }

  bool get _canPreparePlayback =>
      PipelineController.instance.shouldPreparePresentation(
        _provider.imageKey,
      );

  _PlaybackGate _playbackGate(bool isCurrent) {
    if (!_firstFrameReported) return _PlaybackGate.present;
    if (_shouldFreezePlayback || !isCurrent) {
      return _canPreparePlayback ? _PlaybackGate.prepare : _PlaybackGate.wait;
    }
    return _PlaybackGate.present;
  }

  void _queueGifSnapshot(DownloadSessionSnapshot snapshot) {
    _gifRuntime.addSnapshot(snapshot);
  }

  Future<void> _onGifUpdated() async {
    if (_disposed) return;
    _signalPlayback();
    _fallbackStarted = true;
    if (_fallbackCodec == null && _gifRuntime.canBuild) {
      await _replaceGifCodec(skipFrames: 0);
    } else {
      _signalPlayback();
    }
  }

  Future<bool> _replaceGifCodec({
    required int skipFrames,
    ui.Codec? expectedCodec,
  }) async {
    if (_gifCodecReplacing) return false;
    _gifCodecReplacing = true;
    try {
      final build = await _gifRuntime.buildCodec(skipFrames: skipFrames);
      if (build == null) return false;
      if (_disposed ||
          expectedCodec != null && !identical(_fallbackCodec, expectedCodec)) {
        build.codec.dispose();
        return false;
      }
      final old = _fallbackCodec;
      _fallbackCodec = build.codec;
      _fallbackFramesEmitted = skipFrames;
      _gifCodecFrames = build.frameCount;
      _gifCodecEpoch = build.epoch;
      if (old != null && !identical(old, build.codec)) old.dispose();
      _signalPlayback();
      return true;
    } finally {
      _gifCodecReplacing = false;
    }
  }
  Future<void> _maybeDecodeFallback(
    DownloadSessionSnapshot snapshot, {
    Object? nativeError,
  }) async {
    if (snapshot.contentKind == DownloadContentKind.gif &&
        snapshot.artifactFile != null) {
      _queueGifSnapshot(snapshot);
      return;
    }
    if (_fallbackStarted || _disposed) return;
    final lease = _lease;
    if (lease == null) return;
    final eligible =
        snapshot.externalContent ||
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
      _signalPlayback();
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

    ui.FrameInfo? pendingFrame;
    _fallbackPumping = true;
    try {
      while (!_disposed &&
          hasListeners &&
          _isLifecycleActive &&
          identical(_fallbackCodec, codec)) {
        final playbackRevision = _playbackRevision;
        final isCurrent = _lease?.decode.isCurrent == true;
        if (isCurrent) {
          final healthy =
              !_gifRuntime.hasFrames ||
              _gifRuntime.isFinal ||
              _fallbackFramesEmitted < _gifCodecFrames;
          PipelineController.instance.updateCurrentExternalCodec(
            ready: healthy,
          );
        }
        if (pendingFrame == null &&
            _gifRuntime.hasFrames &&
            _fallbackFramesEmitted >= _gifCodecFrames) {
          final sourceChanged =
              _gifCodecEpoch != _gifRuntime.epoch && _gifRuntime.availableFrames > 0;
          if ((sourceChanged || _gifRuntime.availableFrames > _gifCodecFrames) &&
              _gifRuntime.canBuild) {
            await _replaceGifCodec(
              skipFrames: sourceChanged ? 0 : _gifCodecFrames,
              expectedCodec: codec,
            );
            return;
          }
          if (!_gifRuntime.isFinal) {
            await _waitForPlaybackSignal(playbackRevision);
            continue;
          }
        }
        final repetitionCount = codec.repetitionCount;
        final totalFrames = repetitionCount < 0
            ? null
            : codec.frameCount * (repetitionCount + 1);
        if (totalFrames != null && _fallbackFramesEmitted >= totalFrames) {
          codec.dispose();
          if (identical(_fallbackCodec, codec)) _fallbackCodec = null;
          return;
        }

        final gate = _playbackGate(isCurrent);
        if (gate != _PlaybackGate.present) {
          if (gate == _PlaybackGate.prepare && pendingFrame == null) {
            pendingFrame = await codec.getNextFrame();
            if (_disposed || !identical(_fallbackCodec, codec)) return;
          }
          await _waitForPlaybackSignal(playbackRevision);
          continue;
        }
        pendingFrame ??= await codec.getNextFrame();
        if (_disposed || !identical(_fallbackCodec, codec)) return;
        if (_playbackGate(_lease?.decode.isCurrent == true) !=
            _PlaybackGate.present) {
          continue;
        }
        final frame = pendingFrame;
        pendingFrame = null;
        ImagePipelinePerf.count('framePresentedFallback');
        _reportFirstFrameLatency();
        setImage(ImageInfo(image: frame.image, scale: _provider.scale));
        _fallbackFramesEmitted++;

        if (codec.frameCount <= 1 && (!_gifRuntime.hasFrames || _gifRuntime.isFinal)) {
          codec.dispose();
          if (identical(_fallbackCodec, codec)) _fallbackCodec = null;
          return;
        }

        final delay = frame.duration.inMicroseconds <= 0
            ? const Duration(milliseconds: 100)
            : Duration(
                milliseconds:
                    (frame.duration.inMilliseconds / animatedPlaybackSpeed)
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
      pendingFrame?.image.dispose();
      _fallbackPumping = false;
    }
  }

  void _reportError(Object error, [StackTrace? stack]) {
    if (_disposed || _reportedTerminalError) return;
    _reportedTerminalError = true;
    reportError(exception: error, stack: stack);
  }
}
