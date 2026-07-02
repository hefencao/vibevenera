import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

// ═══════════════════════════════════════════════════════════════
// 高能效渲染引擎：核心组件
// ═══════════════════════════════════════════════════════════════

/// 全局 WebP 动画播放速度。
double webpPlaybackSpeed = 1.0;
const List<double> webpSpeedPresets = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 从 "path/00000008.webp@1080x2340" 提取 "08.webp"
String _short(String key) {
  final name = key.split('@').first.split('/').last.split('\\').last;
  final m = RegExp(r'^(\d+)').firstMatch(name);
  if (m != null) {
    final digits = m.group(1)!;
    return '${digits.substring(digits.length - 2)}.webp';
  }
  return name;
}

/// 微秒级计时器
int _nowUs() => DateTime.now().microsecondsSinceEpoch;

/// 页面状态枚举（驱动解码策略与优先级）
enum PageState {
  current,  // 当前激活页：持续补充模式 (HIGH=7, LOW=3)，多线程
  next,     // 预读页：单次填充至 5 帧，单线程
  last,     // 上一页：停止 Refill，保留现有帧
  precache  // 远端预读：单次填充至 5 帧，低优先级
}

/// 包装解码后的 GPU 帧及其时长
class BufferedFrame {
  final ui.Image image;
  final int durationMs;
  BufferedFrame(this.image, this.durationMs);
}

/// 解码器状态持有者：管理单张动画图片的生命周期、缓冲区与 Refill 逻辑
class DecoderHolder {
  final String key;
  final webp.WebPAnimDecoder decoder;
  final int targetW;
  final int targetH;
  final double scale;
  String get shortKey => _short(key);

  PageState _state = PageState.precache;
  final Queue<BufferedFrame> _frameBuffer = Queue();

  int lastAccessTime = DateTime.now().millisecondsSinceEpoch;
  bool _isFetching = false;
  bool _disposed = false;
  bool _pendingDispose = false;

  DecoderHolder({
    required this.key,
    required this.decoder,
    required this.targetW,
    required this.targetH,
    required this.scale,
  });

  PageState get state => _state;

  bool get disposed => _disposed;

  void updateState(PageState newState) {
    if (_disposed || _state == newState) return;
    final oldState = _state;
    _state = newState;
    lastAccessTime = DateTime.now().millisecondsSinceEpoch;

    if (newState == PageState.current) {
      decoder.setThreadLimit(2);
    } else {
      decoder.setThreadLimit(1);
    }
    debugPrint('[WebP] $shortKey $oldState to $newState');
    _triggerRefillIfNeeded();
  }

  /// 消费一帧（由 Completer 驱动渲染循环调用）
  BufferedFrame? consumeFrame() {
    if (_disposed) return null;
    lastAccessTime = DateTime.now().millisecondsSinceEpoch;

    if (_frameBuffer.isEmpty) {
      _triggerRefillIfNeeded();
      return null;
    }

    final frame = _frameBuffer.removeFirst();
    _triggerRefillIfNeeded();
    return frame;
  }

  /// 水位线驱动的批量补充逻辑。
  /// 采用"水漫式"渐进策略：CURRENT 热身程度决定 NEXT/PRECACHE 的预取额度。
  ///   Phase 0 (CURRENT buf=0)  : C=2, N=1, P=0
  ///   Phase 1 (CURRENT buf<=3) : C=4, N=2, P=1
  ///   Phase 2 (CURRENT buf<=6) : C=7, N=3, P=1
  ///   Phase 3 (steady)         : C=7, N=5, P=2
  void _triggerRefillIfNeeded() {
    if (_isFetching || _disposed || _pendingDispose) return;

    int target = 0;
    webp.DecodePriority priority = webp.DecodePriority.background;
    final buf = _frameBuffer.length;

    if (_state == PageState.current) {
      // CURRENT: 冷启动 2 帧快速上屏，之后始终追求 HIGH=7
      target = (buf == 0) ? 2 : 7;
      priority = webp.DecodePriority.current;
    } else if (_state == PageState.next) {
      final p = DecoderManager.instance.currentPhase;
      target = const [1, 2, 3, 5][p];     // 随 CURRENT 热身逐步释放
      priority = webp.DecodePriority.next;
    } else if (_state == PageState.precache) {
      final p = DecoderManager.instance.currentPhase;
      target = const [0, 1, 1, 2][p];     // 远端最小投入
      priority = webp.DecodePriority.background;
    } else {
      return; // LAST: 不补充
    }

    if (buf >= target) return;
    int refillCount = target - buf;

    if (refillCount > 0) {
      _isFetching = true;
      final currentGen = DecoderManager.instance.generation;
      final t0 = _nowUs();

      webp.WorkerPoolScheduler.instance.dispatch(
        webp.DecodeJob(
          generation: currentGen,
          decoderAddress: decoder.address,
          framesToDecode: refillCount,
          targetW: targetW,
          targetH: targetH,
          onComplete: (newFrameAddresses) async {
            final t1 = _nowUs();
            final n = newFrameAddresses.length;
            // 快速路径：空结果或 gen 不匹配
            if (n == 0) {
              _isFetching = false;
              if (_disposed || _pendingDispose) {
                if (_pendingDispose) { _pendingDispose = false; dispose(); }
                return;
              }
              if (_state == PageState.current || _frameBuffer.length <= 3) {
                _triggerRefillIfNeeded();
              }
              return;
            }

            if (_disposed || _pendingDispose) {
              _isFetching = false;
              _releaseRemainingBuffers(newFrameAddresses, 0);
              if (_pendingDispose) { _pendingDispose = false; dispose(); }
              return;
            }

            if (currentGen != DecoderManager.instance.generation && _state != PageState.current) {
              _isFetching = false;
              _releaseRemainingBuffers(newFrameAddresses, 0);
              return;
            }

            // GPU 上传
            final tUpload = _nowUs();
            final List<BufferedFrame> uploadedFrames = [];
            try {
              for (int i = 0; i < n; i++) {
                if (_disposed || _pendingDispose) {
                  _releaseRemainingBuffers(newFrameAddresses, i);
                  break;
                }
                final addr = newFrameAddresses[i];
                final len = targetW * targetH * 4;
                final rgba = Pointer<Uint8>.fromAddress(addr.address).asTypedList(len);
                final completer = Completer<ui.Image>();
                ui.decodeImageFromPixels(
                  rgba, targetW, targetH, ui.PixelFormat.rgba8888,
                  (img) {
                    webp.nativePoolRelease(addr.address);
                    completer.complete(img);
                  }
                );
                final img = await completer.future;
                uploadedFrames.add(BufferedFrame(img, addr.durationMs));
              }
            } catch (e, stack) {
              debugPrint('[WebP] $shortKey upload error: $e\n$stack');
            }
            final t2 = _nowUs();

            _isFetching = false;

            if (_disposed || _pendingDispose) {
              for (var f in uploadedFrames) { f.image.dispose(); }
              if (_pendingDispose) { _pendingDispose = false; dispose(); }
              return;
            }

            _frameBuffer.addAll(uploadedFrames);
            debugPrint('[WebP] $shortKey +$n frames '
                'decode=${(t1 - t0) ~/ 1000}ms '
                'gpu=${(t2 - tUpload) ~/ 1000}ms '
                'total=${(t2 - t0) ~/ 1000}ms '
                'buf=${_frameBuffer.length} gen=$currentGen');

            if (_state == PageState.current && _frameBuffer.length <= 3) {
              _triggerRefillIfNeeded();
            }
          },
        ),
        priority,
      );
    }
  }

  /// 释放尚未上传的原生缓冲池帧（零拷贝管线清理）
  void _releaseRemainingBuffers(List<webp.WebPAnimFrameAddress> addrs, int startIndex) {
    for (int i = startIndex; i < addrs.length; i++) {
      webp.nativePoolRelease(addrs[i].address);
    }
  }

  void dispose() {
    if (_disposed) return;
    if (_isFetching) {
      _pendingDispose = true;
      return;
    }
    _disposed = true;
    for (final f in _frameBuffer) { f.image.dispose(); }
    _frameBuffer.clear();
    decoder.dispose();
  }
}

/// 全局调度中枢：管理所有 DecoderHolder 的状态迁移与生命周期
class DecoderManager {
  static final DecoderManager instance = DecoderManager._();
  DecoderManager._() {
    Timer.periodic(const Duration(seconds: 1), _onEvictionHeartbeat);
  }

  final Map<String, DecoderHolder> _holders = {};
  int _generation = 0;

  String _currentKey = '';
  final Set<String> _nextKeys = {};
  final Set<String> _lastKeys = {};
  final Set<String> _precacheKeys = {};

  int get generation => _generation;

  /// CURRENT 页面的"热身"阶段：0=冷启动, 1=预热, 2=填充, 3=稳态
  int get currentPhase {
    final cur = _holders[_currentKey];
    if (cur == null) return 0;
    final b = cur._frameBuffer.length;
    if (b == 0) return 0;
    if (b <= 3) return 1;
    if (b <= 6) return 2;
    return 3;
  }

  /// 页面滚动事件驱动的状态机迁移
  void activePagesChanged({
    required String currentKey,
    required List<String> nextKeys,
    required List<String> lastKeys,
    required List<String> precacheKeys,
  }) {
    _generation++;
    webp.WorkerPoolScheduler.instance.updateGeneration(_generation);

    _currentKey = currentKey;
    _nextKeys..clear()..addAll(nextKeys);
    _lastKeys..clear()..addAll(lastKeys);
    _precacheKeys..clear()..addAll(precacheKeys);

    _holders[currentKey]?.updateState(PageState.current);
    for (final k in nextKeys) {
      _holders[k]?.updateState(PageState.next);
    }
    for (final k in lastKeys) {
      _holders[k]?.updateState(PageState.last);
    }
    for (final k in precacheKeys) {
      _holders[k]?.updateState(PageState.precache);
    }
  }

  /// 获取或注册一个新的持有者
  DecoderHolder getOrCreateHolder(String key, webp.WebPAnimDecoder decoder, int tw, int th, double scale) {
    return _holders.putIfAbsent(key, () {
      final holder = DecoderHolder(key: key, decoder: decoder, targetW: tw, targetH: th, scale: scale);
      if (key == _currentKey) {
        holder.updateState(PageState.current);
      } else if (_nextKeys.contains(key)) {
        holder.updateState(PageState.next);
      } else if (_lastKeys.contains(key)) {
        holder.updateState(PageState.last);
      } else if (_precacheKeys.contains(key)) {
        holder.updateState(PageState.precache);
      }
      return holder;
    });
  }

  DecoderHolder? getHolder(String key) => _holders[key];

  void _onEvictionHeartbeat(Timer timer) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final List<String> toRemove = [];

    _holders.forEach((key, holder) {
      if (holder.state == PageState.last || holder.state == PageState.precache) {
        if (now - holder.lastAccessTime > 2000) {
          toRemove.add(key);
        }
      }
    });

    for (final k in toRemove) {
      final h = _holders.remove(k);
      if (h != null) {
        debugPrint('[WebP] ${_short(k)} evicted (TTL)');
        h.dispose();
      }
    }
  }

  void clearAll() {
    _generation++;
    webp.WorkerPoolScheduler.instance.updateGeneration(_generation);
    for (final h in _holders.values) { h.dispose(); }
    _holders.clear();
  }
}

// ═══════════════════════════════════════════════════════════════
// WebPImageProvider 实现
// ═══════════════════════════════════════════════════════════════

class WebPImageProvider extends ImageProvider<WebPImageProvider> {
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
  final double scale;

  String get _fullKey => '$imageKey@${targetWidth}x$targetHeight';

  @override
  Future<WebPImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<WebPImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(WebPImageProvider key, ImageDecoderCallback decode) {
    return _WebPImageStreamCompleter(_loadImageAsync(), key);
  }

  Future<_ImageResult> _loadImageAsync() async {
    final t0 = _nowUs();
    final short = _short(_fullKey);
    final existing = DecoderManager.instance.getHolder(_fullKey);
    if (existing != null) {
      debugPrint('[WebP] $short load: hit holder (${(_nowUs() - t0) ~/ 1000}ms)');
      return _ImageResult.animated(existing);
    }

    if (cache != null) {
      final cached = cache!.getL1(imageKey);
      if (cached != null) {
        debugPrint('[WebP] $short load: hit L1 (${(_nowUs() - t0) ~/ 1000}ms)');
        return _ImageResult.static(ImageInfo(image: cached, scale: scale));
      }
    }

    Uint8List bytes;
    final tFetch = _nowUs();
    try {
      if (cache != null && cache!.hasL2(imageKey)) {
        bytes = cache!.getL2(imageKey)!;
        debugPrint('[WebP] $short load: L2 ${bytes.length ~/ 1024}KB (${(_nowUs() - tFetch) ~/ 1000}ms)');
      } else {
        bytes = await _fetchBytes();
        debugPrint('[WebP] $short load: fetch ${bytes.length ~/ 1024}KB (${(_nowUs() - tFetch) ~/ 1000}ms)');
        if (cache != null && webp.isWebP(bytes)) cache!.putL2(imageKey, bytes);
      }
    } catch (e) {
      debugPrint('[WebP] $short load: ERROR $e');
      return _ImageResult.error(e);
    }

    if (!webp.isWebP(bytes)) {
      return _ImageResult.fallback(bytes);
    }
    final info = webp.getInfo(bytes);
    if (info == null) {
      return _ImageResult.error('Invalid WebP header');
    }

    if (info.isAnimated) {
      final tDec = _nowUs();
      final decoder = webp.createAnimDecoder(bytes, targetWidth: targetWidth, targetHeight: targetHeight);
      if (decoder == null) return _ImageResult.error('Failed to create anim decoder');
      final holder = DecoderManager.instance.getOrCreateHolder(_fullKey, decoder, decoder.targetWidth, decoder.targetHeight, scale);
      debugPrint('[WebP] $short load: decoder ${decoder.frameCount}f ${decoder.targetWidth}x${decoder.targetHeight} (${(_nowUs() - tDec) ~/ 1000}ms) total=${(_nowUs() - t0) ~/ 1000}ms');
      return _ImageResult.animated(holder);
    } else {
      final frame = webp.decodeStatic(bytes, targetWidth: targetWidth, targetHeight: targetHeight);
      if (frame == null) return _ImageResult.error('Failed to decode static WebP');
      final completer = Completer<_ImageResult>();
      ui.decodeImageFromPixels(frame.rgba, frame.width, frame.height, ui.PixelFormat.rgba8888, (img) {
        if (cache != null) cache!.putL1(imageKey, img);
        completer.complete(_ImageResult.static(ImageInfo(image: img, scale: scale)));
      });
      return completer.future;
    }
  }

  Future<Uint8List> _fetchBytes() async {
    if (imageKey.startsWith('file://')) {
      final file = File(imageKey.substring(7));
      if (await file.exists()) return await file.readAsBytes();
    }
    final directFile = File(imageKey);
    if (await directFile.exists()) {
      return await directFile.readAsBytes();
    }

    Uint8List? result;
    await for (final event in ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid)) {
      if (event.imageBytes != null) {
        result = event.imageBytes!;
        break;
      }
    }
    if (result == null) throw Exception('Load failed: $imageKey');
    return result;
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
  int get hashCode => Object.hash(imageKey, sourceKey, cid, eid, targetWidth, targetHeight);

  static void onPageChanged({
    required String current,
    required List<String> next,
    required List<String> last,
    required List<String> precache,
  }) {
    DecoderManager.instance.activePagesChanged(
      currentKey: current,
      nextKeys: next,
      lastKeys: last,
      precacheKeys: precache,
    );
  }

  static void clearAll() => DecoderManager.instance.clearAll();
}

// ═══════════════════════════════════════════════════════════════
// Stream Completer
// ═══════════════════════════════════════════════════════════════

class _WebPImageStreamCompleter extends ImageStreamCompleter {
  final WebPImageProvider _provider;
  bool _disposed = false;

  _WebPImageStreamCompleter(Future<_ImageResult> future, this._provider) {
    future.then(_onResult, onError: _onError);
  }

  void _onResult(_ImageResult result) {
    if (_disposed) return;
    switch (result.type) {
      case _ResultType.static:
        setImage(result.imageInfo!);
        break;
      case _ResultType.animated:
        _startAnimation(result.holder!);
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
    if (_disposed) return;
    reportError(exception: error, stack: stack);
  }

  void _fallbackDecode(Uint8List bytes) {
    ui.instantiateImageCodec(bytes).then((codec) {
      codec.getNextFrame().then((frame) {
        if (!_disposed) setImage(ImageInfo(image: frame.image, scale: _provider.scale));
      });
    });
  }

  void _startAnimation(DecoderHolder holder) {
    bool isActive = true;
    final short = holder.shortKey;

    void reloadAndRestart() {
      if (!isActive || _disposed) return;
      debugPrint('[WebP] $short reloading (holder evicted)...');
      _provider._loadImageAsync().then((result) {
        if (!isActive || _disposed) return;
        if (result.type == _ResultType.animated) {
          _startAnimation(result.holder!);
        } else if (result.type == _ResultType.static) {
          setImage(result.imageInfo!);
        }
      });
    }

    void playLoop() async {
      if (!isActive || _disposed) return;

      // 不可见时只轮询等待，不重载（避免逐出-重载死循环）
      if (!hasListeners) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (isActive && !_disposed) playLoop();
        return;
      }

      // 可见时，holder 被逐出 → 自动重载
      if (holder.disposed) {
        reloadAndRestart();
        return;
      }

      final frame = holder.consumeFrame();
      if (frame == null) {
        if (holder.disposed) {
          reloadAndRestart();
          return;
        }
        await Future.delayed(const Duration(milliseconds: 16));
        if (isActive && !_disposed) playLoop();
        return;
      }

      setImage(ImageInfo(image: frame.image, scale: holder.scale));

      final delay = (frame.durationMs <= 10 ? 100 : frame.durationMs).clamp(8, 1000);
      Future.delayed(Duration(milliseconds: (delay / webpPlaybackSpeed).round()), () {
        if (isActive && !_disposed) playLoop();
      });
    }

    playLoop();
  }

  @override
  void onDisposed() {
    _disposed = true;
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
  final DecoderHolder? holder;
  final Uint8List? rawBytes;
  final Object? error;

  _ImageResult._({required this.type, this.imageInfo, this.holder, this.rawBytes, this.error});

  factory _ImageResult.static(ImageInfo info) => _ImageResult._(type: _ResultType.static, imageInfo: info);
  factory _ImageResult.animated(DecoderHolder holder) => _ImageResult._(type: _ResultType.animated, holder: holder);
  factory _ImageResult.fallback(Uint8List bytes) => _ImageResult._(type: _ResultType.fallback, rawBytes: bytes);
  factory _ImageResult.error(Object e) => _ImageResult._(type: _ResultType.error, error: e);
}
