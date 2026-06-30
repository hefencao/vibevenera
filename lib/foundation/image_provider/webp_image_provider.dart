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
  _PrecacheEntry({required this.decoder, required this.gpuFrames, required this.durations});
}

/// 基于 FFI libwebp 的 WebP 图像提供器。
///
/// 预缓存池：异步预解码前 N 帧并上传 GPU，显示时瞬间就绪。
/// 前一张 4 帧、后一张 5 帧、后二张 4 帧。FIFO 驱逐，max 5。
class WebPImageProvider extends ImageProvider<WebPImageProvider> {
  static final Map<String, _PrecacheEntry> _precachePool = {};
  static final List<String> _poolOrder = [];
  static const int _maxPoolSize = 5;
  static final Set<String> _poolCreating = {};
  static final Set<String> _activeKeys = {}; // 活跃中的 key，已取出防重复入池

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
  }) async {
    final key = '$imageKey@${targetWidth}x$targetHeight';
    if (_precachePool.containsKey(key) || _poolCreating.contains(key) || _activeKeys.contains(key)) return;
    _poolCreating.add(key);
    try {
      // 1. 获取原始字节（优先 L2 缓存，避免并发文件 I/O）
      Uint8List bytes;
      if (l2Cache != null && l2Cache.hasL2(imageKey)) {
        bytes = l2Cache.getL2(imageKey)!;
      } else if (imageKey.startsWith('file://')) {
        final f = File(imageKey.substring(7));
        if (!await f.exists()) { _poolCreating.remove(key); return; }
        bytes = await f.readAsBytes();
      } else {
        final c = Completer<Uint8List>();
        late StreamSubscription sub;
        sub = ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid).listen(
          (e) { if (e.imageBytes != null) { c.complete(e.imageBytes!); sub.cancel(); } },
          onError: (_) { if (!c.isCompleted) c.completeError('download failed'); },
          cancelOnError: true,
        );
        try { bytes = await c.future; } catch (_) { _poolCreating.remove(key); return; }
      }
      if (!webp.isWebP(bytes)) { _poolCreating.remove(key); return; }
      final info = webp.getInfo(bytes);
      if (info == null || !info.isAnimated) { _poolCreating.remove(key); return; }

      // 2. 创建解码器
      final decoder = webp.createAnimDecoder(bytes, targetWidth: targetWidth, targetHeight: targetHeight);
      if (decoder == null) { _poolCreating.remove(key); return; }

      // 3. 异步预解码 + 上传前 frameCount 帧到 GPU
      final gpuFrames = <ImageInfo>[];
      final durations = <int>[];
      for (int i = 0; i < frameCount; i++) {
        final addr = await decoder.getNextFrameAsync(pool: true);
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

      // 4. 存入池
      final entry = _PrecacheEntry(decoder: decoder, gpuFrames: gpuFrames, durations: durations);
      _precachePool[key] = entry;
      _poolOrder.add(key);
      while (_poolOrder.length > _maxPoolSize) {
        final oldKey = _poolOrder.removeAt(0);
        final old = _precachePool.remove(oldKey);
        if (old != null) {
          for (final f in old.gpuFrames) { f.image.dispose(); }
          old.decoder.dispose();
        }
      }
      debugPrint('[WebP-POOL] precached ${gpuFrames.length} frames for $key (pool=${_precachePool.length})');
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
      _activeKeys.add(key); // 标记活跃，防止重复入池
      debugPrint('[WebP-POOL] hit ${e.gpuFrames.length} frames for $key (pool=${_precachePool.length})');
    }
    return e;
  }

  /// 活跃解码器已释放，允许该 key 重新入池。
  static void releaseActiveKey(String imageKey, int targetWidth, int targetHeight) {
    _activeKeys.remove('$imageKey@${targetWidth}x$targetHeight');
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
    final t0 = DateTime.now().millisecondsSinceEpoch;

    // ── 1. 获取原始字节 ──
    Uint8List rawBytes;

    // 检查 L2 缓存
    if (cache != null && cache!.hasL2(imageKey)) {
      rawBytes = cache!.getL2(imageKey)!;
    } else {
      rawBytes = await _fetchBytes();

      // 存入 L2
      if (cache != null && webp.isWebP(rawBytes)) {
        cache!.putL2(imageKey, rawBytes);
      }
    }
    final t1 = DateTime.now().millisecondsSinceEpoch;

    // ── 2. 检查 L1 缓存 ──
    if (cache != null) {
      final cached = cache!.getL1(imageKey);
      if (cached != null) {
        return _ImageResult.static(ImageInfo(image: cached));
      }
    }

    // ── 3. 格式校验 ──
    if (!webp.isWebP(rawBytes)) {
      // 不是 WebP，走 Flutter 内置解码
      return _ImageResult.fallback(rawBytes);
    }

    // ── 4. 检测类型并解码 ──
    final info = webp.getInfo(rawBytes);
    if (info == null) {
      return _ImageResult.error('Failed to parse WebP header');
    }

    if (info.isAnimated) {
      final result = await _decodeAnimated(rawBytes);
      final t2 = DateTime.now().millisecondsSinceEpoch;
      debugPrint('[WebP-E2E] _loadImageAsync: fetch=${t1-t0}ms decode=${t2-t1}ms total=${t2-t0}ms');
      return result;
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
    // 优先从预缓存池获取（已解码 + 已上传 GPU）
    final precached = WebPImageProvider.takePrecached(imageKey, targetWidth, targetHeight);
    if (precached != null) {
      debugPrint('[WebP] precache hit: ${precached.gpuFrames.length} frames ready on GPU');
      preUploadedFrames = precached.gpuFrames;
      preUploadedDurations = precached.durations;
      return _ImageResult.animated(precached.decoder);
    }
    // 池未命中：现场创建
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

class _WebPImageStreamCompleter extends ImageStreamCompleter {
  final WebPImageProvider _provider;
  bool _disposed = false;
  int _loadStartMs = 0; // loadImage 调用时刻，用于首帧端到端计时

  /// 活跃动画追踪（仅用于内存上限，超限时 dispose 最旧）
  static final List<_WebPImageStreamCompleter> _active = [];
  static const int _maxActive = 3; // PageView 可见范围 ~3 页，只保留这些动画
  void Function()? _disposeDecoder;

  _WebPImageStreamCompleter(Future<_ImageResult> future, this._provider) {
    future.then(_onResult, onError: _onError);
  }

  void _onResult(_ImageResult result) {
    if (_disposed) {
      if (result.type == _ResultType.animated) result.decoder?.dispose();
      return;
    }
    switch (result.type) {
      case _ResultType.static:
        setImage(result.imageInfo!);
        break;
      case _ResultType.animated:
        _startAnimation(result.decoder!,
            preUploaded: _provider.preUploadedFrames,
            preDurations: _provider.preUploadedDurations);
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
      {List<ImageInfo>? preUploaded, List<int>? preDurations}) {
    debugPrint('[WebP-ANIM] _startAnimation called (pre=${preUploaded?.length ?? 0})');
    // 注册活跃动画，超限时停止最旧的（stopAnimation 检查 fetching 后安全释放）
    _active.add(this);
    while (_active.length > _maxActive) {
      final old = _active.removeAt(0);
      old._disposed = true;
      // 从 ImageCache 驱逐，确保下次访问时创建新 Completer
      PaintingBinding.instance.imageCache.evict(old._provider);
      old._disposeDecoder?.call(); // stopAnimation, 安全：检查 fetching
    }
    var isActive = true;
    webp.WebPAnimFrameAddress? pendingFrame;
    bool fetching = false;
    int consecutiveNullFrames = 0;
    int frameIndex = 0;
    bool pendingDispose = false;

    void doDispose() {
      if (!isActive) return;
      isActive = false;
      _active.remove(this);
      _disposeDecoder = null;
      WebPImageProvider.releaseActiveKey(_provider.imageKey, _provider.targetWidth, _provider.targetHeight);
      decoder.dispose();
    }

    void stopAnimation() {
      if (!isActive) return;
      if (fetching) { pendingDispose = true; return; }
      doDispose();
    }

    _disposeDecoder = stopAnimation; // 走 stopAnimation 检查 fetching

    Future<void> fetchNext() async {
      if (fetching || pendingFrame != null || !isActive || _disposed) {
        if (frameIndex == 0 && (fetching || pendingFrame != null)) {
          debugPrint('[WebP-DIAG] fetchNext blocked: fetching=$fetching pending=${pendingFrame != null} active=$isActive');
        }
        return;
      }
      fetching = true;
      try {
        if (!decoder.hasMoreFrames) decoder.reset();
        final int t0 = DateTime.now().millisecondsSinceEpoch;
        final result = await decoder.getNextFrameAsync();
        final int dt = DateTime.now().millisecondsSinceEpoch - t0;
        if (result != null) {
          pendingFrame = result;
          consecutiveNullFrames = 0;
          if (frameIndex < 5) debugPrint('[WebP-TIMING] Isolate decode=${dt}ms frame#$frameIndex');
        } else {
          consecutiveNullFrames++;
          debugPrint('[WebP-DIAG] fetchNext returned null (#$consecutiveNullFrames)');
          if (consecutiveNullFrames > 3) stopAnimation();
        }
      } catch (e) {
        consecutiveNullFrames++;
        debugPrint('[WebP-DIAG] fetchNext exception: $e');
      } finally {
        fetching = false;
        if (pendingDispose) { pendingDispose = false; doDispose(); }
      }
    }

    Future<void> playNext() async {
      if (!isActive || _disposed) { stopAnimation(); return; }

      int waitLoops = 0;
      final tWaitStart = DateTime.now().millisecondsSinceEpoch;
      while (pendingFrame == null && isActive && !_disposed) {
        if (!fetching) await fetchNext();
        if (pendingFrame == null) {
          waitLoops++;
          await Future.delayed(const Duration(milliseconds: 2));
        }
      }
      final waitTotal = DateTime.now().millisecondsSinceEpoch - tWaitStart;
      if (waitTotal > 20) debugPrint('[WebP-WAIT] playNext waited ${waitTotal}ms (${waitLoops} loops) frame#$frameIndex');
      if (!isActive || _disposed) { stopAnimation(); return; }

      final frame = pendingFrame!;
      pendingFrame = null;
      final int duration = frame.durationMs <= 10 ? 33 : frame.durationMs;
      final int length = decoder.targetWidth * decoder.targetHeight * 4;
      final rgba = Pointer<Uint8>.fromAddress(frame.address).asTypedList(length);
      final int t0 = DateTime.now().millisecondsSinceEpoch;

      fetchNext(); // pipeline: start next decode in parallel with GPU upload

      ui.decodeImageFromPixels(rgba, decoder.targetWidth, decoder.targetHeight,
        ui.PixelFormat.rgba8888, (image) {
          if (!isActive || _disposed) { image.dispose(); stopAnimation(); return; }
          setImage(ImageInfo(image: image, scale: _provider.scale));
          final int elapsed = DateTime.now().millisecondsSinceEpoch - t0;
          final int delay = (duration - elapsed).clamp(8, duration);
          if (frameIndex == 0) {
            final e2e = DateTime.now().millisecondsSinceEpoch - _loadStartMs;
            debugPrint('[WebP-E2E] load-to-first-frame=${e2e}ms (fetch=${_loadStartMs > 0 ? t0 - _loadStartMs : -1}ms upload=${elapsed}ms)');
          }
          if (frameIndex < 5) debugPrint('[WebP-TIMING] upload=${elapsed}ms delay=${delay}ms frame#$frameIndex');
          frameIndex++;
          Future.delayed(Duration(milliseconds: delay), playNext);
        });
    }

    if (preUploaded != null && preUploaded.isNotEmpty && preDurations != null) {
      // 预上传帧已在 GPU，直接展示无延迟
      final frames = preUploaded;
      final durs = preDurations;
      var i = 0;
      void playPreUploaded() {
        if (!isActive || _disposed || i >= frames.length) {
          if (isActive && !_disposed) fetchNext().then((_) => playNext());
          return;
        }
        if (i == 0) {
          final e2e = DateTime.now().millisecondsSinceEpoch - _loadStartMs;
          debugPrint('[WebP-E2E] load-to-first-frame(preupload)=${e2e}ms');
        }
        setImage(frames[i]);
        frameIndex = i + 1;
        i++;
        if (i < frames.length) {
          final d = durs.length > i - 1 ? durs[i - 1] : 33;
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
      fetchNext().then((_) => playNext());
    }
  }

  @override
  void onDisposed() {
    _disposed = true;
    _active.remove(this);
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
