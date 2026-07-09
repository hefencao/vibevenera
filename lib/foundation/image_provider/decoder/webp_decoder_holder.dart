part of '../webp_image_provider.dart';

class DecoderHolder {
  static const int _firstFrameWatermark = 1;
  static const int _lowWatermark = 3;
  static const int _highWatermark = 7;
  static const int _precacheTarget = 5;

  final String key;
  final webp.WebPAnimDecoder decoder;
  final int targetW, targetH;
  final double scale;
  final String shortKey;

  PageState _state = PageState.precache;
  PageState get state => _state;

  ResourcePolicy _policy = const ResourcePolicy();
  ResourcePolicy get policy => _policy;

  final WebPFrameBuffer _frameBuffer = WebPFrameBuffer();
  int get bufferLength => _frameBuffer.bufferLength;
  int get queuedFrameCount => _frameBuffer.queuedFrameCount;

  bool _disposed = false;
  bool get disposed => _disposed;
  bool _pendingDispose = false;

  int lastAccessTime = 0;
  int decodedFrameCount = 0;
  int uploadedFrameCount = 0;
  int streamLoadedBytes = 0;
  int? streamExpectedBytes;
  int _streamEmptyDecodeCount = 0;
  int _lastStreamDecodeLogMs = 0;
  bool _streamFailed = false;
  bool _streamDownloadClosed = false;
  Object? streamError;
  bool get streamFailed => _streamFailed;
  bool get streamNeedsResume =>
      _streamDownloadClosed && decoder.isStreaming && !decoder.streamIsComplete;

  bool _decodeInFlight = false;
  bool _isUploading = false;
  int _decodeToken = 0;
  Completer<void>? refillSignal;

  /// Callback set by [HolderDecodeService]. Called when the holder
  /// needs more frames decoded.
  void Function()? onNeedFrames;

  DecoderHolder({
    required this.key,
    required this.decoder,
    required this.targetW,
    required this.targetH,
    required this.scale,
  }) : shortKey = _short(key);

  void updateState(PageState newState) {
    if (_disposed || _state == newState) return;
    _state = newState;
    lastAccessTime = _nowMs();
    decoder.setThreadLimit(newState == PageState.current ? 2 : 1);
    _notifyCurrentBuffer();
    _pumpUpload();
    _requestFramesIfNeeded();
  }

  void updatePolicy(ResourcePolicy newPolicy) {
    if (_disposed) return;
    if (_policy.allowDecode == newPolicy.allowDecode &&
        _policy.allowGpuUpload == newPolicy.allowGpuUpload) {
      return;
    }
    _policy = newPolicy;
    if (!_policy.allowGpuUpload) _clearRawFrames();
    _pumpUpload();
    _requestFramesIfNeeded();
  }

  BufferedFrame? consumeFrame() {
    if (_disposed) return null;
    lastAccessTime = _nowMs();
    if (!_frameBuffer.hasUploadedFrames) {
      _requestFramesIfNeeded();
      return null;
    }
    final frame = _frameBuffer.removeUploadedFrame();
    _notifyCurrentBuffer();
    _pumpUpload();
    _requestFramesIfNeeded();
    return frame;
  }

  /// [FIX] Delegates to external [onNeedFrames] instead of calling
  /// WorkerPoolScheduler directly.
  void _requestFramesIfNeeded() {
    if (_disposed || _pendingDispose) return;
    if (!_policy.allowDecode || !_policy.allowGpuUpload) return;
    if (_decodeInFlight) return;

    final target = _state == PageState.current
        ? _highWatermark
        : _precacheTarget;
    final low = _state == PageState.current ? _lowWatermark : 0;
    final queued = queuedFrameCount;
    final shouldRefill = _state == PageState.current
        ? queued < target
        : bufferLength <= low && queued < target;
    if (shouldRefill) {
      onNeedFrames?.call();
    }
  }

  // ── Decode callback (called by HolderDecodeService) ─────────

  /// Called by [HolderDecodeService] with decoded frame addresses.
  void onFramesDecoded(List<webp.WebPAnimFrameAddress> frames, int token) {
    if (token != _decodeToken) {
      _decodeInFlight = false;
      WebPFrameBuffer.releaseRawFrames(frames);
      _disposeIfPendingAfterDecode();
      return;
    }
    _decodeInFlight = false;
    if (_disposed || _pendingDispose) {
      WebPFrameBuffer.releaseRawFrames(frames);
      _completeRefillWaiters();
      _disposeIfPendingAfterDecode();
      return;
    }
    if (frames.isEmpty) {
      if (_pendingDispose) {
        _pendingDispose = false;
        dispose();
      }
      _completeRefillWaiters();
      if (decoder.isStreaming) {
        _streamEmptyDecodeCount++;
        final now = _nowMs();
        if (_streamEmptyDecodeCount <= 3 ||
            now - _lastStreamDecodeLogMs >= 1000) {
          _lastStreamDecodeLogMs = now;
          debugPrint(
            '[WebP-Stream][decode] empty#$_streamEmptyDecodeCount '
            'frames=${decoder.frameCount} buf=$bufferLength raw=${_frameBuffer.rawLength} '
            '$shortKey',
          );
        }
        if (_streamEmptyDecodeCount >= 6 &&
            decoder.streamIsComplete &&
            queuedFrameCount == 0 &&
            _streamMayDecodeMore) {
          markStreamFailed(StateError('stream decode stalled after final'));
        } else if (_streamMayDecodeMore) {
          Future.delayed(
            Duration(milliseconds: _streamEmptyDecodeCount <= 2 ? 0 : 50),
            requestRefill,
          );
        }
        return;
      }
      _requestFramesIfNeeded();
      return;
    }
    // Drop frames decoded for a page that's no longer visible.
    // Without this check, stale frames from previous pages get
    // uploaded and mixed into the current display → corruption.
    if (_state != PageState.current &&
        _dispatchGen != DecoderManager.instance.generation) {
      WebPFrameBuffer.releaseRawFrames(frames);
      _completeRefillWaiters();
      _requestFramesIfNeeded();
      return;
    }
    if (!_policy.allowGpuUpload) {
      WebPFrameBuffer.releaseRawFrames(frames);
      _completeRefillWaiters();
      return;
    }
    decodedFrameCount += frames.length;
    if (decoder.isStreaming) {
      _streamEmptyDecodeCount = 0;
      debugPrint(
        '[WebP-Stream][decode] frames=${frames.length} '
        'totalDecoded=$decodedFrameCount buf=$bufferLength raw=${_frameBuffer.rawLength} '
        '$shortKey',
      );
    }
    _frameBuffer.addRawFrames(frames);
    _pumpUpload();
    _requestFramesIfNeeded();
  }

  bool get _streamMayDecodeMore {
    if (!decoder.isStreaming || !decoder.streamIsComplete) return false;
    final frames = decoder.frameCount;
    if (frames <= 0) return false;
    final loops = decoder.loopCount;
    return loops <= 0 || decodedFrameCount < frames * loops;
  }

  bool get _streamAtAvailableEnd =>
      decoder.isStreaming &&
      !decoder.streamIsComplete &&
      decoder.frameCount > 0 &&
      decodedFrameCount >= decoder.frameCount &&
      queuedFrameCount == 0;

  /// Generation at the time the last decode was dispatched.
  int _dispatchGen = 0;

  // ── GPU Upload ─────────────────────────────────────────────

  void _pumpUpload() {
    if (_isUploading || _disposed || _pendingDispose) return;
    if (!_policy.allowGpuUpload || !_frameBuffer.hasRawFrames) return;
    _doUpload();
  }

  Future<void> _doUpload() async {
    _isUploading = true;
    final outW = decoder.targetWidth;
    final outH = decoder.targetHeight;
    try {
      while (_frameBuffer.hasRawFrames) {
        if (_disposed || _pendingDispose || !_policy.allowGpuUpload) {
          _clearRawFrames();
          break;
        }
        final addr = _frameBuffer.removeRawFrame();
        final rgba = Pointer<Uint8>.fromAddress(
          addr.address,
        ).asTypedList(outW * outH * 4);
        final completer = Completer<BufferedFrame>();
        ui.decodeImageFromPixels(rgba, outW, outH, ui.PixelFormat.rgba8888, (
          img,
        ) {
          webp.nativePoolRelease(addr.address);
          completer.complete(BufferedFrame(img, addr.durationMs));
        });
        final frame = await completer.future;
        if (_disposed || _pendingDispose || !_policy.allowGpuUpload) {
          frame.image.dispose();
          continue;
        }
        _frameBuffer.addUploadedFrame(frame);
        uploadedFrameCount++;
        _notifyCurrentBuffer();
        _completeRefillWaitersIfFirstFrameReady();
        _requestFramesIfNeeded();
      }
    } finally {
      _isUploading = false;
      _completeRefillWaiters();
      if (_frameBuffer.hasRawFrames) _pumpUpload();
      _requestFramesIfNeeded();
    }
  }

  void _completeRefillWaiters() {
    refillSignal?.complete();
    refillSignal = null;
  }

  void _completeRefillWaitersIfFirstFrameReady() {
    if (_state == PageState.current &&
        bufferLength >= _firstFrameWatermark) {
      _completeRefillWaiters();
    }
  }

  void _clearRawFrames() => _frameBuffer.clearRawFrames();

  void clearBufferedFrames() {
    _frameBuffer.clear();
    _notifyCurrentBuffer();
  }

  void resetStreamPlaybackState() {
    if (!decoder.isStreaming) return;
    decodedFrameCount = 0;
    uploadedFrameCount = 0;
    _streamEmptyDecodeCount = 0;
    _lastStreamDecodeLogMs = 0;
    markStreamActive();
    _completeRefillWaiters();
  }

  void updateStreamTransfer(int current, int? total, {bool reset = false}) {
    if (reset) {
      streamLoadedBytes = 0;
      streamExpectedBytes = null;
      return;
    }
    if (current > streamLoadedBytes) streamLoadedBytes = current;
    streamExpectedBytes = total ?? streamExpectedBytes;
  }

  bool restartAvailableStreamPlayback({int minFrames = 3}) {
    if (_disposed || _pendingDispose || !decoder.isStreaming) return false;
    if (decoder.streamIsComplete || decoder.frameCount < minFrames) return false;
    if (queuedFrameCount > 0 || _isUploading) return false;
    final cancelInFlight = _decodeInFlight;
    if (cancelInFlight) {
      DecoderManager.instance.decodeService.invalidatePendingDecodes(this);
      _decodeInFlight = false;
    }
    _decodeToken++;
    decoder.restartStreamPlayback();
    resetStreamPlaybackState();
    requestRefill();
    if (cancelInFlight) {
      debugPrint('[WebP-Stream][visible] REPLAY-CANCEL-DECODE $shortKey');
    }
    return true;
  }

  void markStreamActive() {
    _streamFailed = false;
    _streamDownloadClosed = false;
    streamError = null;
  }

  void markStreamDownloadClosed(Object reason) {
    if (_disposed || _pendingDispose) return;
    _streamDownloadClosed = true;
    streamError = reason;
    _completeRefillWaiters();
  }

  void markStreamFailed(Object error) {
    if (_disposed || _pendingDispose) return;
    _streamFailed = true;
    _streamDownloadClosed = false;
    streamError = error;
    _completeRefillWaiters();
  }

  void resumeFromLifecyclePause() {
    if (_disposed || _pendingDispose) return;
    _completeRefillWaiters();
    requestRefill();
  }

  void requestRefill() {
    if (_disposed || _pendingDispose) return;
    _pumpUpload();
    _requestFramesIfNeeded();
    _notifyCurrentBuffer();
  }

  void _notifyCurrentBuffer() {
    if (_state == PageState.current) {
      PipelineController.instance.updateCurrentBufferedFrames(
        bufferLength,
      );
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────

  void dispose() {
    if (_disposed) return;
    if (_decodeInFlight) {
      _pendingDispose = true;
      onNeedFrames = null;
      clearBufferedFrames();
      _completeRefillWaiters();
      final active =
          DecoderManager.instance.decodeService.invalidatePendingDecodes(this);
      if (active) return;
      _decodeInFlight = false;
      _pendingDispose = false;
    }
    _disposed = true;
    _decodeToken++;
    decoder.dispose();
    clearBufferedFrames();
    onNeedFrames = null;
    _completeRefillWaiters();
  }

  void markPendingDispose() {
    if (_pendingDispose || _disposed) return;
    _pendingDispose = true;
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_pendingDispose && !_disposed) {
        _pendingDispose = false;
        dispose();
      }
    });
  }

  void _disposeIfPendingAfterDecode() {
    if (!_pendingDispose || _decodeInFlight || _disposed) return;
    _pendingDispose = false;
    dispose();
  }
}

// ═══════════════════════════════════════════════════════════════
// 3. HolderDecodeService — drives frame decode externally
//
// [FIX] Extracted from DecoderHolder._scheduleDecode().
// DecoderHolder no longer knows about WorkerPoolScheduler or
// generation counters. This service wires them together.
// ═══════════════════════════════════════════════════════════════

