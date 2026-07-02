import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

/// 基于 FFI libwebp 的 WebP 图像提供器。
///
/// 支持静态和动画 WebP，集成三级缓存。
///
/// 预缓存条目：解码器 + 已上传 GPU 的前 N 帧
class _PrecacheEntry {
  final webp.WebPAnimDecoder decoder;
  final List<ImageInfo> gpuFrames;
  final List<int> durations;
  final int page;
  _PrecacheEntry({required this.decoder, required this.gpuFrames, required this.durations, required this.page});
}

/// 基于 FFI libwebp 的 WebP 图像提供器。
///
/// 预缓存池：异步预解码前 N 帧并上传 GPU，显示时瞬间就绪。
/// 前一张 4 帧、后一张 5 帧、后二张 4 帧。FIFO 驱逐，max 5。
class WebPImageProvider extends ImageProvider<WebPImageProvider> {
  static final Map<String, _PrecacheEntry> _precachePool = {};
  static final List<String> _poolOrder = [];
  static const int _maxPoolSize = 7;
  static const int _maxPoolMemoryMB = 300;
  static final Set<String> _poolCreating = {};
  static final Map<String, int> _activeKeys = {}; // key → refcount，支持同图多实例
  static int _generation = 0;

  static void _addActiveKey(String key) {
    _activeKeys[key] = (_activeKeys[key] ?? 0) + 1;
  }

  static void _removeActiveKey(String key) {
    final count = _activeKeys[key];
    if (count == null) return;
    if (count <= 1) {
      _activeKeys.remove(key);
    } else {
      _activeKeys[key] = count - 1;
    }
  }

  /// 清空预缓存池，释放所有 decoder 和 GPU 帧。
  /// 不触碰 _activeKeys（活跃动画的 decoder 仍在使用中）。
  static void clearPool() {
    _generation++;
    for (final e in _precachePool.values) {
      for (final f in e.gpuFrames) {
        f.image.dispose();
      }
      e.decoder.dispose();
    }
    _precachePool.clear();
    _poolOrder.clear();
    _poolCreating.clear();
    debugPrint('[WebP-POOL] Cleared all precached decoders and GPU frames (gen=$_generation).');
  }

  /// 估算池中 GPU 帧 + C decoder 的总内存（MB）。
  /// 2x 安全系数：覆盖 GPU texture 对齐开销 + CPU side 副本。
  static double _estimatePoolMemoryMB() {
    double total = 0;
    for (final e in _precachePool.values) {
      final frameBytes = e.decoder.targetWidth * e.decoder.targetHeight * 4;
      // GPU 帧 + C decoder（composite canvas + 3 output bufs + frame_buf ≈ 5×）
      total += (e.gpuFrames.length + 5) * frameBytes;
    }
    return total / (1024 * 1024) * 2.0;
  }

  /// 预缓存的首批帧（已上传 GPU），_decodeAnimated 设置，_startAnimation 消费。
  List<ImageInfo>? preUploadedFrames;
  List<int>? preUploadedDurations;

  /// 预缓存：下载 + 解码器 + 前 [frameCount] 帧 decode + GPU upload。
  /// [l2Cache] 可选 L2 缓存引用，避免重复读取文件。
  static Future<void> precreateDecoder({
    required String imageKey,
    required String? sourceKey,
    required String cid,
    required String eid,
    required int targetWidth,
    required int targetHeight,
    required int frameCount,
    required double scale,
    DecodedImageCache? l2Cache,
    int page = 0,
  }) async {
    final key = '$imageKey@${targetWidth}x$targetHeight';
    if (_precachePool.containsKey(key) || _poolCreating.contains(key) || _activeKeys.containsKey(key)) return;
    _poolCreating.add(key);
    final gen = _generation;
    try {
      // 1. 获取原始字节（优先 L2 缓存，避免并发文件 I/O）
      Uint8List bytes;
      if (l2Cache != null && l2Cache.hasL2(imageKey)) {
        bytes = l2Cache.getL2(imageKey)!;
        debugPrint('[WebP-POOL] re-pooling $imageKey from L2 cache (${bytes.length}B)');
      } else if (imageKey.startsWith('file://')) {
        final f = File(imageKey.substring(7));
        if (!await f.exists()) { _poolCreating.remove(key); return; }
        bytes = await f.readAsBytes();
        if (_generation != gen) { _poolCreating.remove(key); return; }
      } else {
        final c = Completer<Uint8List>();
        late StreamSubscription sub;
        sub = ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid).listen(
          (e) { if (e.imageBytes != null) { c.complete(e.imageBytes!); sub.cancel(); } },
          onError: (_) { if (!c.isCompleted) c.completeError('download failed'); },
          cancelOnError: true,
        );
        try { bytes = await c.future; } catch (_) { _poolCreating.remove(key); return; }
        if (_generation != gen) { _poolCreating.remove(key); return; }
      }
      if (!webp.isWebP(bytes)) { _poolCreating.remove(key); return; }
      final info = webp.getInfo(bytes);
      if (info == null || !info.isAnimated) { _poolCreating.remove(key); return; }

      // 存入 L2 缓存，避免 _loadImageAsync 重复下载
      if (l2Cache != null) l2Cache.putL2(imageKey, bytes);

      // 2. 创建解码器
      final decoder = webp.createAnimDecoder(bytes, targetWidth: targetWidth, targetHeight: targetHeight);
      if (decoder == null) { _poolCreating.remove(key); return; }

      // 3. 异步预解码 + 上传前 frameCount 帧到 GPU
      final gpuFrames = <ImageInfo>[];
      final durations = <int>[];
      for (int i = 0; i < frameCount; i++) {
        final addr = await decoder.getNextFrameAsync();
        if (addr == null) break;
        final len = decoder.targetWidth * decoder.targetHeight * 4;
        final rgba = Pointer<Uint8>.fromAddress(addr.address).asTypedList(len);
        final c = Completer<ImageInfo>();
        ui.decodeImageFromPixels(rgba, decoder.targetWidth, decoder.targetHeight,
            ui.PixelFormat.rgba8888, (img) => c.complete(ImageInfo(image: img, scale: scale)));
        final info = await c.future;
        gpuFrames.add(info);
        durations.add(addr.durationMs <= 10 ? 33 : addr.durationMs);
      }
      if (gpuFrames.isEmpty) { decoder.dispose(); _poolCreating.remove(key); return; }
      if (_generation != gen) {
        for (final f in gpuFrames) { f.image.dispose(); }
        decoder.dispose();
        _poolCreating.remove(key);
        return;
      }

      // 4. 存入池
      final entry = _PrecacheEntry(decoder: decoder, gpuFrames: gpuFrames, durations: durations, page: page);
      _precachePool[key] = entry;
      _poolOrder.add(key);
      // LRU 驱逐：按数量或内存阈值，驱逐离当前页最远的条目
      while (_poolOrder.length > _maxPoolSize ||
             (_poolOrder.length > 1 && _estimatePoolMemoryMB() > _maxPoolMemoryMB)) {
        // 找到离 page 最远的 key
        String? evictKey;
        int maxDist = -1;
        for (final k in _poolOrder) {
          final e = _precachePool[k];
          if (e == null) continue;
          final dist = (e.page - page).abs();
          if (dist > maxDist) { maxDist = dist; evictKey = k; }
        }
        if (evictKey == null) break;
        _poolOrder.remove(evictKey);
        final old = _precachePool.remove(evictKey);
        if (old != null) {
          for (final f in old.gpuFrames) { f.image.dispose(); }
          old.decoder.dispose();
        }
      }
      debugPrint('[WebP-POOL] precached ${gpuFrames.length} frames for $key (pool=${_precachePool.length} est=${_estimatePoolMemoryMB().toStringAsFixed(0)}MB)');
    } catch (e) {
      debugPrint('[WebP-POOL] failed for $imageKey: $e');
    } finally {
      _poolCreating.remove(key);
    }
  }

  /// 取出预缓存条目。返回 null 表示未命中。
  static _PrecacheEntry? takePrecached(String imageKey, int targetWidth, int targetHeight) {
    final key = '$imageKey@${targetWidth}x$targetHeight';
    final e = _precachePool.remove(key);
    if (e != null) {
      _poolOrder.remove(key);
      _addActiveKey(key);
      debugPrint('[WebP-POOL] hit ${e.gpuFrames.length} frames for $key (pool=${_precachePool.length})');
    }
    return e;
  }

  /// 活跃解码器已释放，允许该 key 重新入池。
  static void releaseActiveKey(String imageKey, int targetWidth, int targetHeight) {
    _removeActiveKey('$imageKey@${targetWidth}x$targetHeight');
  }

  /// 强制释放指定 key 的活跃解码器（用于滑动窗口外的旧页面）。
  static void disposeActiveKey(String imageKey, int targetWidth, int targetHeight) {
    final key = '$imageKey@${targetWidth}x$targetHeight';
    _removeActiveKey(key);
    final old = _precachePool.remove(key);
    if (old != null) {
      for (final f in old.gpuFrames) { f.image.dispose(); }
      old.decoder.dispose();
    }
  }
  WebPImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.cache,
    this.targetWidth = 1080,
    this.targetHeight = 1920,
    this.scale = 1.0,
  });

  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;
  final int page;
  final DecodedImageCache? cache;
  final int targetWidth;
  final int targetHeight;
  final double scale; // ImageInfo.scale = 1/dpr，使 1 图像像素=1 物理像素

  @override
  Future<WebPImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<WebPImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
      WebPImageProvider key, ImageDecoderCallback decode) {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    debugPrint('[WebP-LOAD] loadImage called for ${key.imageKey}');
    final completer = _WebPImageStreamCompleter(_loadImageAsync(), key);
    completer._loadStartMs = t0;
    return completer;
  }

  Future<_ImageResult> _loadImageAsync() async {
    final sw = Stopwatch()..start();

    // ── 1. 预缓存池（最快路径：已预解码 GPU 帧，无需任何 I/O） ──
    final precached = WebPImageProvider.takePrecached(imageKey, targetWidth, targetHeight);
    if (precached != null) {
      preUploadedFrames = precached.gpuFrames;
      preUploadedDurations = precached.durations;
      debugPrint('[WebP-E2E] pool hit: ${sw.elapsedMilliseconds}ms');
      return _ImageResult.animated(precached.decoder);
    }

    // ── 2. L1 缓存（静态 WebP 的 GPU 纹理） ──
    if (cache != null) {
      final cached = cache!.getL1(imageKey);
      if (cached != null) {
        return _ImageResult.static(ImageInfo(image: cached));
      }
    }

    // ── 3. L2 缓存 → 获取原始字节（pool miss 时才需要） ──
    Uint8List rawBytes;
    if (cache != null && cache!.hasL2(imageKey)) {
      rawBytes = cache!.getL2(imageKey)!;
    } else {
      rawBytes = await _fetchBytes();
      if (cache != null && webp.isWebP(rawBytes)) {
        cache!.putL2(imageKey, rawBytes);
      }
    }

    // ── 4. 格式校验 → 解码 ──
    if (!webp.isWebP(rawBytes)) {
      return _ImageResult.fallback(rawBytes);
    }
    final info = webp.getInfo(rawBytes);
    if (info == null) {
      return _ImageResult.error('Failed to parse WebP header');
    }

    if (info.isAnimated) {
      return _decodeAnimated(rawBytes);
    } else {
      return _decodeStatic(rawBytes);
    }
  }

  Future<_ImageResult> _decodeStatic(Uint8List rawBytes) {
    final frame = webp.decodeStatic(rawBytes,
        targetWidth: targetWidth, targetHeight: targetHeight);
    if (frame == null) {
      return Future.value(_ImageResult.error('Failed to decode static WebP'));
    }

    final completer = Completer<_ImageResult>();
    try {
      ui.decodeImageFromPixels(
        frame.rgba,
        frame.width,
        frame.height,
        ui.PixelFormat.rgba8888,
        (image) {
          // 存入 L1
          if (cache != null) {
            cache!.putL1(imageKey, image);
          }
          completer.complete(_ImageResult.static(ImageInfo(image: image)));
        },
      );
    } catch (e) {
      completer.complete(_ImageResult.error('Failed to create ui.Image: $e'));
    }
    return completer.future;
  }

  Future<_ImageResult> _decodeAnimated(Uint8List rawBytes) async {
    // 池查找已在上层 _loadImageAsync 完成，此处仅处理 pool miss
    final sw = Stopwatch()..start();
    final decoder = webp.createAnimDecoder(rawBytes,
        targetWidth: targetWidth, targetHeight: targetHeight);
    if (decoder == null) return _ImageResult.error('Failed to create anim decoder');
    debugPrint('[WebP] createAnimDecoder: ${sw.elapsedMilliseconds}ms, ${decoder.frameCount}frames, target=${decoder.targetWidth}x${decoder.targetHeight}');
    return _ImageResult.animated(decoder);
  }

  // ─── 内部方法 ───

  Future<Uint8List> _fetchBytes() async {
    if (imageKey.startsWith('file://')) {
      final file = File(imageKey.substring(7));
      return await file.readAsBytes();
    }

    Uint8List? result;
    await for (final event
        in ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid)) {
      if (event.imageBytes != null) {
        result = event.imageBytes!;
        break;
      }
    }
    if (result == null) {
      throw Exception('Failed to load image: $imageKey');
    }
    return result;
  }

  String get key => 'webp:$imageKey@$sourceKey@$cid@$eid@$page';

  @override
  bool operator ==(Object other) {
    return other is WebPImageProvider && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'WebPImageProvider($key)';
}

// ═══════════════════════════════════════════════════════════════
// Isolate 预解码函数（必须为顶级函数）
// ═══════════════════════════════════════════════════════════════

/// 在 Isolate 中同步解码所有帧，返回 [rgba, durationMs] 列表。
@pragma('vm:entry-point')
List<Map<String, dynamic>>? _decodeAllFramesSync(
    Uint8List bytes, int targetW, int targetH) {
  final decoder = webp.createAnimDecoder(bytes,
      targetWidth: targetW, targetHeight: targetH);
  if (decoder == null) return null;

  final frames = <Map<String, dynamic>>[];
  while (decoder.hasMoreFrames) {
    final frame = decoder.getNextFrame();
    if (frame == null) break;
    frames.add({
      'rgba': frame.rgba,
      'durationMs': frame.durationMs,
    });
  }
  // 所有帧同尺寸，加在第一条
  if (frames.isNotEmpty) {
    frames[0]['w'] = decoder.targetWidth;
    frames[0]['h'] = decoder.targetHeight;
  }
  decoder.dispose();
  return frames;
}

// ═══════════════════════════════════════════════════════════════
// Stream Completer
// ═══════════════════════════════════════════════════════════════

/// 全局 WebP 动画播放速度。
double webpPlaybackSpeed = 1.0;
const List<double> webpSpeedPresets = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

class _WebPImageStreamCompleter extends ImageStreamCompleter {
  final WebPImageProvider _provider;
  bool _disposed = false;
  int _loadStartMs = 0;

  void Function()? _disposeDecoder;

  _WebPImageStreamCompleter(Future<_ImageResult> future, this._provider) {
    future.then(_onResult, onError: _onError);
  }

  void _onResult(_ImageResult result) {
    if (_disposed) {
      if (result.type == _ResultType.animated) {
        result.decoder?.dispose();
        WebPImageProvider._removeActiveKey(
          '${_provider.imageKey}@${_provider.targetWidth}x${_provider.targetHeight}');
      }
      return;
    }
    switch (result.type) {
      case _ResultType.static:
        setImage(result.imageInfo!);
        break;
      case _ResultType.animated:
        final wasFromPool = _provider.preUploadedFrames != null;
        _startAnimation(result.decoder!,
            preUploaded: _provider.preUploadedFrames,
            preDurations: _provider.preUploadedDurations,
            fromPool: wasFromPool);
        _provider.preUploadedFrames = null;
        _provider.preUploadedDurations = null;
        break;
      case _ResultType.fallback:
        _fallbackDecode(result.rawBytes!);
        break;
      case _ResultType.error:
        reportError(
          context: ErrorDescription('WebPImageProvider(${_provider.key})'),
          exception: result.error ?? 'Unknown error',
        );
        break;
    }
  }

  void _onError(Object error, StackTrace? stack) {
    if (_disposed) return;
    reportError(
      context: ErrorDescription('WebPImageProvider(${_provider.key})'),
      exception: error,
      stack: stack,
    );
  }

  void _fallbackDecode(Uint8List bytes) {
    ui.instantiateImageCodec(bytes).then((codec) {
      codec.getNextFrame().then((frameInfo) {
        if (!_disposed) setImage(ImageInfo(image: frameInfo.image));
      });
    }).catchError((error) {
      if (!_disposed) {
        reportError(context: ErrorDescription('Fallback decode failed'), exception: error);
      }
    });
  }

  void _startAnimation(webp.WebPAnimDecoder decoder,
      {List<ImageInfo>? preUploaded, List<int>? preDurations, bool fromPool = false}) {
    debugPrint('[WebP-ANIM] _startAnimation called (pre=${preUploaded?.length ?? 0})');
    if (!fromPool) {
      final poolKey = '${_provider.imageKey}@${_provider.targetWidth}x${_provider.targetHeight}';
      WebPImageProvider._addActiveKey(poolKey);
    }
    var isActive = true;
    webp.WebPAnimFrameAddress? pendingFrame;
    bool fetching = false;
    int consecutiveNullFrames = 0;
    int frameIndex = 0;
    bool pendingDispose = false;
    bool disposeDone = false;
    int preIndex = -1; // 最后一个已传给 setImage 的 preUploaded 帧索引

    void doDispose() {
      if (disposeDone) return;
      disposeDone = true;
      if (!isActive) return;
      isActive = false;
      _disposeDecoder = null;
      final poolKey = '${_provider.imageKey}@${_provider.targetWidth}x${_provider.targetHeight}';
      WebPImageProvider._removeActiveKey(poolKey);
      // 释放未消费的 preUploaded 帧（从未传给 setImage，GPU 安全释放）
      if (preUploaded != null && preIndex >= -1) {
        for (int j = preIndex + 1; j < preUploaded.length; j++) {
          preUploaded[j].image.dispose();
        }
      }
      decoder.dispose();
    }

    void stopAnimation() {
      if (!isActive) return;
      if (fetching) { pendingDispose = true; return; }
      doDispose();
    }

    _disposeDecoder = stopAnimation;

    /// 缓存的解码 Future（复用 + 直接 await，消除 2ms 轮询）
    Future<void>? _currentFetch;

    Future<void> fetchNext() {
      if (_currentFetch != null) return _currentFetch!;
      if (!isActive || _disposed) return Future.value();

      fetching = true;
      _currentFetch = () async {
        try {
          if (!decoder.hasMoreFrames) decoder.reset();
          final result = await decoder.getNextFrameAsync();
          if (result != null) {
            pendingFrame = result;
            consecutiveNullFrames = 0;
          } else {
            consecutiveNullFrames++;
            if (consecutiveNullFrames > 3) stopAnimation();
          }
        } catch (_) {
          consecutiveNullFrames++;
        } finally {
          fetching = false;
          _currentFetch = null;
          if (pendingDispose) { pendingDispose = false; doDispose(); }
        }
      }();
      return _currentFetch!;
    }

    Future<void> playNext() async {
      if (!isActive || _disposed) { stopAnimation(); return; }

      // 无监听者 → 低功耗挂起，200ms 后重检
      if (!hasListeners) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (isActive && !_disposed) { Future.microtask(playNext); }
        else { stopAnimation(); }
        return;
      }

      // 直接 await 解码任务（消除 2ms 轮询）
      if (pendingFrame == null && isActive && !_disposed) {
        await fetchNext();
      }
      if (!isActive || _disposed || pendingFrame == null) { stopAnimation(); return; }

      final frame = pendingFrame!;
      pendingFrame = null;
      final int minFrameMs = 16;
      final int rawDuration = frame.durationMs <= 5 ? 33 : frame.durationMs.clamp(minFrameMs, 500);
      final int duration = (rawDuration / webpPlaybackSpeed).round().clamp(minFrameMs, 500);
      final int length = decoder.targetWidth * decoder.targetHeight * 4;
      final rgba = Pointer<Uint8>.fromAddress(frame.address).asTypedList(length);
      final int t0 = DateTime.now().millisecondsSinceEpoch;

      ui.decodeImageFromPixels(rgba, decoder.targetWidth, decoder.targetHeight,
        ui.PixelFormat.rgba8888, (image) {
          if (!isActive || _disposed) { image.dispose(); stopAnimation(); return; }
          setImage(ImageInfo(image: image, scale: _provider.scale));
          final int elapsed = DateTime.now().millisecondsSinceEpoch - t0;
          final int delay = (duration - elapsed).clamp(8, duration);
          frameIndex++;
          // GPU 已完成读取 C buffer，现在安全启动下一帧解码
          if (isActive && !_disposed) { fetchNext(); }
          Future.delayed(Duration(milliseconds: delay), playNext);
        });
    }

    if (preUploaded != null && preUploaded.isNotEmpty && preDurations != null) {
      // 预上传帧已在 GPU，直接展示无延迟
      final frames = preUploaded;
      final durs = preDurations;
      void playPreUploaded() {
        if (!isActive || _disposed || preIndex + 1 >= frames.length) {
          if (isActive && !_disposed) fetchNext().then((_) { Future.microtask(playNext); });
          return;
        }
        preIndex++;
        if (preIndex == 0) {
          final e2e = DateTime.now().millisecondsSinceEpoch - _loadStartMs;
          debugPrint('[WebP-E2E] load-to-first-frame(preupload)=${e2e}ms');
        }
        setImage(frames[preIndex]);
        frameIndex = preIndex + 1;
        if (preIndex + 1 < frames.length) {
          final d = durs.length > preIndex ? durs[preIndex] : 33;
          Future.delayed(Duration(milliseconds: d.clamp(8, d)), playPreUploaded);
        } else {
          // 等 pipeline 帧解码完成再调度 playNext，消除过渡停顿
          fetchNext().then((_) {
            final lastDur = durs.isNotEmpty ? durs.last : 33;
            Future.delayed(Duration(milliseconds: lastDur.clamp(8, lastDur)), playNext);
          });
        }
      }
      playPreUploaded();
    } else {
      fetchNext().then((_) { Future.microtask(playNext); });
    }
  }

  @override
  void onDisposed() {
    _disposed = true;
    _disposeDecoder?.call();
    _disposeDecoder = null;
    super.onDisposed();
  }
}

// ═══════════════════════════════════════════════════════════════
// 内部类型
// ═══════════════════════════════════════════════════════════════

enum _ResultType { static, animated, fallback, error }

class _ImageResult {
  final _ResultType type;
  final ImageInfo? imageInfo;
  final webp.WebPAnimDecoder? decoder;
  final Uint8List? rawBytes;
  final Object? error;

  _ImageResult._({
    required this.type,
    this.imageInfo,
    this.decoder,
    this.rawBytes,
    this.error,
  });

  factory _ImageResult.static(ImageInfo info) =>
      _ImageResult._(type: _ResultType.static, imageInfo: info);

  factory _ImageResult.animated(webp.WebPAnimDecoder decoder,
          {List<ImageInfo>? preUploaded, List<int>? preDurations}) =>
      _ImageResult._(type: _ResultType.animated, decoder: decoder,
          imageInfo: preUploaded?.isNotEmpty == true ? preUploaded!.first : null);

  factory _ImageResult.fallback(Uint8List bytes) =>
      _ImageResult._(type: _ResultType.fallback, rawBytes: bytes);

  factory _ImageResult.error(Object e) =>
      _ImageResult._(type: _ResultType.error, error: e);
}
