import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';

/// WebP 图片格式信息
class WebPImageInfo {
  final int width;
  final int height;
  final bool hasAlpha;
  final bool isAnimated;

  const WebPImageInfo({
    required this.width,
    required this.height,
    required this.hasAlpha,
    required this.isAnimated,
  });
}

/// 解码后的静态 WebP 帧
class WebPStaticFrame {
  final Uint8List rgba;
  final int width;
  final int height;

  const WebPStaticFrame({
    required this.rgba,
    required this.width,
    required this.height,
  });
}

/// 解码后的动画 WebP 帧（已在目标分辨率）
class WebPAnimFrame {
  final Uint8List rgba;
  final int durationMs;

  const WebPAnimFrame({
    required this.rgba,
    required this.durationMs,
  });
}

/// 解码后的动画 WebP 帧（原生内存地址版本，减少 Isolate 拷贝）
class WebPAnimFrameAddress {
  final int address;
  final int durationMs;

  const WebPAnimFrameAddress({
    required this.address,
    required this.durationMs,
  });
}

// ═══════════════════════════════════════════════════════════════
// FFI 函数类型定义
// ═══════════════════════════════════════════════════════════════

typedef _WebPGetInfoNative = Int32 Function(
  Pointer<Uint8> data,
  Uint64 size,
  Pointer<Int32> width,
  Pointer<Int32> height,
  Pointer<Int32> hasAlpha,
  Pointer<Int32> isAnimated,
);

typedef _WebPGetInfoDart = int Function(
  Pointer<Uint8> data,
  int size,
  Pointer<Int32> width,
  Pointer<Int32> height,
  Pointer<Int32> hasAlpha,
  Pointer<Int32> isAnimated,
);

typedef _WebPDecodeScaledNative = Pointer<Uint8> Function(
  Pointer<Uint8> data,
  Uint64 size,
  Int32 targetWidth,
  Int32 targetHeight,
  Pointer<Int32> outWidth,
  Pointer<Int32> outHeight,
);

typedef _WebPDecodeScaledDart = Pointer<Uint8> Function(
  Pointer<Uint8> data,
  int size,
  int targetWidth,
  int targetHeight,
  Pointer<Int32> outWidth,
  Pointer<Int32> outHeight,
);

typedef _WebPAnimDecoderNewNative = Pointer<Void> Function(
  Pointer<Uint8> data,
  Uint64 size,
  Int32 targetWidth,
  Int32 targetHeight,
  Pointer<Int32> canvasWidth,
  Pointer<Int32> canvasHeight,
  Pointer<Int32> frameCount,
  Pointer<Int32> loopCount,
  Pointer<Int32> actualWidth,
  Pointer<Int32> actualHeight,
);

typedef _WebPAnimDecoderNewDart = Pointer<Void> Function(
  Pointer<Uint8> data,
  int size,
  int targetWidth,
  int targetHeight,
  Pointer<Int32> canvasWidth,
  Pointer<Int32> canvasHeight,
  Pointer<Int32> frameCount,
  Pointer<Int32> loopCount,
  Pointer<Int32> actualWidth,
  Pointer<Int32> actualHeight,
);

typedef _WebPAnimDecoderGetFrameNative = Pointer<Uint8> Function(
  Pointer<Void> ctx,
  Pointer<Int32> durationMs,
);

typedef _WebPAnimDecoderGetFrameDart = Pointer<Uint8> Function(
  Pointer<Void> ctx,
  Pointer<Int32> durationMs,
);

typedef _WebPAnimDecoderHasMoreNative = Int32 Function(Pointer<Void> ctx);
typedef _WebPAnimDecoderHasMoreDart = int Function(Pointer<Void> ctx);

typedef _WebPAnimDecoderResetNative = Void Function(Pointer<Void> ctx);
typedef _WebPAnimDecoderResetDart = void Function(Pointer<Void> ctx);

typedef _WebPAnimDecoderDeleteNative = Void Function(Pointer<Void> ctx);
typedef _WebPAnimDecoderDeleteDart = void Function(Pointer<Void> ctx);

typedef _WebPAnimDecoderSetThreadLimitNative = Void Function(
  Pointer<Void> ctx,
  Int32 useThreads,
);
typedef _WebPAnimDecoderSetThreadLimitDart = void Function(
  Pointer<Void> ctx,
  int useThreads,
);

typedef _WebPAnimDecoderAliveCountNative = Int32 Function();
typedef _WebPAnimDecoderAliveCountDart = int Function();

typedef _WebPFreeBufferNative = Void Function(Pointer<Uint8> buf);
typedef _WebPFreeBufferDart = void Function(Pointer<Uint8> buf);

// ─── 原生缓冲池 API（Zero-Copy 管线） ───

typedef _WebPNativePoolAcquireNative = Pointer<Uint8> Function(Uint64 size);
typedef _WebPNativePoolAcquireDart = Pointer<Uint8> Function(int size);

typedef _WebPNativePoolReleaseNative = Void Function(Pointer<Uint8> ptr);
typedef _WebPNativePoolReleaseDart = void Function(Pointer<Uint8> ptr);

// ─── 帧提取 API（用于并行解码） ───

typedef _WebPAnimExtractFramesNative = Pointer<Void> Function(
  Pointer<Uint8> data, Uint64 size,
);
typedef _WebPAnimExtractFramesDart = Pointer<Void> Function(
  Pointer<Uint8> data, int size,
);

typedef _WebPFreeFrameListNative = Void Function(Pointer<Void> list);
typedef _WebPFreeFrameListDart = void Function(Pointer<Void> list);

typedef _WebPDecodeFragmentScaledNative = Pointer<Uint8> Function(
  Pointer<Uint8> fragData, Uint64 fragSize,
  Int32 fragW, Int32 fragH,
  Int32 targetW, Int32 targetH,
  Pointer<Int32> outW, Pointer<Int32> outH,
);
typedef _WebPDecodeFragmentScaledDart = Pointer<Uint8> Function(
  Pointer<Uint8> fragData, int fragSize,
  int fragW, int fragH,
  int targetW, int targetH,
  Pointer<Int32> outW, Pointer<Int32> outH,
);

// ═══════════════════════════════════════════════════════════════
// 原生库加载
// ═══════════════════════════════════════════════════════════════

DynamicLibrary _loadLibrary() {
  // Android
  try {
    return DynamicLibrary.open('libvenera_webp.so');
  } catch (_) {}

  // Fallback (for testing on other platforms)
  try {
    return DynamicLibrary.open('libvenera_webp.dll');
  } catch (_) {}

  try {
    return DynamicLibrary.open('libvenera_webp.so');
  } catch (_) {}

  throw UnsupportedError(
    'Cannot load libvenera_webp native library. '
    'Make sure it is compiled for your platform.',
  );
}

// ═══════════════════════════════════════════════════════════════
// 绑定实例
// ═══════════════════════════════════════════════════════════════

class _WebPBindings {
  final DynamicLibrary _lib;

  late final _WebPGetInfoDart getInfo;
  late final _WebPDecodeScaledDart decodeScaled;
  late final _WebPAnimDecoderNewDart animNew;
  late final _WebPAnimDecoderGetFrameDart animGetFrame;
  late final _WebPAnimDecoderHasMoreDart animHasMore;
  late final _WebPAnimDecoderResetDart animReset;
  late final _WebPAnimDecoderDeleteDart animDelete;
  late final _WebPAnimDecoderSetThreadLimitDart animSetThreadLimit;
  late final _WebPAnimDecoderAliveCountDart animAliveCount;
  late final _WebPFreeBufferDart freeBuffer;
  late final _WebPNativePoolAcquireDart poolAcquire;
  late final _WebPNativePoolReleaseDart poolRelease;
  late final _WebPAnimExtractFramesDart animExtractFrames;
  late final _WebPFreeFrameListDart freeFrameList;
  late final _WebPDecodeFragmentScaledDart decodeFragmentScaled;

  _WebPBindings(this._lib) {
    getInfo = _lib
        .lookupFunction<_WebPGetInfoNative, _WebPGetInfoDart>('webp_get_info');
    decodeScaled = _lib.lookupFunction<_WebPDecodeScaledNative,
        _WebPDecodeScaledDart>('webp_decode_scaled');
    animNew = _lib.lookupFunction<_WebPAnimDecoderNewNative,
        _WebPAnimDecoderNewDart>('webp_anim_decoder_new');
    animGetFrame = _lib.lookupFunction<_WebPAnimDecoderGetFrameNative,
        _WebPAnimDecoderGetFrameDart>('webp_anim_decoder_get_frame');
    animHasMore = _lib.lookupFunction<_WebPAnimDecoderHasMoreNative,
        _WebPAnimDecoderHasMoreDart>('webp_anim_decoder_has_more');
    animReset = _lib.lookupFunction<_WebPAnimDecoderResetNative,
        _WebPAnimDecoderResetDart>('webp_anim_decoder_reset');
    animDelete = _lib.lookupFunction<_WebPAnimDecoderDeleteNative,
        _WebPAnimDecoderDeleteDart>('webp_anim_decoder_delete');
    animSetThreadLimit = _lib.lookupFunction<_WebPAnimDecoderSetThreadLimitNative,
        _WebPAnimDecoderSetThreadLimitDart>('webp_anim_decoder_set_thread_limit');
    animAliveCount = _lib.lookupFunction<_WebPAnimDecoderAliveCountNative,
        _WebPAnimDecoderAliveCountDart>('webp_anim_decoder_alive_count');
    freeBuffer = _lib.lookupFunction<_WebPFreeBufferNative, _WebPFreeBufferDart>(
        'webp_free_buffer');
    poolAcquire = _lib.lookupFunction<_WebPNativePoolAcquireNative,
        _WebPNativePoolAcquireDart>('webp_native_pool_acquire');
    poolRelease = _lib.lookupFunction<_WebPNativePoolReleaseNative,
        _WebPNativePoolReleaseDart>('webp_native_pool_release');
    animExtractFrames = _lib.lookupFunction<_WebPAnimExtractFramesNative,
        _WebPAnimExtractFramesDart>('webp_anim_extract_frames');
    freeFrameList = _lib.lookupFunction<_WebPFreeFrameListNative,
        _WebPFreeFrameListDart>('webp_free_frame_list');
    decodeFragmentScaled = _lib.lookupFunction<_WebPDecodeFragmentScaledNative,
        _WebPDecodeFragmentScaledDart>('webp_decode_fragment_scaled');
  }
}

_WebPBindings? _bindings;
_WebPBindings get _bind => _bindings ??= _WebPBindings(_loadLibrary());

// ═══════════════════════════════════════════════════════════════
// WebP 格式检测（纯 Dart，无需 FFI）
// ═══════════════════════════════════════════════════════════════

/// 检测是否为 WebP 格式
bool isWebP(Uint8List data) {
  if (data.length < 12) return false;
  return data[0] == 0x52 && // R
      data[1] == 0x49 && // I
      data[2] == 0x46 && // F
      data[3] == 0x46 && // F
      data[8] == 0x57 && // W
      data[9] == 0x45 && // E
      data[10] == 0x42 && // B
      data[11] == 0x50; // P
}

// ═══════════════════════════════════════════════════════════════
// 公共 API
// ═══════════════════════════════════════════════════════════════

/// 归还 Native Buffer Pool 中的缓冲区（零拷贝管线闭环）。
///
/// 必须在 decodeImageFromPixels 的完成回调中调用，
/// 此时 GPU 已安全读取完像素数据。
void nativePoolRelease(int address) {
  _bind.poolRelease(Pointer<Uint8>.fromAddress(address));
}

/// 获取 WebP 图片基本信息
WebPImageInfo? getInfo(Uint8List data) {
  if (!isWebP(data)) return null;

  final size = data.length;
  final nativeData = data._asNative();

  final w = calloc<Int32>();
  final h = calloc<Int32>();
  final alpha = calloc<Int32>();
  final animated = calloc<Int32>();

  try {
    final result = _bind.getInfo(nativeData, size, w, h, alpha, animated);
    if (result == 0) return null;

    return WebPImageInfo(
      width: w.value,
      height: h.value,
      hasAlpha: alpha.value != 0,
      isAnimated: animated.value != 0,
    );
  } finally {
    calloc.free(w);
    calloc.free(h);
    calloc.free(alpha);
    calloc.free(animated);
    nativeData._free();
  }
}

/// 解码静态 WebP 到指定目标尺寸（保持宽高比）
WebPStaticFrame? decodeStatic(Uint8List data,
    {required int targetWidth, required int targetHeight}) {
  if (!isWebP(data)) return null;
  final sw = Stopwatch()..start();

  final nativeData = data._asNative();

  final outW = calloc<Int32>();
  final outH = calloc<Int32>();

  try {
    final result = _bind.decodeScaled(
      nativeData,
      data.length,
      targetWidth,
      targetHeight,
      outW,
      outH,
    );

    if (result == Pointer.fromAddress(0)) return null;

    final w = outW.value;
    final h = outH.value;
    final length = w * h * 4;

    final rgba = result.asTypedList(length);
    final copySw = Stopwatch()..start();
    final dartRgba = Uint8List.fromList(rgba);

    _bind.freeBuffer(result);

    debugPrint('[WebP] decodeStatic ${w}x$h C=${sw.elapsedMilliseconds}ms copy=${copySw.elapsedMilliseconds}ms');
    return WebPStaticFrame(rgba: dartRgba, width: w, height: h);
  } finally {
    calloc.free(outW);
    calloc.free(outH);
    nativeData._free();
  }
}

/// 创建动画 WebP 解码器。
///
/// 每次调用创建独立解码器实例。调用者通过 [WebPAnimDecoder.dispose] 释放资源。
/// 注意：不再复用解码器以避免多 Completer 间共享 C 状态导致的竞态条件。
///
/// 返回 null 表示失败（nativeData 已释放）。
WebPAnimDecoder? createAnimDecoder(Uint8List data,
    {required int targetWidth, required int targetHeight}) {
  if (!isWebP(data)) return null;

  final nativeData = data._asNative();

  final cW = calloc<Int32>();
  final cH = calloc<Int32>();
  final fC = calloc<Int32>();
  final lC = calloc<Int32>();
  final aW = calloc<Int32>();
  final aH = calloc<Int32>();

  try {
    final ctx = _bind.animNew(
      nativeData,
      data.length,
      targetWidth,
      targetHeight,
      cW,
      cH,
      fC,
      lC,
      aW,
      aH,
    );

    if (ctx == Pointer.fromAddress(0)) {
      nativeData._free();
      debugPrint('[WebP-DECODER] createAnimDecoder FAILED');
      return null;
    }

    final decoder = WebPAnimDecoder._(
      bindings: _bind,
      ctx: ctx,
      nativeData: nativeData,
      canvasWidth: cW.value,
      canvasHeight: cH.value,
      frameCount: fC.value,
      loopCount: lC.value,
      targetWidth: aW.value,
      targetHeight: aH.value,
    );
    debugPrint('[WebP] +decoder #${_bind.animAliveCount()} ${decoder.frameCount}f ${decoder.targetWidth}x${decoder.targetHeight}');
    return decoder;
  } finally {
    calloc.free(cW);
    calloc.free(cH);
    calloc.free(fC);
    calloc.free(lC);
    calloc.free(aW);
    calloc.free(aH);
  }
}

// ═══════════════════════════════════════════════════════════════
// 高能效渲染引擎：调度器与解码器
// ═══════════════════════════════════════════════════════════════

/// 任务优先级（对应页面状态）
enum DecodePriority {
  current,    // 最高：当前页，多线程
  next,       // 中等：预取页，单线程
  background  // 最低：远端预读，单线程
}

/// 解码任务
class DecodeJob {
  final int generation;
  final int decoderAddress;
  final int framesToDecode;
  final int targetW;
  final int targetH;
  final void Function(List<WebPAnimFrameAddress> frames) onComplete;

  DecodeJob({
    required this.generation,
    required this.decoderAddress,
    required this.framesToDecode,
    required this.targetW,
    required this.targetH,
    required this.onComplete,
  });
}

/// 全局工作池调度器
class WorkerPoolScheduler {
  static final WorkerPoolScheduler instance = WorkerPoolScheduler._();
  WorkerPoolScheduler._();

  final Queue<DecodeJob> _currentQueue = Queue();
  final Queue<DecodeJob> _nextQueue = Queue();
  final Queue<DecodeJob> _bgQueue = Queue();

  bool _isProcessing = false;
  int _currentGeneration = 0;

  // 双工作线程：Worker 0 优先服务 CURRENT，Worker 1 处理 NEXT/BG 及溢出
  final List<SendPort?> _workerPorts = [null, null];
  final List<bool> _isInitializing = [false, false];
  final List<bool> _workerBusy = [false, false];

  void updateGeneration(int newGen) {
    _currentGeneration = newGen;
  }

  Future<void> _ensureWorker(int index) async {
    if (_workerPorts[index] != null || _isInitializing[index]) return;
    _isInitializing[index] = true;
    try {
      final receivePort = ReceivePort();
      await Isolate.spawn(_workerEntry, [receivePort.sendPort, index]);
      _workerPorts[index] = await receivePort.first as SendPort;
    } catch (e) {
      debugPrint('[WebP-Worker] Failed to initialize worker $index: $e');
    } finally {
      _isInitializing[index] = false;
    }
  }

  /// Worker Isolate 入口：批量解码，帧数据从原生缓冲池获取
  /// 消息格式：[replyPort, decoderAddress, count, targetW, targetH, generation]
  /// 回复格式：[addr1, dur1, addr2, dur2, ...]  (所有帧批量返回)
  static void _workerEntry(List args) {
    final mainPort = args[0] as SendPort;
    final workerIndex = args[1] as int;
    final receivePort = ReceivePort();
    mainPort.send(receivePort.sendPort);

    _WebPBindings? bindings;
    try {
      bindings = _WebPBindings(_loadLibrary());
    } catch (e) {
      debugPrint('[WebP-Worker] w$workerIndex lib load FAILED: $e');
    }

    final durationMsPtr = calloc<Int32>();

    receivePort.listen((message) {
      final data = message as List;
      final replyPort = data[0] as SendPort;
      final decoderAddress = data[1] as int;
      final count = data[2] as int;
      // data[3]=targetW, data[4]=targetH, data[5]=generation (reserved)

      if (bindings == null) {
        replyPort.send('Error: Library not loaded');
        return;
      }

      final List<int> results = [];

      try {
        if (decoderAddress == 0) {
          replyPort.send('Error: Null decoder');
          return;
        }

        final ctx = Pointer<Void>.fromAddress(decoderAddress);
        for (int i = 0; i < count; i++) {
          final rgbaPtr = bindings.animGetFrame(ctx, durationMsPtr);
          if (rgbaPtr == Pointer.fromAddress(0)) break;
          results.add(rgbaPtr.address);
          results.add(durationMsPtr.value);
        }
        replyPort.send(results);
      } catch (e, stack) {
        debugPrint('[WebP-Worker] w$workerIndex crash: $e\n$stack');
        replyPort.send('Error: $e');
      }
    });
  }

  void dispatch(DecodeJob job, DecodePriority priority) {
    switch (priority) {
      case DecodePriority.current:
        _currentQueue.add(job);
        break;
      case DecodePriority.next:
        _nextQueue.add(job);
        break;
      case DecodePriority.background:
        _bgQueue.add(job);
        break;
    }
    _scheduleNext();
  }

  void _scheduleNext() {
    if (_isProcessing) return;
    _isProcessing = true;
    scheduleMicrotask(() async {
      try {
        await _ensureWorker(0);
        await _ensureWorker(1);
        await _processQueues();
      } catch (e, stack) {
        debugPrint('[WebP-Worker] ERROR: $e\n$stack');
      } finally {
        _isProcessing = false;
      }
    });
  }

  Future<void> _processQueues() async {
    while (true) {
      // 找一个空闲 worker
      int? w;
      if (!_workerBusy[0]) {
        w = 0;
      } else if (!_workerBusy[1]) {
        w = 1;
      } else {
        break; // 两个 worker 都忙
      }

      // 从优先级队列取 job
      DecodeJob? job;
      DecodePriority? jobPri;
      if (_currentQueue.isNotEmpty) {
        job = _currentQueue.removeFirst();
        jobPri = DecodePriority.current;
      } else if (_nextQueue.isNotEmpty) {
        job = _nextQueue.removeFirst();
        jobPri = DecodePriority.next;
      } else if (_bgQueue.isNotEmpty) {
        job = _bgQueue.removeFirst();
        jobPri = DecodePriority.background;
      } else {
        break; // 无任务
      }

      if (job.generation != _currentGeneration) {
        // 过期任务：释放深拷贝缓冲区（由 onComplete 处理，这里传空列表）
        job.onComplete([]);
        continue;
      }

      // CURRENT 优先用 Worker 0
      final targetWorker = (jobPri == DecodePriority.current && !_workerBusy[0]) ? 0 : w;
      _runJob(job, targetWorker);
    }
  }

  /// 派发单个 job 到指定 worker，等待批量回复后调用 onComplete
  void _runJob(DecodeJob job, int workerIndex) async {
    final port = _workerPorts[workerIndex];
    if (port == null) {
      job.onComplete([]);
      return;
    }

    _workerBusy[workerIndex] = true;
    final t0 = DateTime.now().microsecondsSinceEpoch;
    try {
      final replyPort = ReceivePort();
      port.send([replyPort.sendPort, job.decoderAddress, job.framesToDecode,
                 job.targetW, job.targetH, job.generation]);

      final result = await replyPort.first;
      replyPort.close();
      final dt = (DateTime.now().microsecondsSinceEpoch - t0) ~/ 1000;

      if (result is List<int>) {
        final n = result.length ~/ 2;
        if (job.generation == _currentGeneration) {
          final List<WebPAnimFrameAddress> frames = [];
          for (int i = 0; i < result.length; i += 2) {
            frames.add(WebPAnimFrameAddress(
              address: result[i],
              durationMs: result[i + 1],
            ));
          }
          debugPrint('[WebP-Worker] w$workerIndex +$n frames ${dt}ms gen=${job.generation}');
          job.onComplete(frames);
        } else {
          // 过期：归还原生缓冲池中的帧缓冲区
          for (int i = 0; i < result.length; i += 2) {
            nativePoolRelease(result[i]);
          }
          job.onComplete([]);
        }
      } else {
        debugPrint('[WebP-Worker] w$workerIndex error: $result');
        job.onComplete([]);
      }
    } catch (e) {
      debugPrint('[WebP-Worker] w$workerIndex exception: $e');
      job.onComplete([]);
    } finally {
      _workerBusy[workerIndex] = false;
      _scheduleNext();
    }
  }
}

class WebPAnimDecoder {
  final _WebPBindings _bindings;
  final Pointer<Void> _ctx;
  final Pointer<Uint8> _nativeData;
  bool _disposed = false;

  /// 原始画布尺寸
  final int canvasWidth;
  final int canvasHeight;

  /// 目标画布尺寸（保持宽高比后的实际尺寸）
  final int targetWidth;
  final int targetHeight;

  /// 总帧数
  final int frameCount;

  /// 循环次数（0=无限循环）
  final int loopCount;

  WebPAnimDecoder._({
    required _WebPBindings bindings,
    required Pointer<Void> ctx,
    required Pointer<Uint8> nativeData,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.frameCount,
    required this.loopCount,
    required this.targetWidth,
    required this.targetHeight,
  })  : _bindings = bindings,
        _ctx = ctx,
        _nativeData = nativeData;

  int get address => _ctx.address;

  /// 当前是否仍有帧可获取（委托 C 层判断）
  bool get hasMoreFrames {
    _checkNotDisposed();
    return _bindings.animHasMore(_ctx) != 0;
  }

  /// 动态设置解码线程限制 (0/1=单线程, 2/3=多线程)
  void setThreadLimit(int useThreads) {
    _checkNotDisposed();
    _bindings.animSetThreadLimit(_ctx, useThreads);
  }

  /// 获取下一帧（目标尺寸 RGBA，deep copy 到 dart heap）。
  /// 仅用于离线批量解码或同步场景。
  WebPAnimFrame? getNextFrame() {
    _checkNotDisposed();
    if (!hasMoreFrames) return null;
    final durationMs = calloc<Int32>();
    try {
      final rgbaPtr = _bindings.animGetFrame(_ctx, durationMs);
      if (rgbaPtr == Pointer.fromAddress(0)) return null;
      final length = targetWidth * targetHeight * 4;
      final rgba = rgbaPtr.asTypedList(length);
      return WebPAnimFrame(
        rgba: Uint8List.fromList(rgba),
        durationMs: durationMs.value,
      );
    } finally {
      calloc.free(durationMs);
    }
  }

  /// 重置到第一帧
  void reset() {
    _checkNotDisposed();
    _bindings.animReset(_ctx);
  }

  /// 释放所有原生资源
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.animDelete(_ctx);
    final alive = _bindings.animAliveCount();
    debugPrint('[WebP] -decoder ($alive remain)');
    _nativeData._free();
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('WebPAnimDecoder is already disposed');
  }
}

// ═══════════════════════════════════════════════════════════════
// 原生内存辅助
// ═══════════════════════════════════════════════════════════════

extension _Uint8ListNative on Uint8List {
  /// 将 [Uint8List] 拷贝到原生堆，返回 Pointer，调用者负责 [free]。
  Pointer<Uint8> _asNative() {
    final ptr = calloc<Uint8>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension _PointerFree on Pointer<Uint8> {
  void _free() {
    calloc.free(this);
  }
}
