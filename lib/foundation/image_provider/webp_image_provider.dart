import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;
import 'dart:ffi';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
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
    return '${digits.substring(digits.length - 2)}.webp';
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
  int get bufferLength => _frameBuffer.length;

  bool _disposed = false;
  bool get disposed => _disposed;
  bool _pendingDispose = false;

  int lastAccessTime = 0;
  int decodedFrameCount = 0;
  int uploadedFrameCount = 0;

  bool _decodeInFlight = false;
  bool _isUploading = false;
  List<webp.WebPAnimFrameAddress>? _pendingUploadAddrs;
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
    _requestFramesIfNeeded();
  }

  void updatePolicy(ResourcePolicy newPolicy) {
    if (_disposed) return;
    if (_policy.allowDecode == newPolicy.allowDecode &&
        _policy.allowGpuUpload == newPolicy.allowGpuUpload) {
      return;
    }
    _policy = newPolicy;
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
    _requestFramesIfNeeded();
    return frame;
  }

  /// [FIX] Delegates to external [onNeedFrames] instead of calling
  /// WorkerPoolScheduler directly.
  void _requestFramesIfNeeded() {
    if (_disposed || _pendingDispose) return;
    if (!_policy.allowDecode || !_policy.allowGpuUpload) return;
    if (_decodeInFlight) return;
    if (_isUploading) return;
    if (_pendingUploadAddrs != null) return;

    final target = _state == PageState.current
        ? _highWatermark
        : _precacheTarget;
    final low = _state == PageState.current ? _lowWatermark : 0;
    if (_frameBuffer.length <= low && _frameBuffer.length < target) {
      onNeedFrames?.call();
    }
  }

  // ── Decode callback (called by HolderDecodeService) ─────────

  /// Called by [HolderDecodeService] with decoded frame addresses.
  void onFramesDecoded(List<webp.WebPAnimFrameAddress> frames) {
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
    _scheduleUpload(
      frames,
      frames.length,
      frames.first.durationMs,
      frames.last.durationMs,
    );
    _requestFramesIfNeeded();
  }

  /// Generation at the time the last decode was dispatched.
  int _dispatchGen = 0;

  // ── GPU Upload ─────────────────────────────────────────────

  void _scheduleUpload(
    List<webp.WebPAnimFrameAddress> addrs,
    int n,
    int t0,
    int t1,
  ) {
    if (_isUploading) {
      final old = _pendingUploadAddrs;
      if (old != null) {
        for (final f in old) {
          webp.nativePoolRelease(f.address);
        }
      }
      _pendingUploadAddrs = addrs;
      return;
    }
    _doUpload(addrs, n);
  }

  Future<void> _doUpload(List<webp.WebPAnimFrameAddress> addrs, int n) async {
    _isUploading = true;
    final outW = decoder.targetWidth;
    final outH = decoder.targetHeight;
    for (int i = 0; i < n; i++) {
      if (_disposed || _pendingDispose || !_policy.allowGpuUpload) {
        _releaseRemainingBuffers(addrs, i);
        break;
      }
      final addr = addrs[i];
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
    }
    _isUploading = false;
    _completeRefillWaiters();
    if (_pendingUploadAddrs != null) {
      final pending = _pendingUploadAddrs!;
      _pendingUploadAddrs = null;
      _doUpload(pending, pending.length);
    } else {
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

  void _releaseRemainingBuffers(
    List<webp.WebPAnimFrameAddress> addrs,
    int from,
  ) {
    for (int i = from; i < addrs.length; i++) {
      webp.nativePoolRelease(addrs[i].address);
    }
  }

  void clearBufferedFrames() {
    for (final f in _frameBuffer) {
      f.image.dispose();
    }
    _frameBuffer.clear();
    _notifyCurrentBuffer();
  }

  void resumeFromLifecyclePause() {
    if (_disposed || _pendingDispose) return;
    _completeRefillWaiters();
    requestRefill();
  }

  void requestRefill() {
    if (_disposed || _pendingDispose) return;
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

  /// Attach decode driving to a holder. The holder will call back
  /// via [onNeedFrames] when it needs more frames decoded.
  void attach(DecoderHolder holder) {
    holder.onNeedFrames = () => _requestDecode(holder);
  }

  void _requestDecode(DecoderHolder holder) {
    // Adaptive batch: more when buffer is low, fewer when nearly full.
    final bufLen = holder.bufferLength;
    final target = holder.state == PageState.current
        ? DecoderHolder._highWatermark
        : DecoderHolder._precacheTarget;
    final maxBatch = holder.state == PageState.current ? 6 : 4;
    final refillCount = (target - bufLen).clamp(1, maxBatch);
    holder._decodeInFlight = true;
    holder._dispatchGen = _generation;
    final job = webp.DecodeJob(
      generation: _generation,
      decoderAddress: holder.decoder.address,
      framesToDecode: refillCount,
      targetW: holder.targetW,
      targetH: holder.targetH,
      onComplete: (frames) => holder.onFramesDecoded(frames),
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
  }) async {
    try {
      final existingHolder = DecoderManager.instance.getHolder(_fullKey);
      if (existingHolder != null && !existingHolder.disposed) {
        return _ImageResult.animated(existingHolder);
      }

      // L1 cache check (decoded ui.Image in memory)
      if (cache != null) {
        final cached = cache!.getL1(_fullKey);
        if (cached != null) {
          return _ImageResult.static(ImageInfo(image: cached, scale: scale));
        }
      }

      // Get bytes — check L2 cache first, then network / local file.
      Uint8List bytes;
      if (cache?.hasL2(imageKey) == true) {
        bytes = cache!.getL2(imageKey)!;
      } else {
        bytes = await _fetchBytes(chunkEvents: chunkEvents);
        if (cache != null && webp.isWebP(bytes)) {
          cache!.putL2(imageKey, bytes);
        }
      }

      // Check if WebP
      if (!webp.isWebP(bytes)) return _ImageResult.fallback(bytes);

      final info = webp.getInfo(bytes);
      if (info == null) return _ImageResult.error('Invalid WebP header');

      if (info.isAnimated) {
        final holder = await _createAnimatedHolder(bytes, info);
        if (holder != null) return _ImageResult.animated(holder);
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

  Future<Uint8List> _fetchBytes({
    StreamController<ImageChunkEvent>? chunkEvents,
  }) async {
    return fetchImageBytes(
      imageKey,
      sourceKey,
      cid,
      eid,
      chunkEvents: chunkEvents,
      debugLabel: 'webp-visible',
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
    if (_disposed) return;
    switch (result.type) {
      case _ResultType.static:
        setImage(result.imageInfo!);
        break;
      case _ResultType.animated:
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

  Future<DecoderHolder?> _reloadAndRestart(DecoderHolder oldHolder) async {
    if (_disposed) return null;
    try {
      final result = await _provider._loadImageAsync();
      if (_disposed) return null;
      if (result.type == _ResultType.animated) return result.holder;
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

      if (holder.disposed) {
        _drainBuffer(holder);
        final nh = await _reloadAndRestart(holder);
        if (nh != null) {
          holder = nh;
          _activeHolder = holder;
          hasShownFirstFrame = false;
          continue;
        } else {
          break;
        }
      }

      final startupWatermark = hasShownFirstFrame
          ? 0
          : DecoderHolder._firstFrameWatermark;
      if (holder.bufferLength < startupWatermark &&
          holder.state == PageState.current) {
        holder.requestRefill();
        holder.refillSignal ??= Completer<void>();
        await holder.refillSignal!.future;
        continue;
      }

      final frame = holder.consumeFrame();
      if (frame == null) {
        if (holder.disposed) continue;
        holder.refillSignal ??= Completer<void>();
        await holder.refillSignal!.future;
        continue;
      }

      setImage(ImageInfo(image: frame.image, scale: holder.scale));
      hasShownFirstFrame = true;
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
    // Clear stale frames so they don't corrupt the next page
    if (_activeHolder == holder) {
      _activeHolder = null;
    }
    _drainBuffer(holder);
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

  _ImageResult._({
    required this.type,
    this.imageInfo,
    this.holder,
    this.rawBytes,
    this.error,
  });

  factory _ImageResult.static(ImageInfo info) =>
      _ImageResult._(type: _ResultType.static, imageInfo: info);
  factory _ImageResult.animated(DecoderHolder holder) =>
      _ImageResult._(type: _ResultType.animated, holder: holder);
  factory _ImageResult.fallback(Uint8List bytes) =>
      _ImageResult._(type: _ResultType.fallback, rawBytes: bytes);
  factory _ImageResult.error(Object e) =>
      _ImageResult._(type: _ResultType.error, error: e);
}
