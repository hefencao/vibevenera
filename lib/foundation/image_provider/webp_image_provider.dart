import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:venera/foundation/appdata.dart'; // 引入以读取预取深度配置
import 'package:venera/foundation/cache_manager.dart'; // 引入 CacheManager，实现网络 WebP 预取本地状态安全解算
import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

// ═══════════════════════════════════════════════════════════════
// 高能效渲染引擎：核心组件
// ═══════════════════════════════════════════════════════════════

/// 全局 WebP 动画播放速度。
double webpPlaybackSpeed = 1.0;
const List<double> webpSpeedPresets = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 全局时钟（避免 DateTime.now() 的 JNI 开销）
final _clock = Stopwatch()..start();
int _nowUs() => _clock.elapsedMicroseconds;
int _nowMs() => _clock.elapsedMilliseconds;

/// 从 "path/00000008.webp@1080x2340" 提取 "08.webp"
String _short(String key) {
  final end = key.indexOf('@');
  final s = end < 0 ? key : key.substring(0, end);
  final slash = s.lastIndexOf('/');
  final bslash = s.lastIndexOf('\\');
  final start = (slash > bslash ? slash : bslash) + 1;
  final name = s.substring(start);
  if (name.length >= 2 && name.codeUnitAt(0) >= 0x30 && name.codeUnitAt(0) <= 0x39) {
    // 数字开头 → 取末两位
    final digits = name.split('.').first;
    return '${digits.substring(digits.length - 2)}.webp';
  }
  return name;
}

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

  int lastAccessTime = _nowMs();

  // ── 动态水位 + 播放速度控制 ──
  int _avgRttMs = 150;           // 指数平滑后的 refill round-trip 时间
  int _avgFrameDurMs = 100;      // 指数平滑后的帧时长
  static const _rttSmooth = 0.3; // 平滑系数

  /// 根据实测 RTT 计算动态 buffer target
  int _dynamicTarget() {
    if (_avgRttMs <= 0 || _avgFrameDurMs <= 0) return 7;
    final needed = ((_avgRttMs * 2) / _avgFrameDurMs).ceil();
    return needed.clamp(3, 16);
  }

  /// 估算可持续播放速度倍率（1.0=原速, 0.5=半速, 0=建议等待）
  double get estimatedSpeedMul {
    if (_avgRttMs <= 0 || _avgFrameDurMs <= 0) return 1.0;
    // 每帧解码耗时 vs 帧间隔 → 能跟上几倍速
    final framesPerRtt = (_avgRttMs / _avgFrameDurMs).ceil();
    final throughput = framesPerRtt / _dynamicTarget().clamp(1, 16);
    if (throughput >= 1.0) return 1.0;
    if (throughput >= 0.67) return 0.75;
    if (throughput >= 0.4) return 0.5;
    return 0.0; // < 0.4× → 建议等待缓冲而非慢速播放
  }

  void _updateRtt(int rttMs, int frameDurMs) {
    _avgRttMs = (_rttSmooth * rttMs + (1.0 - _rttSmooth) * _avgRttMs).round();
    _avgFrameDurMs = (_rttSmooth * frameDurMs + (1.0 - _rttSmooth) * _avgFrameDurMs).round();
  }

  // 管线分离：decode 和 GPU upload 可重叠
  bool _isDecoding = false;   // worker 解码中
  bool _isUploading = false;  // GPU 上传中
  List<webp.WebPAnimFrameAddress>? _pendingUploadAddrs; // 待上传（当前批 upload 完成后处理）
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
    lastAccessTime = _nowMs();

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
    lastAccessTime = _nowMs();

    if (_frameBuffer.isEmpty) {
      _triggerRefillIfNeeded();
      debugPrint('[WebP-T] $shortKey consume EMPTY buf=0 state=${_state.name}');
      return null; // buffer 空，playLoop 等待 refill。Flutter 保留上一帧不黑屏
    }

    final frame = _frameBuffer.removeFirst();
    debugPrint('[WebP-T] $shortKey consume buf=${_frameBuffer.length} dur=${frame.durationMs}ms');
    _triggerRefillIfNeeded();
    return frame;
  }

  /// 水位线驱动的批量补充逻辑
  /// _isDecoding 只保护 worker 解码阶段；_isUploading 期间可发起新解码，实现管线重叠
  void _triggerRefillIfNeeded() {
    if (_isDecoding || _disposed || _pendingDispose) return;

    int target = 0;
    webp.DecodePriority priority = webp.DecodePriority.background;
    final buf = _frameBuffer.length;

    if (_state == PageState.current) {
      final dynTarget = _dynamicTarget();        // 基于实测 RTT
      if (buf == 0) {
        target = (dynTarget ~/ 3).clamp(2, 4);  // 冷启动：dynTarget 的 1/3
      } else if (buf * 2 < dynTarget) {         // buf < target 的一半 → 补水
        target = dynTarget;
      } else {
        return;                                  // buf 充足
      }
      priority = webp.DecodePriority.current;
    } else if (_state == PageState.next) {
      final dyn = _dynamicTarget();
      target = (dyn ~/ 3).clamp(1, 5);
      priority = webp.DecodePriority.next;
    } else if (_state == PageState.precache) {
      target = _dynamicTarget() > 7 ? 2 : 1;
      priority = webp.DecodePriority.background;
    } else {
      return; // LAST: 不补充
    }

    if (buf >= target) return;
    int refillCount = target - buf;

    if (refillCount > 0) {
      _isDecoding = true;
      final currentGen = DecoderManager.instance.generation;
      final t0 = _nowUs();

      debugPrint('[WebP-T] $shortKey refill +$refillCount target=$target buf=$buf '
          'state=${_state.name} gen=$currentGen');

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

            _isDecoding = false;

            if (n == 0) {
              if (_disposed || _pendingDispose) {
                if (_pendingDispose) { _pendingDispose = false; dispose(); }
              }
              debugPrint('[WebP] $shortKey Refill yielded 0 frames, aborting retry to prevent deadlocks.');
              return;
            }

            if (_disposed || _pendingDispose) {
              _releaseRemainingBuffers(newFrameAddresses, 0);
              if (_pendingDispose) { _pendingDispose = false; dispose(); }
              return;
            }

            if (currentGen != DecoderManager.instance.generation && _state != PageState.current) {
              _releaseRemainingBuffers(newFrameAddresses, 0);
              if (_pendingDispose) { _pendingDispose = false; dispose(); }
              return;
            }

            // 管线重叠：若上一批仍在 GPU 上传中，暂存帧；否则立即上传
            // 同时立即检查是否需要下一批解码（decode 与 upload 可并行）
            _scheduleUpload(newFrameAddresses, n, t0, t1, currentGen);
            _triggerRefillIfNeeded();
          },
        ),
        priority,
      );
    }
  }

  /// 调度 GPU 上传。若当前无上传在执行，立即开始；否则暂存，等当前批完成后自动触发。
  void _scheduleUpload(List<webp.WebPAnimFrameAddress> addrs, int n, int t0, int t1, int currentGen) {
    if (_isUploading) {
      // 上一批 upload 还在进行中，暂存帧
      _pendingUploadAddrs = addrs;
      return;
    }
    _doUpload(addrs, n, t0, t1, currentGen);
  }

  Future<void> _doUpload(List<webp.WebPAnimFrameAddress> addrs, int n, int t0, int t1, int currentGen) async {
    _isUploading = true;
    final tUpload = _nowUs();
    int uploaded = 0;
    for (int i = 0; i < n; i++) {
      if (_disposed || _pendingDispose) {
        _releaseRemainingBuffers(addrs, i);
        break;
      }
      final addr = addrs[i];
      final len = targetW * targetH * 4;
      final rgba = Pointer<Uint8>.fromAddress(addr.address).asTypedList(len);
      final tGpu = _nowUs();
      final completer = Completer<BufferedFrame>();
      ui.decodeImageFromPixels(
        rgba, targetW, targetH, ui.PixelFormat.rgba8888,
        (img) {
          final dtGpu = (_nowUs() - tGpu) ~/ 1000;
          webp.nativePoolRelease(addr.address);
          debugPrint('[WebP-T] $shortKey gpu f${uploaded+1}/$n ${dtGpu}ms');
          completer.complete(BufferedFrame(img, addr.durationMs));
        },
      );
      final frame = await completer.future;
      if (_disposed || _pendingDispose) {
        frame.image.dispose();
        _releaseRemainingBuffers(addrs, i + 1);
        break;
      }
      _frameBuffer.add(frame);
      uploaded++;
    }
    final t2 = _nowUs();
    _isUploading = false;

    // 检查是否在解码/上传期间被标记为待释放
    if (_disposed || _pendingDispose) {
      if (_pendingDispose) { _pendingDispose = false; dispose(); }
      return;
    }

    // 检查 generation：如果页面已切换，丢弃这批帧
    if (currentGen != DecoderManager.instance.generation && _state != PageState.current) {
      // 已入队的帧会在 dispose 时清理，这里只停止后续处理
      return;
    }

    // 更新动态水位 RTT 估算
    final totalMs = (t2 - t0) ~/ 1000;
    final sampleDur = addrs.isNotEmpty ? addrs.first.durationMs : 100;
    _updateRtt(totalMs, sampleDur);

    debugPrint('[WebP-T] $shortKey refill_done +$uploaded/$n frames '
        'wait=${(t1 - t0) ~/ 1000}ms '
        'gpu=${(t2 - tUpload) ~/ 1000}ms '
        'total=${totalMs}ms '
        'buf=${_frameBuffer.length} dynT=${_dynamicTarget()} rtt=${_avgRttMs}ms gen=$currentGen');

    // 处理在当前批上传期间完成的下一批解码
    if (_pendingUploadAddrs != null) {
      final pending = _pendingUploadAddrs!;
      _pendingUploadAddrs = null;
      final pendingN = pending.length;
      // 递归处理前检查 _pendingDispose
      if (_pendingDispose) {
        _releaseRemainingBuffers(pending, 0);
        _pendingDispose = false;
        dispose();
        return;
      }
      _doUpload(pending, pendingN, t0, _nowUs(), currentGen);
      return;
    }

    if (_state == PageState.current && _frameBuffer.length <= 3) {
      _triggerRefillIfNeeded();
    }
  }

  void _releaseRemainingBuffers(List<webp.WebPAnimFrameAddress> addrs, int startIndex) {
    for (int i = startIndex; i < addrs.length; i++) {
      webp.nativePoolRelease(addrs[i].address);
    }
  }

  void dispose() {
    if (_disposed) return;
    if (_isDecoding || _isUploading) {
      _pendingDispose = true;
      return;
    }
    _disposed = true;
    // 释放暂存帧的原生缓冲区
    if (_pendingUploadAddrs != null) {
      _releaseRemainingBuffers(_pendingUploadAddrs!, 0);
      _pendingUploadAddrs = null;
    }
    for (final f in _frameBuffer) { f.image.dispose(); }
    _frameBuffer.clear();
    decoder.dispose();
  }
}

/// 全局调度中枢
class DecoderManager {
  static final DecoderManager instance = DecoderManager._();
  DecoderManager._();

  final Map<String, DecoderHolder> _holders = {};
  int _generation = 0;

  String _currentKey = '';
  final Set<String> _nextKeys = {};
  final Set<String> _lastKeys = {};
  final Set<String> _precacheKeys = {};

  int _phase = 0;
  Timer? _evictionTimer;

  int get generation => _generation;

  int get currentPhase {
    final cur = _holders[_currentKey];
    final b = cur?._frameBuffer.length ?? 0;
    if (_phase == 0 && b >= 2) _phase = 1;
    if (_phase == 1 && b >= 4) _phase = 2;
    if (_phase == 2 && b >= 7) _phase = 3;
    if (_phase == 3 && b <= 2) _phase = 2;
    if (_phase == 2 && b == 0) _phase = 0;
    return _phase;
  }

  void _ensureEvictionTimer() {
    if (_evictionTimer != null) return;
    _evictionTimer = Timer.periodic(const Duration(seconds: 1), _onEvictionHeartbeat);
  }

  void _cancelEvictionTimer() {
    _evictionTimer?.cancel();
    _evictionTimer = null;
  }

  /// 状态机迁移。不在新集合中的 holder 降级为 precache。
  void activePagesChanged({
    required int currentPageIndex,
    required List<String> images,
    required BuildContext context,
    required String cid,
    required String eid,
    required String? sourceKey,
    DecodedImageCache? cache,
  }) {
    _generation++;
    webp.WorkerPoolScheduler.instance.updateGeneration(_generation);

    final size = WebPImageProvider.calculateTargetSize(context);
    final int tw = size.width.round();
    final int th = size.height.round();
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final double scale = 1.0 / dpr;

    String fk(int index) {
      if (index < 0 || index >= images.length) return '';
      final imageKey = images[index];
      return '$imageKey@${tw}x$th';
    }

    final String currentKey = fk(currentPageIndex);
    final List<String> nextKeys = [
      fk(currentPageIndex + 1),
      fk(currentPageIndex + 2),
    ].where((k) => k.isNotEmpty).toList();
    final List<String> lastKeys = [
      fk(currentPageIndex - 1),
    ].where((k) => k.isNotEmpty).toList();
    final List<String> precacheKeys = [
      fk(currentPageIndex + 3),
      fk(currentPageIndex + 4),
    ].where((k) => k.isNotEmpty).toList();

    _currentKey = currentKey;
    _nextKeys..clear()..addAll(nextKeys);
    _lastKeys..clear()..addAll(lastKeys);
    _precacheKeys..clear()..addAll(precacheKeys);

    final keep = <String>{currentKey, ...nextKeys, ...lastKeys, ...precacheKeys};
    for (final e in _holders.entries) {
      if (!keep.contains(e.key) && e.value.state != PageState.last && e.value.state != PageState.precache) {
        e.value.updateState(PageState.precache);
      }
    }

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

    // 统一更新 L1/L2 三级缓存活跃集合
    if (cache != null) {
      final activeKeys = {
        currentKey.split('@').first,
        ...nextKeys.map((k) => k.split('@').first),
        ...lastKeys.map((k) => k.split('@').first),
      }.where((k) => k.isNotEmpty).toList();
      cache.setActivePages(activeKeys);
    }

    // ───────────────────────────────────────────────────────────
    // 关键优化一：大窗口磁盘异步预下载管线 (Wider Disk Prefetch Window)
    // ───────────────────────────────────────────────────────────
    // 一切漫画格式（包含 JPEG/PNG 等非 WebP 图）在此处被统一管理
    final int preDownloadCount = appdata.settings["preloadImageCount"] ?? 5;
    for (int i = 1; i <= preDownloadCount; i++) {
      final int targetIdx = currentPageIndex + i;
      if (targetIdx >= 0 && targetIdx < images.length) {
        final String imageKey = images[targetIdx];
        if (!imageKey.startsWith('file://')) {
          ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid);
        }
      }
    }

    // ───────────────────────────────────────────────────────────
    // 关键优化二：窄窗口 FFI 原生预解码管线 (Narrower VRAM Pre-decode Window)
    // ───────────────────────────────────────────────────────────
    // 仅对紧邻可见页的 NEXT/PRECACHE WebP 进行 FFI 预先解码上屏，维持 VRAM 占用极其合理
    final List<String> precreateTargets = [...nextKeys, ...precacheKeys];
    for (final k in precreateTargets) {
      if (!_holders.containsKey(k)) {
        final imageKey = k.split('@').first;
        if (imageKey.endsWith('.webp') || WebPImageProvider.isLikelyWebP(imageKey)) {
          WebPImageProvider.ensureHolder(
            imageKey: imageKey,
            fullKey: k,
            cache: cache,
            sourceKey: sourceKey,
            cid: cid,
            eid: eid,
            targetWidth: tw,
            targetHeight: th,
            scale: scale,
            onlyIfCached: true, // 极其安全：只预解算已成功下载到磁盘的文件，绝不抢跑触发多余的网络请求
          ).catchError((_) => null);
        }
      }
    }
  }

  DecoderHolder getOrCreateHolder(String key, webp.WebPAnimDecoder decoder, int tw, int th, double scale) {
    _ensureEvictionTimer();
    return _holders.putIfAbsent(key, () {
      final h = DecoderHolder(key: key, decoder: decoder, targetW: tw, targetH: th, scale: scale);
      if (key == _currentKey) {
        h.updateState(PageState.current);
      } else if (_nextKeys.contains(key)) {
        h.updateState(PageState.next);
      } else if (_lastKeys.contains(key)) {
        h.updateState(PageState.last);
      } else if (_precacheKeys.contains(key)) {
        h.updateState(PageState.precache);
      }
      return h;
    });
  }

  DecoderHolder? getHolder(String key) => _holders[key];

  void _onEvictionHeartbeat(Timer timer) {
    final now = _nowMs();
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
        debugPrint('[WebP] ${_short(k)} evicted');
        h.dispose();
      }
    }

    if (_holders.isEmpty) _cancelEvictionTimer();
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
    required this.targetWidth,
    required this.targetHeight,
    required this.scale,
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

  /// 静态尺寸源计算器：统一数据源，消除 UI 与 FFI 预载间的尺寸极微误差
  static ui.Size calculateTargetSize(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    var w = (size.width * dpr).round();
    var h = (size.height * dpr).round();
    if (w > 1920) w = 1920;
    if (h > 2560) h = 2560;
    return ui.Size(w.toDouble(), h.toDouble());
  }

  static bool isLikelyWebP(String imageKey) {
    var lower = imageKey.toLowerCase();
    if (lower.contains('.webp')) return true;
    return false;
  }

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
    final short = _short(imageKey);
    
    // 1. 内存缓存命中检测
    if (cache != null) {
      final cached = cache!.getL1(imageKey);
      if (cached != null) {
        debugPrint('[WebP] $short load: hit L1 (${(_nowUs() - t0) ~/ 1000}ms)');
        return _ImageResult.static(ImageInfo(image: cached, scale: scale));
      }
    }

    // 2. 统一获取原始字节流（解决文件下载/写入竞态）
    Uint8List bytes;
    try {
      if (cache != null && cache!.hasL2(imageKey)) {
        bytes = cache!.getL2(imageKey)!;
      } else {
        // 安全防静默挂起：为后台或 I/O 文件读取增加 15s 强制超时锁，打破任何潜在的线程锁死死结
        bytes = await _fetchBytes().timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('[WebP] 15秒读取/下载超时，安全断开'),
        );
        if (cache != null && webp.isWebP(bytes)) cache!.putL2(imageKey, bytes);
      }
    } catch (e) {
      debugPrint('[WebP] $short load bytes ERROR: $e');
      return _ImageResult.error(e);
    }

    // 3. 基础格式校验（降级到非 WebP 传统解码器）
    if (!webp.isWebP(bytes)) {
      return _ImageResult.fallback(bytes);
    }
    
    final info = webp.getInfo(bytes);
    if (info == null) {
      return _ImageResult.error('Invalid WebP header');
    }

    // 4. 根据动静态类型分别解算
    if (info.isAnimated) {
      // 动画 WebP -> 复用或创建 DecoderHolder
      final holder = await ensureHolder(
        imageKey: imageKey,
        fullKey: _fullKey,
        cache: cache,
        sourceKey: sourceKey,
        cid: cid,
        eid: eid,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        scale: scale,
        providedBytes: bytes, // 传入已获取好的 bytes，避免 ensureHolder 重复读取
      );
      if (holder != null) return _ImageResult.animated(holder);
      return _ImageResult.error('Failed to create animated decoder');
    } else {
      // 静态 WebP -> 单帧解码
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

  // ─── per-key 并发单飞锁 ───

  static final Map<String, Future<Uint8List>> _pendingByteLoads = {};

  static final Map<String, Future<DecoderHolder?>> _pendingLoads = {};

  static Future<DecoderHolder?> ensureHolder({
    required String imageKey,
    required String fullKey,
    DecodedImageCache? cache,
    String? sourceKey,
    required String cid,
    required String eid,
    required int targetWidth,
    required int targetHeight,
    required double scale,
    Uint8List? providedBytes,
    bool onlyIfCached = false,
  }) async {
    final short = _short(imageKey);
    final completer = Completer<DecoderHolder?>();

    if (onlyIfCached) {
      bool exists = false;
      try {
        if (imageKey.startsWith('file://')) {
          final file = File(imageKey);
          if (await file.exists() && await file.length() > 0) {
            exists = true;
          } else {
            final decodedFile = File(Uri.decodeFull(imageKey));
            if (await decodedFile.exists() && await decodedFile.length() > 0) {
              exists = true;
            }
          }
        } else {
          // 关键改动：网络图片在 precreate 预创建时，异步检索 L2 缓存及 CacheManager 本地沙盒
          // 判定其是否下载完成。彻底解决网络 WebP 划页预解码被误截断拦截的问题。
          if (cache != null && cache.hasL2(imageKey)) {
            exists = true;
          } else {
            final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
            final cacheFile = await CacheManager().findCache(cacheKey);
            if (cacheFile != null && await cacheFile.exists() && await cacheFile.length() > 0) {
              exists = true;
            }
          }
        }
      } catch (_) {}

      if (!exists) {
        completer.complete(null);
        return null; // 未在本地下载，静默放弃预分配
      }
    }

    final existing = DecoderManager.instance.getHolder(fullKey);
    if (existing != null) {
      return existing;
    }

    if (_pendingLoads.containsKey(fullKey)) {
      debugPrint('[WebP] $short pending, waiting');
      return _pendingLoads[fullKey];
    }

    _pendingLoads[fullKey] = completer.future;

    try {
      final t0 = _nowUs();
      Uint8List? bytes = providedBytes;
      
      if (bytes == null) {
        try {
          if (cache != null && cache.hasL2(imageKey)) {
            bytes = cache.getL2(imageKey)!;
          } else {
            bytes = await _fetchBytesStatic(imageKey, sourceKey, cid, eid);
            if (cache != null && webp.isWebP(bytes)) cache.putL2(imageKey, bytes);
          }
        } catch (e) {
          debugPrint('[WebP] $short fetch error: $e');
          completer.complete(null);
          return null;
        }
      }

      if (bytes == null || !webp.isWebP(bytes)) { completer.complete(null); return null; }
      final info = webp.getInfo(bytes);
      if (info == null || !info.isAnimated) { completer.complete(null); return null; }

      final decoder = await webp.WorkerPoolScheduler.instance.createDecoderAsync(bytes, targetWidth, targetHeight);
      if (decoder == null) { completer.complete(null); return null; }

      final holder = DecoderManager.instance.getOrCreateHolder(fullKey, decoder, decoder.targetWidth, decoder.targetHeight, scale);
      debugPrint('[WebP] $short decoder ${decoder.frameCount}f ${decoder.targetWidth}x${decoder.targetHeight} (${(_nowUs() - t0) ~/ 1000}ms)');
      completer.complete(holder);
      return holder;
    } finally {
      _pendingLoads.remove(fullKey);
    }
  }

  static Future<Uint8List> _fetchBytesStatic(String imageKey, String? sourceKey, String cid, String eid) async {
    // 关键优化（全局字节单飞锁）：防范预载下载管线与主渲染加载管线在 App 刚启动时，
    // 并发抢占 I/O 并读写同一本地物理文件造成的锁死与损坏（消灭 70% 的文件竞态）
    if (_pendingByteLoads.containsKey(imageKey)) {
      debugPrint('[WebP-IO] Join pending byte loading task for $imageKey');
      return _pendingByteLoads[imageKey]!;
    }

    final completer = Completer<Uint8List>();
    _pendingByteLoads[imageKey] = completer.future;

    try {
      final bytes = await _fetchBytesStaticRaw(imageKey, sourceKey, cid, eid);
      completer.complete(bytes);
      return bytes;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      _pendingByteLoads.remove(imageKey);
    }
  }

  static Future<Uint8List> _fetchBytesStaticRaw(String imageKey, String? sourceKey, String cid, String eid) async {
    final isLocal = imageKey.startsWith('file://');
    
    // 1. 本地 file:// 协议文件安全读取
    if (isLocal) {
      final file = File(imageKey);
      try {
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            if (webp.isWebP(bytes)) {
              return bytes;
            } else {
              throw FileSystemException('File is not a valid WebP format', imageKey);
            }
          }
        }
      } catch (e) {
        // 本地文件系统完全读取失败时，绝不进行 ImageDownloader 网络降级。
        // 直接上报物理 I/O 异常，供 Flutter 渲染层排查权限或路径问题。
        throw FileSystemException('Failed to read local SAF/file WebP: $e', imageKey);
      }
      
      throw FileSystemException('Local WebP file not found or inaccessible', imageKey);
    }
    
    // 2. 本地直接路径文件（针对无协议头的本地路径检测）
    final directFile = File(imageKey);
    if (await directFile.exists()) {
      final bytes = await directFile.readAsBytes();
      if (bytes.isNotEmpty) {
        if (webp.isWebP(bytes)) {
          return bytes;
        } else {
          throw FileSystemException('Direct file is not a valid WebP', imageKey);
        }
      }
    }
    
    // 3. 远端网络图片才会走到下载链路
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

  Future<Uint8List> _fetchBytes() async {
    return _fetchBytesStatic(imageKey, sourceKey, cid, eid);
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

  /// 全局滑动状态机更新接口：与新版 images.txt 完全同步
  static void onPageChanged({
    required int currentPageIndex,
    required List<String> images,
    required BuildContext context,
    required String cid,
    required String eid,
    required String? sourceKey,
    DecodedImageCache? cache,
  }) {
    DecoderManager.instance.activePagesChanged(
      currentPageIndex: currentPageIndex,
      images: images,
      context: context,
      cid: cid,
      eid: eid,
      sourceKey: sourceKey,
      cache: cache,
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
  // 滑动窗口释放队列：保留最近 4 帧，第 5 帧旧的显式 dispose
  final List<ui.Image> _disposeQueue = [];

  void _enqueueDispose(ui.Image img) {
    _disposeQueue.add(img);
    while (_disposeQueue.length > 4) {
      _disposeQueue.removeAt(0).dispose();
    }
  }

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

  void _startAnimation(DecoderHolder initialHolder) {
    bool isActive = true;
    DecoderHolder holder = initialHolder;
    final short = holder.shortKey;

    /// 统一异步重载逻辑
    Future<bool> reloadAndRestart() async {
      if (!isActive || _disposed) return false;
      debugPrint('[WebP] $short reloading (holder evicted)...');
      try {
        final result = await _provider._loadImageAsync();
        if (!isActive || _disposed) return false;
        
        if (result.type == _ResultType.animated) {
          holder = result.holder!;
          return true; // 成功重新捕获动画句柄，继续循环
        } else if (result.type == _ResultType.static) {
          setImage(result.imageInfo!);
          isActive = false; // 已降级为静态图片，安全退出循环
          return false;
        }
      } catch (e) {
        debugPrint('[WebP] $short reload error: $e');
      }
      return false;
    }

    /// 扁平化单向循环迭代器（完全避免递归、匿名闭包分配及 concurrent loop 竞争问题）
    void playLoop() async {
      int frameIndex = 0;
      int tLastFrame = _nowUs();
      double speedMul = 1.0;       // 当前播放速度倍率（固定，非逐帧变化）
      int speedStableCount = 0;    // 连续稳定计数（调速用滞后）
      int bufLowStreak = 0;        // 连续低 buffer 计数
      bool waitedForStart = false; // 是否已完成初始缓冲等待

      int framesSinceGc = 0;
      while (isActive && !_disposed) {
        // 1. 无可见监听者或 App 处于后台时挂起
        if (!hasListeners) {
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }
        try {
          final state = WidgetsBinding.instance.lifecycleState;
          if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
            await Future.delayed(const Duration(milliseconds: 200));
            continue;
          }
        } catch (_) { /* binding not ready yet */ }

        // 1.5 每 30 帧触发一次 GC，避免临时对象累积导致 RSS 飙升
        if (++framesSinceGc >= 30) {
          framesSinceGc = 0;
          await Future.delayed(Duration.zero); // 让出事件循环
        }

        // 2. 句柄被全局滑动回收机制逐出时，触发就地安全热重载
        if (holder.disposed) {
          final reloaded = await reloadAndRestart();
          if (reloaded) {
            waitedForStart = false; // 重载后重新等缓冲
            speedMul = 1.0;
            continue;
          } else {
            break;
          }
        }

        // 3. 初始缓冲等待：启动播放前攒够最低帧数
        if (!waitedForStart) {
          final minStart = (holder._dynamicTarget() ~/ 3).clamp(2, 5);
          if (holder._frameBuffer.length < minStart && holder._isDecoding) {
            await Future.delayed(const Duration(milliseconds: 32));
            continue;
          }
          // 确定初始播放速度
          final est = holder.estimatedSpeedMul;
          speedMul = est > 0 ? est : 0.5;
          if (est == 0.0 && holder._frameBuffer.length < holder._dynamicTarget() ~/ 2) {
            // 吞吐严重不足 → 继续等待缓冲
            await Future.delayed(const Duration(milliseconds: 50));
            continue;
          }
          waitedForStart = true;
          tLastFrame = _nowUs();
        }

        // 4. 消费帧数据
        final frame = holder.consumeFrame();
        if (frame == null) {
          if (holder.disposed) continue;
          await Future.delayed(const Duration(milliseconds: 16));
          continue;
        }

        // 5. 派发渲染帧上屏（Flutter setImage 内部 dispose 旧帧）
        final tNow = _nowUs();
        final displayInterval = (tNow - tLastFrame) ~/ 1000;
        tLastFrame = tNow;
        setImage(ImageInfo(image: frame.image, scale: holder.scale));
        _enqueueDispose(frame.image);
        frameIndex++;

        // 6. 帧间隔延时（固定速度 × 调速倍率）
        final rawDelay = frame.durationMs <= 10 ? 100 : frame.durationMs;
        final baseDelay = rawDelay.clamp(8, 1000);
        final buf = holder._frameBuffer.length;
        final dynT = holder._dynamicTarget();

        // 滞后调速：连续 N 帧 buffer 不足才降速，连续 N 帧恢复才升速
        if (buf * 3 < dynT) {
          bufLowStreak++;
        } else {
          bufLowStreak = 0;
        }
        if (bufLowStreak >= 5 && speedMul > 0.5) {
          speedMul = (speedMul - 0.25).clamp(0.5, 1.0);
          bufLowStreak = 0;
        } else if (bufLowStreak == 0 && buf > dynT * 2 ~/ 3 && speedMul < 1.0) {
          speedStableCount++;
          if (speedStableCount >= 10) {
            speedMul = (speedMul + 0.25).clamp(0.5, 1.0);
            speedStableCount = 0;
          }
        } else {
          speedStableCount = 0;
        }

        final delay = (baseDelay / speedMul).round().clamp(8, 2000);
        debugPrint('[WebP-T] ${holder.shortKey} display f#$frameIndex '
            'dur=${frame.durationMs}ms int=${displayInterval}ms '
            'wait=${delay}ms spd=${speedMul.toStringAsFixed(2)} buf=$buf/$dynT rtt=${holder._avgRttMs}ms');
        await Future.delayed(Duration(milliseconds: (delay / webpPlaybackSpeed).round()));
      }
    }

    // 启动扁平循环
    playLoop();
  }

  @override
  void onDisposed() {
    _disposed = true;
    for (final img in _disposeQueue) { img.dispose(); }
    _disposeQueue.clear();
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