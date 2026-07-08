import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;
import 'dart:ffi';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'image_fetch.dart';
import 'pipeline_controller.dart';
import 'task_scheduler.dart';

double webpPlaybackSpeed = 1.0;
const List<double> webpSpeedPresets = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

final _clock = Stopwatch()..start();
int _nowMs() => _clock.elapsedMilliseconds;

String _short(String key) {
  final end = key.indexOf('@');
  final s = end < 0 ? key : key.substring(0, end);
  final slash = s.lastIndexOf('/');
  final bslash = s.lastIndexOf('\\');
  final start = (slash > bslash ? slash : bslash) + 1;
  final name = s.substring(start);
  if (name.length >= 2 &&
      name.codeUnitAt(0) >= 0x30 &&
      name.codeUnitAt(0) <= 0x39) {
    final digits = name.split('.').first;
    return digits.length <= 4
        ? '$digits.webp'
        : '${digits.substring(digits.length - 4)}.webp';
  }
  return name;
}

enum PageState { current, next, last, precache }

PageState _priorityToPageState(PagePriority p) {
  switch (p) {
    case PagePriority.current:
      return PageState.current;
    case PagePriority.near:
      return PageState.next;
    case PagePriority.far:
    case PagePriority.keep:
    case PagePriority.distant:
      return PageState.precache;
  }
}

// ═══════════════════════════════════════════════════════════════
// 1. BufferedFrame
// ═══════════════════════════════════════════════════════════════

class BufferedFrame {
  final ui.Image image;
  final int durationMs;
  BufferedFrame(this.image, this.durationMs);
}

// ═══════════════════════════════════════════════════════════════
// 2. DecoderHolder — pure decoder wrapper
//
// [FIX] No longer knows about DecoderManager, WorkerPoolScheduler,
// or generation counters. Decode is driven externally by
// [HolderDecodeService].
// ═══════════════════════════════════════════════════════════════

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

  final Queue<BufferedFrame> _frameBuffer = Queue();
  final Queue<webp.WebPAnimFrameAddress> _rawFrameQueue = Queue();
  int get bufferLength => _frameBuffer.length;
  int get queuedFrameCount => _frameBuffer.length + _rawFrameQueue.length;

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
    if (_frameBuffer.isEmpty) {
      _requestFramesIfNeeded();
      return null;
    }
    final frame = _frameBuffer.removeFirst();
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
        : _frameBuffer.length <= low && queued < target;
    if (shouldRefill) {
      onNeedFrames?.call();
    }
  }

  // ── Decode callback (called by HolderDecodeService) ─────────

  /// Called by [HolderDecodeService] with decoded frame addresses.
  void onFramesDecoded(List<webp.WebPAnimFrameAddress> frames, int token) {
    if (token != _decodeToken) {
      for (final f in frames) {
        webp.nativePoolRelease(f.address);
      }
      return;
    }
    _decodeInFlight = false;
    if (_disposed || _pendingDispose) {
      for (final f in frames) {
        webp.nativePoolRelease(f.address);
      }
      _completeRefillWaiters();
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
            'frames=${decoder.frameCount} buf=$bufferLength raw=${_rawFrameQueue.length} '
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
      for (final f in frames) {
        webp.nativePoolRelease(f.address);
      }
      _completeRefillWaiters();
      _requestFramesIfNeeded();
      return;
    }
    if (!_policy.allowGpuUpload) {
      for (final f in frames) {
        webp.nativePoolRelease(f.address);
      }
      _completeRefillWaiters();
      return;
    }
    decodedFrameCount += frames.length;
    if (decoder.isStreaming) {
      _streamEmptyDecodeCount = 0;
      debugPrint(
        '[WebP-Stream][decode] frames=${frames.length} '
        'totalDecoded=$decodedFrameCount buf=$bufferLength raw=${_rawFrameQueue.length} '
        '$shortKey',
      );
    }
    _rawFrameQueue.addAll(frames);
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
    if (!_policy.allowGpuUpload || _rawFrameQueue.isEmpty) return;
    _doUpload();
  }

  Future<void> _doUpload() async {
    _isUploading = true;
    final outW = decoder.targetWidth;
    final outH = decoder.targetHeight;
    try {
      while (_rawFrameQueue.isNotEmpty) {
        if (_disposed || _pendingDispose || !_policy.allowGpuUpload) {
          _clearRawFrames();
          break;
        }
        final addr = _rawFrameQueue.removeFirst();
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
        _frameBuffer.add(frame);
        uploadedFrameCount++;
        _notifyCurrentBuffer();
        _completeRefillWaitersIfFirstFrameReady();
        _requestFramesIfNeeded();
      }
    } finally {
      _isUploading = false;
      _completeRefillWaiters();
      if (_rawFrameQueue.isNotEmpty) _pumpUpload();
      _requestFramesIfNeeded();
    }
  }

  void _completeRefillWaiters() {
    refillSignal?.complete();
    refillSignal = null;
  }

  void _completeRefillWaitersIfFirstFrameReady() {
    if (_state == PageState.current &&
        _frameBuffer.length >= _firstFrameWatermark) {
      _completeRefillWaiters();
    }
  }

  void _clearRawFrames() {
    while (_rawFrameQueue.isNotEmpty) {
      webp.nativePoolRelease(_rawFrameQueue.removeFirst().address);
    }
  }

  void clearBufferedFrames() {
    for (final f in _frameBuffer) {
      f.image.dispose();
    }
    _frameBuffer.clear();
    _clearRawFrames();
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
        _frameBuffer.length,
      );
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────

  void dispose() {
    if (_disposed) return;
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
}

// ═══════════════════════════════════════════════════════════════
// 3. HolderDecodeService — drives frame decode externally
//
// [FIX] Extracted from DecoderHolder._scheduleDecode().
// DecoderHolder no longer knows about WorkerPoolScheduler or
// generation counters. This service wires them together.
// ═══════════════════════════════════════════════════════════════

class HolderDecodeService {
  final webp.WorkerPoolScheduler _pool = webp.WorkerPoolScheduler.instance;
  int _generation = 0;

  int get generation => _generation;

  void updateGeneration(int gen) {
    _generation = gen;
    _pool.updateGeneration(gen);
  }

  void invalidatePendingDecodes(DecoderHolder holder) =>
      _pool.invalidateDecoder(holder.decoder.address);

  /// Attach decode driving to a holder. The holder will call back
  /// via [onNeedFrames] when it needs more frames decoded.
  void attach(DecoderHolder holder) {
    holder.onNeedFrames = () => _requestDecode(holder);
  }

  void _requestDecode(DecoderHolder holder) {
    // Adaptive batch: more when buffer is low, fewer when nearly full.
    final bufLen = holder.queuedFrameCount;
    final target = holder.state == PageState.current
        ? DecoderHolder._highWatermark
        : DecoderHolder._precacheTarget;
    final maxBatch = holder.state == PageState.current ? 6 : 4;
    final refillCount = (target - bufLen).clamp(1, maxBatch);
    holder._decodeInFlight = true;
    holder._dispatchGen = _generation;
    final token = holder._decodeToken;
    final job = webp.DecodeJob(
      generation: _generation,
      decoderAddress: holder.decoder.address,
      decoderEpoch: _pool.decoderEpoch(holder.decoder.address),
      isStreaming: holder.decoder.isStreaming,
      framesToDecode: refillCount,
      targetW: holder.targetW,
      targetH: holder.targetH,
      onComplete: (frames) => holder.onFramesDecoded(frames, token),
    );
    _pool.dispatch(
      job,
      holder.state == PageState.current
          ? webp.DecodePriority.current
          : webp.DecodePriority.next,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 4. DecoderManager — holder lifecycle + eviction
//
// [FIX] ResourceEntry management is now in PipelineController.
// DecoderManager focuses on holder creation, lookup, and eviction.
// ═══════════════════════════════════════════════════════════════

class DecoderManager {
  static final DecoderManager instance = DecoderManager._();
  DecoderManager._();

  final Map<String, DecoderHolder> _holders = {};
  final HolderDecodeService decodeService = HolderDecodeService();

  int get generation => decodeService.generation;

  // Page range for policy assignment to new holders.
  String _currentKey = '';
  final Set<String> _nextKeys = {};
  final Set<String> _lastKeys = {};
  final Set<String> _precacheKeys = {};
  InteractionState _interaction = InteractionState.idle;

  Timer? _evictionTimer;

  void setInteractionState(InteractionState state) {
    _interaction = state;
  }

  bool isCurrentImageKey(String imageKey) => _baseKey(imageKey) == _currentKey;
  bool isActiveImageKey(String imageKey) {
    final key = _baseKey(imageKey);
    return _currentKey.isEmpty ||
        key == _currentKey ||
        _nextKeys.contains(key) ||
        _lastKeys.contains(key) ||
        _precacheKeys.contains(key);
  }
  bool isCurrentHolder(DecoderHolder holder) =>
      _baseKey(holder.key) == _currentKey && holder.state == PageState.current;

  DecodedImageCache? cache;

  /// Extract bare imageKey from a fullKey (imageKey@WxH).
  static String _baseKey(String fullKey) {
    // The resolution suffix always has the form @WxH at the end.
    // Split on the last '@' — the imageKey itself may contain '@'
    // in rare URL cases, but the resolution suffix is always last.
    final at = fullKey.lastIndexOf('@');
    if (at < 0) return fullKey;
    final suffix = fullKey.substring(at + 1);
    // Verify it looks like WxH (digits, 'x', digits)
    if (RegExp(r'^\d+x\d+$').hasMatch(suffix)) {
      return fullKey.substring(0, at);
    }
    return fullKey;
  }

  // ── Holder management ──────────────────────────────────────

  DecoderHolder? getHolder(String key) => _holders[key];

  DecoderHolder getOrCreateHolder(
    String key,
    webp.WebPAnimDecoder decoder,
    int tw,
    int th,
    double scale,
  ) {
    _ensureEvictionTimer();
    final existing = _holders[key];
    if (existing != null && !existing.disposed) {
      decoder.dispose();
      return existing;
    }
    if (existing != null) {
      _holders.remove(key);
    }
    return _holders.putIfAbsent(key, () {
      final h = DecoderHolder(
        key: key,
        decoder: decoder,
        targetW: tw,
        targetH: th,
        scale: scale,
      );
      decodeService.attach(h);
      final bk = _baseKey(key);
      if (bk == _currentKey) {
        h.updateState(PageState.current);
        h.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.current),
        );
      } else if (_nextKeys.contains(bk) || _lastKeys.contains(bk)) {
        h.updateState(PageState.next);
        h.updatePolicy(ResourcePolicy.compute(_interaction, PagePriority.near));
      } else if (_precacheKeys.contains(bk)) {
        h.updateState(PageState.precache);
        h.updatePolicy(ResourcePolicy.compute(_interaction, PagePriority.far));
      }
      return h;
    });
  }

  // ── Page range tracking ────────────────────────────────────

  void setPageRange({
    required String currentKey,
    required Set<String> nextKeys,
    required Set<String> lastKeys,
    required Set<String> precacheKeys,
  }) {
    _currentKey = currentKey;
    _nextKeys
      ..clear()
      ..addAll(nextKeys);
    _lastKeys
      ..clear()
      ..addAll(lastKeys);
    _precacheKeys
      ..clear()
      ..addAll(precacheKeys);

    // Update holder states by matching base keys
    for (final e in _holders.entries) {
      final bk = _baseKey(e.key);
      if (bk == currentKey) {
        e.value.updateState(PageState.current);
        e.value.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.current),
        );
      } else if (nextKeys.contains(bk) || lastKeys.contains(bk)) {
        e.value.updateState(PageState.next);
        e.value.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.near),
        );
      } else if (precacheKeys.contains(bk)) {
        e.value.updateState(PageState.precache);
        e.value.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.far),
        );
      } else {
        e.value.updateState(PageState.precache);
        e.value.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.distant),
        );
      }
    }
  }

  void applyPolicyToHolder(
    String imageKey,
    ResourcePolicy policy,
    PagePriority priority,
  ) {
    for (final e in _holders.entries) {
      if (_baseKey(e.key) == imageKey && !e.value.disposed) {
        e.value.updateState(_priorityToPageState(priority));
        e.value.updatePolicy(policy);
        return;
      }
    }
  }

  // ── Eviction ───────────────────────────────────────────────

  void _ensureEvictionTimer() {
    _evictionTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _evictDistant(),
    );
  }

  void _cancelEvictionTimer() {
    _evictionTimer?.cancel();
    _evictionTimer = null;
  }

  void _evictDistant() {
    final now = _nowMs();
    final toRemove = <String>[];
    _holders.forEach((key, holder) {
      final bk = _baseKey(key);
      if (bk != _currentKey &&
          !_nextKeys.contains(bk) &&
          !_lastKeys.contains(bk) &&
          !_precacheKeys.contains(bk)) {
        if (now - holder.lastAccessTime > 2000) toRemove.add(key);
      }
    });
    for (final k in toRemove) {
      final h = _holders.remove(k);
      if (h != null) {
        debugPrint('[WebP] ${_short(k)} evicted (distant)');
        h.markPendingDispose();
      }
    }
    if (_holders.isEmpty) _cancelEvictionTimer();
  }

  // ── Lifecycle ──────────────────────────────────────────────

  void clearAll() {
    decodeService.updateGeneration(decodeService.generation + 1);
    _interaction = InteractionState.idle;
    for (final h in _holders.values) {
      h.dispose();
    }
    _holders.clear();
    _currentKey = '';
    _nextKeys.clear();
    _lastKeys.clear();
    _precacheKeys.clear();
    _cancelEvictionTimer();
  }
}

// ═══════════════════════════════════════════════════════════════
// 5. WebPImageProvider — Flutter ImageProvider
//
// [FIX] Simplified: delegates to PipelineController for resource
// state, uses decomposed ensureHolder steps.
// ═══════════════════════════════════════════════════════════════

class WebPImageProvider extends ImageProvider<WebPImageProvider> {
  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;
  final int targetWidth;
  final int targetHeight;
  final double scale;
  final DecodedImageCache? cache;

  const WebPImageProvider({
    required this.imageKey,
    this.sourceKey,
    required this.cid,
    required this.eid,
    this.targetWidth = 0,
    this.targetHeight = 0,
    this.scale = 1.0,
    this.cache,
  });

  String get _fullKey {
    if (targetWidth > 0 || targetHeight > 0) {
      return '$imageKey@${targetWidth}x$targetHeight';
    }
    return imageKey;
  }

  static (int, int) calculateTargetSize(BuildContext context) {
    final mq = MediaQuery.of(context);
    final dpr = mq.devicePixelRatio;
    final width = _alignDecodeDimension((mq.size.width * dpr).round());
    final height = _alignDecodeDimension((mq.size.height * dpr).round());
    return (width, height);
  }

  static int _alignDecodeDimension(int value, {int alignment = 8}) {
    if (value <= alignment) return math.max(1, value);
    final aligned = value - (value % alignment);
    return math.max(alignment, aligned);
  }

  static (int, int) _resolveDecodeTarget(
    webp.WebPImageInfo info,
    int boundWidth,
    int boundHeight,
  ) {
    if (boundWidth <= 0 && boundHeight <= 0) {
      return (info.width, info.height);
    }

    final bw = boundWidth > 0 ? boundWidth : info.width;
    final bh = boundHeight > 0 ? boundHeight : info.height;
    final scale = math.min(1.0, math.min(bw / info.width, bh / info.height));
    final tw = _alignDecodeDimension((info.width * scale).round());
    final th = _alignDecodeDimension((tw * info.height / info.width).round());
    return (math.min(tw, info.width), math.min(th, info.height));
  }

  static bool isLikelyWebP(String imageKey) =>
      imageKey.toLowerCase().contains('.webp');

  @override
  Future<WebPImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<WebPImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    WebPImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return _WebPImageStreamCompleter(
      _loadImageAsync(chunkEvents: chunkEvents),
      key,
      chunkEvents: chunkEvents.stream,
    );
  }

  // ── Image loading ──────────────────────────────────────────

  Future<_ImageResult> _loadImageAsync({
    StreamController<ImageChunkEvent>? chunkEvents,
    bool forceNetwork = false,
    bool disableStreaming = false,
  }) async {
    try {
      final existingHolder = DecoderManager.instance.getHolder(_fullKey);
      if (!forceNetwork &&
          !disableStreaming &&
          existingHolder != null &&
          !existingHolder.disposed) {
        if (existingHolder.decoder.isStreaming) {
          debugPrint(
            '[WebP-Stream][visible] REUSE-HOLDER ${existingHolder.shortKey} '
            'frames=${existingHolder.decoder.frameCount} decoded=${existingHolder.decodedFrameCount} '
            'buf=${existingHolder.bufferLength} raw=${existingHolder.queuedFrameCount - existingHolder.bufferLength} '
            'closed=${existingHolder.streamNeedsResume} failed=${existingHolder.streamFailed} '
            'loaded=${existingHolder.streamLoadedBytes}/${existingHolder.streamExpectedBytes ?? -1}',
          );
        }
        return _ImageResult.animated(existingHolder);
      }

      // L1 cache check (decoded ui.Image in memory)
      if (!forceNetwork && cache != null) {
        final cached = cache!.getL1(_fullKey);
        if (cached != null) {
          return _ImageResult.static(ImageInfo(image: cached, scale: scale));
        }
      }

      // Get bytes — check L2 cache first, then network / local file.
      Uint8List bytes;
      if (forceNetwork) {
        cache?.evictL2(imageKey);
        await CacheManager().delete('$imageKey@$sourceKey@$cid@$eid');
      }
      if (!forceNetwork && cache?.hasL2(imageKey) == true) {
        final cached = cache!.getL2(imageKey)!;
        if (ImageDownloader.isIncompleteWebPBytes(cached)) {
          cache!.evictL2(imageKey);
          bytes = Uint8List(0);
        } else {
          bytes = cached;
        }
      } else {
        bytes = Uint8List(0);
      }
      if (bytes.isEmpty) {
        final cachedBytes = forceNetwork
            ? null
            : await tryReadFromCache(imageKey, sourceKey, cid, eid);
        if (cachedBytes != null) {
          bytes = cachedBytes;
        } else {
          final progressive = disableStreaming
              ? null
              : await _tryLoadAnimatedStreaming(chunkEvents: chunkEvents);
          if (progressive?.holder != null) {
            return _ImageResult.animated(
              progressive!.holder!,
              progressiveSub: progressive.subscription,
            );
          }
          bytes =
              progressive?.bytes ?? await _fetchBytes(chunkEvents: chunkEvents);
          if (cache != null && webp.isWebP(bytes)) {
            cache!.putL2(imageKey, bytes);
          }
        }
      }

      // Check if WebP
      if (!webp.isWebP(bytes)) return _ImageResult.fallback(bytes);

      final info = webp.getInfo(bytes);
      if (info == null) return _ImageResult.error('Invalid WebP header');

      if (info.isAnimated) {
        final holder = await _createAnimatedHolder(bytes, info);
        if (holder != null) {
          PipelineController.instance.publishExternalHolder(
            imageKey,
            _fullKey,
            holder,
          );
          return _ImageResult.animated(holder);
        }
        return _ImageResult.error('Failed to create animated decoder');
      } else {
        final image = await _decodeStatic(bytes, info);
        if (image != null) {
          if (cache != null) cache!.putL1(_fullKey, image);
          return _ImageResult.static(ImageInfo(image: image, scale: scale));
        }
        return _ImageResult.error('WebP static decode failed');
      }
    } catch (e) {
      return _ImageResult.error(e);
    }
  }

  Future<_ProgressiveLoadResult?> _tryLoadAnimatedStreaming({
    StreamController<ImageChunkEvent>? chunkEvents,
  }) async {
    final decoder = webp.createStreamingAnimDecoder(
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    if (decoder == null) return null;

    final completer = Completer<_ProgressiveLoadResult?>();
    DecoderHolder? holder;
    Uint8List? finalBytes;
    var chunkCount = 0;
    var lastDebugBytes = 0;
    var lastFrameCount = -1;
    debugPrint('[WebP-Stream][visible] START ${_short(_fullKey)}');

    late StreamSubscription<ImageDownloadProgress> sub;
    sub = ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      debugLabel: 'webp-stream:$imageKey',
    ).listen(
      (event) {
        if (event.reset) {
          holder?.updateStreamTransfer(0, null, reset: true);
        } else {
          holder?.updateStreamTransfer(event.currentBytes, event.totalBytes);
        }
        PipelineController.instance.publishExternalDownloadProgress(
          imageKey,
          event.currentBytes,
          event.totalBytes,
          done: event.imageBytes != null,
        );
        if (chunkEvents != null &&
            !chunkEvents.isClosed &&
            event.chunkBytes == null) {
          chunkEvents.add(
            ImageChunkEvent(
              cumulativeBytesLoaded: event.currentBytes,
              expectedTotalBytes: event.totalBytes ?? 0,
            ),
          );
        }
        if (event.reset && !decoder.isDisposed) {
          debugPrint('[WebP-Stream][visible] RESET ${_short(_fullKey)}');
          decoder.resetStreamInput();
          holder?.clearBufferedFrames();
          holder?.resetStreamPlaybackState();
        }
        final chunk = event.chunkBytes;
        if (chunk != null && !decoder.isDisposed) {
          chunkCount++;
          if (chunkCount <= 3 ||
              event.currentBytes - lastDebugBytes >= 1024 * 1024) {
            lastDebugBytes = event.currentBytes;
            debugPrint(
              '[WebP-Stream][visible] chunk#$chunkCount '
              '+${chunk.length} loaded=${event.currentBytes}/${event.totalBytes ?? -1}',
            );
          }
          final ready = decoder.appendStreamChunk(chunk);
          if (ready && decoder.frameCount != lastFrameCount) {
            lastFrameCount = decoder.frameCount;
            debugPrint(
              '[WebP-Stream][visible] info animated=${decoder.streamIsAnimated} '
              'frames=${decoder.frameCount} ${decoder.targetWidth}x${decoder.targetHeight} '
              '${_short(_fullKey)}',
            );
          }
          if (ready && !decoder.streamIsAnimated) {
            debugPrint(
              '[WebP-Stream][visible] ready but static '
              '${decoder.targetWidth}x${decoder.targetHeight} ${_short(_fullKey)}',
            );
          }
          if (ready &&
              decoder.streamIsAnimated &&
              holder == null &&
              decoder.frameCount > 0 &&
              decoder.targetWidth > 0) {
            debugPrint(
              '[WebP-Stream][visible] READY animated '
              '${decoder.frameCount}f ${decoder.targetWidth}x${decoder.targetHeight} '
              '${_short(_fullKey)}',
            );
            holder = DecoderManager.instance.getOrCreateHolder(
              _fullKey,
              decoder,
              decoder.targetWidth,
              decoder.targetHeight,
              scale,
            );
            holder!.updateStreamTransfer(event.currentBytes, event.totalBytes);
            holder!.markStreamActive();
            PipelineController.instance.publishExternalHolder(
              imageKey,
              _fullKey,
              holder,
            );
            if (holder!.state == PageState.current) holder!.requestRefill();
            debugPrint('[WebP-Stream][visible] HOLDER ${_short(_fullKey)}');
            if (!completer.isCompleted) {
              completer.complete(
                _ProgressiveLoadResult.animated(holder!, sub),
              );
            }
          } else {
            if (holder?.state == PageState.current) holder?.requestRefill();
          }
        }
        final bytes = event.imageBytes;
        if (bytes != null) {
          finalBytes = bytes;
          holder?.updateStreamTransfer(bytes.length, bytes.length);
          debugPrint(
            '[WebP-Stream][visible] FINAL ${bytes.length}B '
            'holder=${holder != null} ${_short(_fullKey)}',
          );
          if (cache != null && webp.isWebP(bytes)) cache!.putL2(imageKey, bytes);
          PipelineController.instance.publishExternalBytes(imageKey, bytes);
          if (!decoder.isDisposed) {
            decoder.appendStreamChunk(Uint8List(0), isFinal: true);
          }
          if (holder?.state == PageState.current) holder?.requestRefill();
          if (!completer.isCompleted) {
            completer.complete(holder != null
                ? _ProgressiveLoadResult.animated(holder!, sub)
                : _ProgressiveLoadResult.bytes(bytes));
          }
        }
      },
      onError: (e) {
        debugPrint('[WebP-Stream][visible] ERROR ${_short(_fullKey)} $e');
        final h = holder;
        if (h != null && h.decoder.isStreaming && !h.decoder.streamIsComplete) {
          h.markStreamDownloadClosed(e);
        } else {
          h?.markStreamFailed(e);
        }
        if (!completer.isCompleted) completer.complete(null);
        if (holder == null && !decoder.isDisposed) decoder.dispose();
      },
      onDone: () {
        debugPrint(
          '[WebP-Stream][visible] DONE holder=${holder != null} '
          'final=${finalBytes?.length ?? 0} ${_short(_fullKey)}',
        );
        if (holder != null && finalBytes == null) {
          holder!.markStreamDownloadClosed(StateError('stream ended without final bytes'));
        }
        if (!completer.isCompleted) {
          final bytes = finalBytes;
          completer.complete(bytes == null
              ? null
              : holder != null
                  ? _ProgressiveLoadResult.animated(holder!, sub)
                  : _ProgressiveLoadResult.bytes(bytes));
        }
        if (holder == null && !decoder.isDisposed) decoder.dispose();
      },
      cancelOnError: false,
    );
    completer.future.whenComplete(() {
      if (holder == null && finalBytes != null) {
        sub.cancel();
        if (!decoder.isDisposed) decoder.dispose();
      }
    });
    return completer.future;
  }

  StreamSubscription<ImageDownloadProgress>? _resumeStreamingIntoHolder(
    DecoderHolder holder, {
    void Function()? onDone,
  }) {
    final decoder = holder.decoder;
    if (!decoder.isStreaming || decoder.isDisposed || decoder.streamIsComplete) {
      return null;
    }
    final resumeFromBytes = holder.streamLoadedBytes;
    final attachedByPipeline =
        PipelineController.instance.hasStreamDecodeAttached(_fullKey);
    final resumeExistingInput = resumeFromBytes > 0;
    var appendedUntil = resumeExistingInput ? resumeFromBytes : 0;
    debugPrint(
      '[WebP-Stream][visible] RESUME ${_short(_fullKey)} '
      'offset=$resumeFromBytes keep=$resumeExistingInput '
      'attached=$attachedByPipeline',
    );
    if (attachedByPipeline) {
      holder.markStreamActive();
      holder.requestRefill();
      return null;
    }
    if (resumeExistingInput) {
      final restarted = holder.restartAvailableStreamPlayback(minFrames: 1);
      debugPrint(
        '[WebP-Stream][visible] RESUME-RESTART ${_short(_fullKey)} '
        'ok=$restarted frames=${decoder.frameCount} decoded=${holder.decodedFrameCount} '
        'buf=${holder.bufferLength} '
        'raw=${holder.queuedFrameCount - holder.bufferLength} '
        'inFlight=${holder._decodeInFlight} uploading=${holder._isUploading}',
      );
    } else {
      decoder.resetStreamInput();
      holder.clearBufferedFrames();
      holder.resetStreamPlaybackState();
    }
    var chunkCount = 0;
    var lastDebugBytes = 0;
    var completed = false;
    var closedByPolicy = false;
    late StreamSubscription<ImageDownloadProgress> sub;
    sub = ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      debugLabel: 'webp-resume:$imageKey',
      resumeFromBytes: resumeExistingInput ? resumeFromBytes : null,
      resumeExpectedBytes: holder.streamExpectedBytes,
      replayPartial: !resumeExistingInput,
    ).listen(
      (event) {
        if (event.reset) {
          holder.updateStreamTransfer(0, null, reset: true);
        } else {
          holder.updateStreamTransfer(event.currentBytes, event.totalBytes);
        }
        PipelineController.instance.publishExternalDownloadProgress(
          imageKey,
          event.currentBytes,
          event.totalBytes,
          done: event.imageBytes != null,
        );
        holder.markStreamActive();
        if (!DecoderManager.instance.isActiveImageKey(imageKey)) {
          closedByPolicy = true;
          sub.cancel();
          onDone?.call();
          return;
        }
        if (event.reset && !decoder.isDisposed) {
          decoder.resetStreamInput();
          holder.clearBufferedFrames();
          holder.resetStreamPlaybackState();
        }
        final chunk = event.chunkBytes;
        if (chunk != null && !decoder.isDisposed) {
          final chunkEnd = event.currentBytes;
          final chunkStart = chunkEnd - chunk.length;
          if (chunkEnd <= appendedUntil) return;
          final data = chunkStart < appendedUntil
              ? Uint8List.sublistView(chunk, appendedUntil - chunkStart)
              : chunk;
          appendedUntil = chunkEnd;
          chunkCount++;
          if (chunkCount <= 3 ||
              event.currentBytes - lastDebugBytes >= 1024 * 1024) {
            lastDebugBytes = event.currentBytes;
            debugPrint(
              '[WebP-Stream][visible] resume-chunk#$chunkCount '
              '+${data.length} loaded=${event.currentBytes}/${event.totalBytes ?? -1} '
              '${_short(_fullKey)}',
            );
          }
          final ready = decoder.appendStreamChunk(data);
          if (ready) holder.requestRefill();
        }
        final bytes = event.imageBytes;
        if (bytes != null) {
          completed = true;
          holder.updateStreamTransfer(bytes.length, bytes.length);
          if (cache != null && webp.isWebP(bytes)) cache!.putL2(imageKey, bytes);
          PipelineController.instance.publishExternalBytes(imageKey, bytes);
          if (!decoder.isDisposed) {
            decoder.appendStreamChunk(
              appendedUntil == 0 ? bytes : Uint8List(0),
              isFinal: true,
            );
          }
          holder.requestRefill();
          onDone?.call();
        }
      },
      onError: (e) {
        debugPrint('[WebP-Stream][visible] RESUME-ERROR ${_short(_fullKey)} $e');
        holder.markStreamDownloadClosed(e);
        onDone?.call();
      },
      onDone: () {
        if (!completed && !closedByPolicy) {
          holder.markStreamDownloadClosed(StateError('resume ended without final bytes'));
        }
        onDone?.call();
      },
      cancelOnError: false,
    );
    return sub;
  }

  Future<Uint8List> _fetchBytes({
    StreamController<ImageChunkEvent>? chunkEvents,
  }) async {
    return fetchImageBytes(
      imageKey,
      sourceKey,
      cid,
      eid,
      chunkEvents: chunkEvents,
      debugLabel: 'webp-visible:$imageKey',
      onEvent: (event) {
        PipelineController.instance.publishExternalDownloadProgress(
          imageKey,
          event.currentBytes,
          event.totalBytes,
          done: event.imageBytes != null,
        );
      },
    );
  }

  /// Step 2: Create animated decoder holder from bytes.
  Future<DecoderHolder?> _createAnimatedHolder(
    Uint8List bytes,
    webp.WebPImageInfo info,
  ) async {
    final (tw, th) = _resolveDecodeTarget(info, targetWidth, targetHeight);

    try {
      final decoder = webp.createAnimDecoder(
        bytes,
        targetWidth: tw,
        targetHeight: th,
      );
      if (decoder == null) return null;
      return DecoderManager.instance.getOrCreateHolder(
        _fullKey,
        decoder,
        tw,
        th,
        scale,
      );
    } catch (_) {
      return null;
    }
  }

  /// Step 3: Decode static WebP to ui.Image.
  Future<ui.Image?> _decodeStatic(
    Uint8List bytes,
    webp.WebPImageInfo info,
  ) async {
    final (tw, th) = _resolveDecodeTarget(info, targetWidth, targetHeight);
    final frame = webp.decodeStatic(bytes, targetWidth: tw, targetHeight: th);
    if (frame == null) return null;
    return _rgbaToUiImage(frame.rgba, frame.width, frame.height);
  }

  Future<ui.Image> _rgbaToUiImage(Uint8List rgba, int w, int h) async {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  // ── Public static helpers ──────────────────────────────────

  /// Ensure a DecoderHolder exists. Used by PrecreateTask.
  /// [onlyIfCached]: if true, skip network fetch.
  static Future<DecoderHolder?> ensureHolder({
    required String imageKey,
    required String fullKey,
    DecodedImageCache? cache,
    String? sourceKey,
    required String cid,
    required String eid,
    int targetWidth = 0,
    int targetHeight = 0,
    double scale = 1.0,
    Uint8List? providedBytes,
    bool onlyIfCached = false,
  }) async {
    // Step 1: Find existing holder
    final existing = DecoderManager.instance.getHolder(fullKey);
    if (existing != null && !existing.disposed) return existing;

    // Step 2: Resolve bytes
    Uint8List? bytes = providedBytes;
    if (bytes == null && cache?.hasL2(imageKey) == true) {
      bytes = cache!.getL2(imageKey);
    }
    if (bytes == null) {
      if (onlyIfCached) return null;
      try {
        final fetched = await fetchImageBytes(
          imageKey,
          sourceKey,
          cid,
          eid,
          debugLabel: 'webp-holder',
        );
        bytes = fetched;
        if (cache != null && webp.isWebP(fetched)) {
          cache.putL2(imageKey, fetched);
        }
      } catch (_) {
        return null;
      }
    }
    if (!webp.isWebP(bytes)) return null;

    // Step 3: Create decoder
    final info = webp.getInfo(bytes);
    if (info == null || !info.isAnimated) return null;

    final (tw, th) = _resolveDecodeTarget(info, targetWidth, targetHeight);

    try {
      final decoder = webp.createAnimDecoder(
        bytes,
        targetWidth: tw,
        targetHeight: th,
      );
      if (decoder == null) return null;

      // Step 4: Publish holder
      final holder = DecoderManager.instance.getOrCreateHolder(
        fullKey,
        decoder,
        tw,
        th,
        scale,
      );
      debugPrint(
        '[WebP-HOLDER] ${_short(fullKey)} created '
        '(${bytes.length ~/ 1024}KB)',
      );
      return holder;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is WebPImageProvider &&
        imageKey == other.imageKey &&
        sourceKey == other.sourceKey &&
        cid == other.cid &&
        eid == other.eid &&
        targetWidth == other.targetWidth &&
        targetHeight == other.targetHeight;
  }

  @override
  int get hashCode =>
      Object.hash(imageKey, sourceKey, cid, eid, targetWidth, targetHeight);

  // ── Static entry points (called by reader UI) ──────────────

  static void onPageChanged({
    required int currentPageIndex,
    required List<String> images,
    required BuildContext context,
    required String cid,
    required String eid,
    required String? sourceKey,
    DecodedImageCache? cache,
  }) {
    DecoderManager.instance.cache = cache;
    DecoderManager.instance.decodeService.updateGeneration(
      DecoderManager.instance.generation + 1,
    );

    String fk(int i) => (i >= 0 && i < images.length) ? images[i] : '';
    final current = fk(currentPageIndex);
    PipelineController.instance.onWindowChanged =
        (currentKey, decodeNextKeys, decodePrevKeys, downloadOnlyKeys) {
          DecoderManager.instance.setPageRange(
            currentKey: currentKey,
            nextKeys: decodeNextKeys,
            lastKeys: decodePrevKeys,
            precacheKeys: downloadOnlyKeys,
          );

          if (cache != null) {
            cache.setActivePages(
              [
                currentKey,
                ...decodeNextKeys,
                ...decodePrevKeys,
              ].where((k) => k.isNotEmpty),
            );
          }
        };

    DecoderManager.instance.setPageRange(
      currentKey: current,
      nextKeys: const <String>{},
      lastKeys: const <String>{},
      precacheKeys: const <String>{},
    );
  }

  static void clearAll() => DecoderManager.instance.clearAll();

  static void setInteractionState(InteractionState state) {
    PipelineController.instance.setInteractionState(state);
    DecoderManager.instance.setInteractionState(state);
  }

  static bool get isJumpingInteraction =>
      PipelineController.instance.interactionState == InteractionState.jumping;
}

// ═══════════════════════════════════════════════════════════════
// 6. ImageStreamCompleter — simple, delegates animation to holder
// ═══════════════════════════════════════════════════════════════

class _WebPImageStreamCompleter extends ImageStreamCompleter
    with WidgetsBindingObserver {
  final WebPImageProvider _provider;
  bool _disposed = false;
  StreamSubscription<ImageChunkEvent>? _chunkSub;
  StreamSubscription<ImageDownloadProgress>? _progressiveSub;
  DecoderHolder? _activeHolder;

  _WebPImageStreamCompleter(
    Future<_ImageResult> future,
    this._provider, {
    Stream<ImageChunkEvent>? chunkEvents,
  }) {
    WidgetsBinding.instance.addObserver(this);
    if (chunkEvents != null) {
      _chunkSub = chunkEvents.listen((event) {
        if (!_disposed) reportImageChunkEvent(event);
      });
    }
    future.then(_onResult, onError: _onError);
  }

  @override
  void onDisposed() {
    WidgetsBinding.instance.removeObserver(this);
    _chunkSub?.cancel();
    _progressiveSub?.cancel();
    _disposed = true;
    super.onDisposed();
  }

  @override
  void didChangeAppLifecycleState(ui.AppLifecycleState state) {
    if (_disposed) return;
    if (state == ui.AppLifecycleState.resumed) {
      _activeHolder?.resumeFromLifecyclePause();
    }
  }

  void _onResult(_ImageResult result) {
    if (_disposed) {
      result.progressiveSub?.cancel();
      return;
    }
    switch (result.type) {
      case _ResultType.static:
        setImage(result.imageInfo!);
        break;
      case _ResultType.animated:
        _progressiveSub = result.progressiveSub;
        _startAnimationLoop(result.holder!);
        break;
      case _ResultType.fallback:
        _fallbackDecode(result.rawBytes!);
        break;
      case _ResultType.error:
        reportError(exception: result.error ?? 'Unknown error');
        break;
    }
  }

  void _onError(Object error, StackTrace? stack) {
    if (!_disposed) reportError(exception: error, stack: stack);
  }

  void _fallbackDecode(Uint8List bytes) {
    ui.instantiateImageCodec(bytes).then((codec) {
      codec.getNextFrame().then((frame) {
        if (!_disposed) {
          setImage(ImageInfo(image: frame.image, scale: _provider.scale));
        }
      });
    });
  }

  Future<DecoderHolder?> _reloadAndRestart(
    DecoderHolder oldHolder, {
    bool forceNetwork = false,
    bool forceFullDecode = false,
  }) async {
    if (_disposed) return null;
    try {
      await _progressiveSub?.cancel();
      _progressiveSub = null;
      if (forceNetwork) {
        _provider.cache?.evictL2(_provider.imageKey);
        await CacheManager().delete(
          '${_provider.imageKey}@${_provider.sourceKey}@${_provider.cid}@${_provider.eid}',
        );
      }
      oldHolder.dispose();
      final result = await _provider._loadImageAsync(
        forceNetwork: forceNetwork,
        disableStreaming: forceFullDecode,
      );
      if (_disposed) return null;
      if (result.type == _ResultType.animated) {
        _progressiveSub = result.progressiveSub;
        return result.holder;
      }
      if (result.type == _ResultType.static) setImage(result.imageInfo!);
    } catch (_) {
      // Reload failed silently; animation will stop.
    }
    return null;
  }

  void _startAnimationLoop(DecoderHolder initialHolder) async {
    DecoderHolder holder = initialHolder;
    _activeHolder = holder;
    var hasShownFirstFrame = false;
    var nullFrameWaits = 0;
    var resumeStartedAt = 0;
    while (!_disposed) {
      if (!hasListeners) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }
      try {
        final state = WidgetsBinding.instance.lifecycleState;
        if (state == ui.AppLifecycleState.paused ||
            state == ui.AppLifecycleState.hidden) {
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }
      } catch (_) {}

      final active = DecoderManager.instance.isActiveImageKey(
        _provider.imageKey,
      );
      if (!active) {
        if (_progressiveSub != null &&
            holder.decoder.isStreaming &&
            !holder.decoder.streamIsComplete) {
          debugPrint('[WebP-Stream][visible] PAUSE ${holder.shortKey}');
          await _progressiveSub?.cancel();
          _progressiveSub = null;
        }
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }

      if (holder.disposed) {
        _drainBuffer(holder);
        final nh = await _reloadAndRestart(holder);
        if (nh != null) {
          holder = nh;
          _activeHolder = holder;
          hasShownFirstFrame = false;
          nullFrameWaits = 0;
          continue;
        } else {
          break;
        }
      }

      final pipelineAttached =
          PipelineController.instance.hasStreamDecodeAttached(holder.key);
      if (holder.streamNeedsResume && _progressiveSub == null && !pipelineAttached) {
        debugPrint(
          '[WebP-Stream][visible] RESUME-CLOSED ${holder.shortKey} '
          'frames=${holder.decoder.frameCount} decoded=${holder.decodedFrameCount} '
          'buf=${holder.bufferLength} loaded=${holder.streamLoadedBytes}/${holder.streamExpectedBytes ?? -1} '
          '${holder.streamError}',
        );
        _progressiveSub = _provider._resumeStreamingIntoHolder(
          holder,
          onDone: () => _progressiveSub = null,
        );
        resumeStartedAt = _nowMs();
      } else if (holder.streamFailed) {
        debugPrint(
          '[WebP-Stream][visible] RELOAD failed-stream ${holder.shortKey} '
          '${holder.streamError}',
        );
        final canUseFinalBytes =
            holder.decoder.isStreaming && holder.decoder.streamIsComplete;
        final nh = await _reloadAndRestart(
          holder,
          forceNetwork: !canUseFinalBytes,
          forceFullDecode: canUseFinalBytes,
        );
        if (nh != null) {
          holder = nh;
          _activeHolder = holder;
          hasShownFirstFrame = false;
          nullFrameWaits = 0;
          continue;
        }
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      if (_progressiveSub == null &&
          holder.decoder.isStreaming &&
          !holder.decoder.streamIsComplete) {
        if (pipelineAttached) {
          holder.markStreamActive();
          holder.requestRefill();
        } else {
          _progressiveSub = _provider._resumeStreamingIntoHolder(
            holder,
            onDone: () => _progressiveSub = null,
          );
          resumeStartedAt = _nowMs();
        }
        holder.requestRefill();
      }

      final startupWatermark = hasShownFirstFrame
          ? 0
          : DecoderHolder._firstFrameWatermark;
      if (holder.bufferLength < startupWatermark &&
          holder.state == PageState.current) {
        holder.requestRefill();
        holder.refillSignal ??= Completer<void>();
        await Future.any([
          holder.refillSignal!.future,
          Future.delayed(const Duration(milliseconds: 200)),
        ]);
        continue;
      }

      final frame = holder.consumeFrame();
      if (frame == null) {
        nullFrameWaits++;
        final currentHolder = holder.state == PageState.current;
        if (currentHolder &&
            holder.decoder.isStreaming &&
            !holder.decoder.streamIsComplete &&
            holder._streamAtAvailableEnd &&
            nullFrameWaits >= (hasShownFirstFrame ? 1 : 3) &&
            holder.restartAvailableStreamPlayback()) {
          debugPrint('[WebP-Stream][visible] REPLAY-PARTIAL ${holder.shortKey}');
          hasShownFirstFrame = false;
          nullFrameWaits = 0;
          continue;
        }
        if (currentHolder &&
            holder.decoder.isStreaming &&
            !holder.decoder.streamIsComplete &&
            _progressiveSub != null &&
            nullFrameWaits >= 30 &&
            _nowMs() - resumeStartedAt > 1500) {
          debugPrint(
            '[WebP-Stream][visible] WAIT-DOWNLOAD ${holder.shortKey} '
            'frames=${holder.decoder.frameCount} decoded=${holder.decodedFrameCount} '
            'buf=${holder.bufferLength} raw=${holder.queuedFrameCount - holder.bufferLength} '
            'inFlight=${holder._decodeInFlight} uploading=${holder._isUploading} '
            'loaded=${holder.streamLoadedBytes}/${holder.streamExpectedBytes ?? -1}',
          );
          nullFrameWaits = 0;
        }
        if (currentHolder &&
            holder.decoder.isStreaming &&
            holder.decoder.streamIsComplete &&
            nullFrameWaits >= 6 &&
            holder._streamMayDecodeMore) {
          holder.markStreamFailed(StateError('stream ended before all frames'));
          continue;
        }
        if (holder.disposed) continue;
        holder.refillSignal ??= Completer<void>();
        await Future.any([
          holder.refillSignal!.future,
          Future.delayed(Duration(milliseconds: currentHolder ? 200 : 800)),
        ]);
        continue;
      }

      setImage(ImageInfo(image: frame.image, scale: holder.scale));
      hasShownFirstFrame = true;
      nullFrameWaits = 0;
      final rawDelay = frame.durationMs <= 0 ? 100 : frame.durationMs;
      final delay = rawDelay.clamp(16, 200);
      final bufferPressureDelay = _bufferPressureDelay(holder);
      await Future.delayed(
        Duration(
          milliseconds: (delay * bufferPressureDelay / webpPlaybackSpeed)
              .round(),
        ),
      );
    }
    if (_activeHolder == holder) {
      _activeHolder = null;
    }
  }

  double _bufferPressureDelay(DecoderHolder holder) {
    if (holder.state != PageState.current) return 1.0;
    final remaining = holder.bufferLength;
    if (remaining <= 1) return 1.3;
    if (remaining <= 3) return 1.2;
    if (remaining <= 5) return 1.1;
    return 1.0;
  }

  /// Dispose all frames remaining in a holder's buffer.
  void _drainBuffer(DecoderHolder h) {
    h.clearBufferedFrames();
  }
}

// ═══════════════════════════════════════════════════════════════
// 7. Result types
// ═══════════════════════════════════════════════════════════════

enum _ResultType { static, animated, fallback, error }

class _ImageResult {
  final _ResultType type;
  final ImageInfo? imageInfo;
  final DecoderHolder? holder;
  final Uint8List? rawBytes;
  final Object? error;
  final StreamSubscription<ImageDownloadProgress>? progressiveSub;

  _ImageResult._({
    required this.type,
    this.imageInfo,
    this.holder,
    this.rawBytes,
    this.error,
    this.progressiveSub,
  });

  factory _ImageResult.static(ImageInfo info) =>
      _ImageResult._(type: _ResultType.static, imageInfo: info);
  factory _ImageResult.animated(
    DecoderHolder holder, {
    StreamSubscription<ImageDownloadProgress>? progressiveSub,
  }) =>
      _ImageResult._(
        type: _ResultType.animated,
        holder: holder,
        progressiveSub: progressiveSub,
      );
  factory _ImageResult.fallback(Uint8List bytes) =>
      _ImageResult._(type: _ResultType.fallback, rawBytes: bytes);
  factory _ImageResult.error(Object e) =>
      _ImageResult._(type: _ResultType.error, error: e);
}

class _ProgressiveLoadResult {
  final DecoderHolder? holder;
  final Uint8List? bytes;
  final StreamSubscription<ImageDownloadProgress>? subscription;

  const _ProgressiveLoadResult._({this.holder, this.bytes, this.subscription});
  factory _ProgressiveLoadResult.animated(
    DecoderHolder holder,
    StreamSubscription<ImageDownloadProgress> subscription,
  ) =>
      _ProgressiveLoadResult._(holder: holder, subscription: subscription);
  factory _ProgressiveLoadResult.bytes(Uint8List bytes) =>
      _ProgressiveLoadResult._(bytes: bytes);
}
