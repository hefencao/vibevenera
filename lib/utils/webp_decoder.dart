import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

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

typedef _WebPDecodeScaledDart = Pointer<Uint8> Function(
  Pointer<Uint8> data,
  int size,
  int targetWidth,
  int targetHeight,
  Pointer<Int32> outWidth,
  Pointer<Int32> outHeight,
);

typedef _WebPDecodeScaledNative = Pointer<Uint8> Function(
  Pointer<Uint8> data,
  Uint64 size,
  Int32 targetWidth,
  Int32 targetHeight,
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

typedef _WebPAnimDecoderGetFramesNative = Int32 Function(
  Pointer<Void> ctx, Int32 count, Pointer<Int64> outResults);
typedef _WebPAnimDecoderGetFramesDart = int Function(
  Pointer<Void> ctx, int count, Pointer<Int64> outResults);

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

typedef _WebPInitNativeNative = Void Function();
typedef _WebPInitNativeDart = void Function();

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
  // [FIX-BUG-2] 原实现有 3 个 try block，第一次和第三次都加载 .so（死代码）。
  // 改为循环尝试多个候选名，覆盖 Android/Linux / macOS / Windows。
  final candidates = <String>[
    'libvenera_webp.so',    // Android / Linux
    'libvenera_webp.dylib', // macOS
    'libvenera_webp.dll',   // Windows
  ];

  Object? lastError;
  for (final name in candidates) {
    try {
      return DynamicLibrary.open(name);
    } catch (e) {
      lastError = e;
    }
  }

  throw UnsupportedError(
    'Cannot load libvenera_webp native library: $lastError. '
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
  late final _WebPAnimDecoderGetFramesDart animGetFrames;
  late final _WebPAnimDecoderHasMoreDart animHasMore;
  late final _WebPAnimDecoderResetDart animReset;
  late final _WebPAnimDecoderDeleteDart animDelete;
  late final _WebPAnimDecoderSetThreadLimitDart animSetThreadLimit;
  late final _WebPAnimDecoderAliveCountDart animAliveCount;
  late final _WebPFreeBufferDart freeBuffer;
  late final _WebPNativePoolAcquireDart poolAcquire;
  late final _WebPInitNativeDart initNative;
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
    animGetFrames = _lib.lookupFunction<_WebPAnimDecoderGetFramesNative,
        _WebPAnimDecoderGetFramesDart>('webp_anim_decoder_get_frames');
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
    initNative = _lib.lookupFunction<_WebPInitNativeNative,
        _WebPInitNativeDart>('webp_init_native');
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
// WebP 格式检测
// ═══════════════════════════════════════════════════════════════

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

void nativePoolRelease(int address) {
  _bind.poolRelease(Pointer<Uint8>.fromAddress(address));
}

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

enum DecodePriority {
  current,    // 最高：当前页，多线程
  next,       // 中等：预取页，单线程
  background  // 最低：远端预读，单线程
}

class DecodeJob {
  final int generation;
  final int decoderAddress;
  final int framesToDecode;
  final int targetW;
  final int targetH;
  final void Function(List<WebPAnimFrameAddress> frames) onComplete;
  final int dispatchedAt; // us, for queue wait time measurement

  DecodeJob({
    required this.generation,
    required this.decoderAddress,
    required this.framesToDecode,
    required this.targetW,
    required this.targetH,
    required this.onComplete,
  }) : dispatchedAt = DateTime.now().microsecondsSinceEpoch;
}

class WorkerPoolScheduler {
  static final WorkerPoolScheduler instance = WorkerPoolScheduler._();

  static bool _nativeInitDone = false;

  /// 初始化 C 层持久化线程池（幂等，首次调用生效）。
  static void ensureNativeInit() {
    if (_nativeInitDone) return;
    _nativeInitDone = true;
    try {
      _bind.initNative();
    } catch (_) {
      // C 层会自动回退到单线程模式
    }
  }

  WorkerPoolScheduler._() {
    ensureNativeInit();
    // 性能优化（线程预热）：启动时预加载并热身两个常驻后台解码 Isolate，消减首屏启动延迟
    scheduleMicrotask(() async {
      await _ensureWorker(0);
      await _ensureWorker(1);
    });
  }

  final Queue<DecodeJob> _currentQueue = Queue();
  final Queue<DecodeJob> _nextQueue = Queue();
  final Queue<DecodeJob> _bgQueue = Queue();

  bool _isProcessing = false;
  int _currentGeneration = 0;

  final List<SendPort?> _workerPorts = [null, null];
  final List<bool> _isInitializing = [false, false];
  final List<bool> _workerBusy = [false, false];

  // Round-robin counter for decoder creation (avoids worker 0 bottleneck)
  int _nextDecoderWorker = 0; // ignore: unused_field

  void updateGeneration(int newGen) {
    _currentGeneration = newGen;
  }

  /// 在 Worker Isolate 中异步创建解码器，主线程零 C 堆开销。
  /// 使用 round-robin 分配 worker，避免单个 worker 成为瓶颈。
  Future<WebPAnimDecoder?> createDecoderAsync(Uint8List data, int tw, int th) async {
    // 确保两个 worker 都已启动
    await _ensureWorker(0);
    await _ensureWorker(1);

    // round-robin 选择 worker，与帧解码共享同一组 worker
    final workerIndex = _nextDecoderWorker;
    _nextDecoderWorker = (_nextDecoderWorker + 1) % 2;

    final port = _workerPorts[workerIndex];
    if (port == null) return null;

    _workerBusy[workerIndex] = true;
    try {
      final replyPort = ReceivePort();
      port.send(['new_decoder', replyPort.sendPort, data, tw, th]);

      final result = await replyPort.first;
      replyPort.close();

      if (result is List && result[0] != 0) {
        return WebPAnimDecoder._fromWorker(
          bindings: _bind,
          ctxAddress: result[0],
          nativeDataAddress: result[1],
          canvasWidth: result[2],
          canvasHeight: result[3],
          frameCount: result[4],
          loopCount: result[5],
          targetWidth: result[6],
          targetHeight: result[7],
        );
      }
      return null;
    } finally {
      _workerBusy[workerIndex] = false;
      _scheduleNext(); // 唤醒可能等待中的帧解码任务
    }
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

  /// Worker Isolate 入口
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

    receivePort.listen((message) {
      final data = message as List;

      if (bindings == null) {
        (data[0] as SendPort).send('Error: Library not loaded');
        return;
      }

      // 消息路由：'new_decoder' 创建解码器，否则为帧解码请求
      if (data[0] is String && data[0] == 'new_decoder') {
        final replyPort = data[1] as SendPort;
        final Uint8List dartBytes = data[2];
        final int tw = data[3];
        final int th = data[4];

        try {
          final nativeData = dartBytes._asNative();
          final cW = calloc<Int32>(), cH = calloc<Int32>();
          final fC = calloc<Int32>(), lC = calloc<Int32>();
          final aW = calloc<Int32>(), aH = calloc<Int32>();

          final ctx = bindings.animNew(nativeData, dartBytes.length, tw, th, cW, cH, fC, lC, aW, aH);
          if (ctx == Pointer.fromAddress(0)) {
            nativeData._free();
            replyPort.send(null);
          } else {
            replyPort.send([ctx.address, nativeData.address, cW.value, cH.value, fC.value, lC.value, aW.value, aH.value]);
          }
          calloc.free(cW); calloc.free(cH); calloc.free(fC);
          calloc.free(lC); calloc.free(aW); calloc.free(aH);
        } catch (e) {
          replyPort.send(null);
        }
        return;
      }

      // 帧解码请求
      final replyPort = data[0] as SendPort;
      final decoderAddress = data[1] as int;
      final count = data[2] as int;

      try {
        if (decoderAddress == 0) {
          replyPort.send('Error: Null decoder');
          return;
        }

        final ctx = Pointer<Void>.fromAddress(decoderAddress);
        // 单次 FFI 调用批量解码 N 帧，消除 per-frame FFI 往返开销
        final cResults = calloc<Int64>(count * 2);
        final tStart = DateTime.now().microsecondsSinceEpoch;
        final n = bindings.animGetFrames(ctx, count, cResults);
        final dtTotal = (DateTime.now().microsecondsSinceEpoch - tStart) ~/ 1000;

        if (n > 0) {
          final results = Int64List.fromList(cResults.asTypedList(n * 2));
          calloc.free(cResults);
          replyPort.send(results);
          debugPrint('[WebP-T] w$workerIndex batch=$n/$count total=${dtTotal}ms avg=${n>0?dtTotal~/n:0}ms/f addr=${decoderAddress & 0xFFFF}');
        } else {
          calloc.free(cResults);
          replyPort.send(Int64List(0));
          debugPrint('[WebP-T] w$workerIndex batch=0/$count (eos) addr=${decoderAddress & 0xFFFF}');
        }
      } catch (e, stack) {
        debugPrint('[WebP-Worker] w$workerIndex crash: $e\n$stack');
        replyPort.send('Error: $e');
      }
    });
  }

  void dispatch(DecodeJob job, DecodePriority priority) {
    // [ANALYSIS-2] Reject stale jobs immediately — before they ever
    // enter the queue. Previously the generation check happened
    // AFTER the worker had already done the decode work.
    if (job.generation != _currentGeneration) {
      debugPrint('[WebP-T] dispatch REJECT stale gen=${job.generation} '
          'curr=$_currentGeneration addr=${job.decoderAddress & 0xFFFF}');
      job.onComplete([]);
      return;
    }
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
    // ctx-hash affinity: each decoder pinned to a specific worker
    // to prevent concurrent access to non-thread-safe C decoder state.
    while (true) {
      // Find a free worker and a job whose ctx-hash matches it
      int? assignedWorker;
      DecodeJob? job;
      Queue<DecodeJob>? sourceQueue;

      for (final w in [0, 1]) {
        if (_workerBusy[w]) continue;

        // Scan queues in priority order for a job matching worker w
        final queues = [
          (_currentQueue, DecodePriority.current),
          (_nextQueue, DecodePriority.next),
          (_bgQueue, DecodePriority.background),
        ];

        for (final (queue, _) in queues) {
          if (queue.isEmpty) continue;
          // Find first job in this queue whose decoder hashes to worker w
          for (final j in queue) {
            if (j.decoderAddress % 2 == w) {
              job = j;
              assignedWorker = w;
              sourceQueue = queue;
              break;
            }
          }
          if (job != null) break;
        }

        // Fallback: if no job hashes to worker w, take any job
        if (job == null) {
          if (_currentQueue.isNotEmpty) {
            job = _currentQueue.first;
            assignedWorker = w;
            sourceQueue = _currentQueue;
          } else if (_nextQueue.isNotEmpty) {
            job = _nextQueue.first;
            assignedWorker = w;
            sourceQueue = _nextQueue;
          } else if (_bgQueue.isNotEmpty) {
            job = _bgQueue.first;
            assignedWorker = w;
            sourceQueue = _bgQueue;
          }
        }

        if (job != null) break; // found work for this worker
      }

      if (job == null) break; // no work can be dispatched

      sourceQueue!.remove(job);

      final queueWaitUs = DateTime.now().microsecondsSinceEpoch - job.dispatchedAt;
      debugPrint('[WebP-T] w$assignedWorker dequeue wait=${queueWaitUs ~/ 1000}ms '
          'n=${job.framesToDecode} addr=${job.decoderAddress & 0xFFFF} gen=${job.generation}');

      if (job.generation != _currentGeneration) {
        debugPrint('[WebP-T] w$assignedWorker stale gen=${job.generation} curr=${_currentGeneration}');
        job.onComplete([]);
        continue;
      }

      _runJob(job, assignedWorker!);
    }
  }

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

      if (result is Int64List) {
        final n = result.length ~/ 2;
        if (job.generation == _currentGeneration) {
          final List<WebPAnimFrameAddress> frames = [];
          for (int i = 0; i < result.length; i += 2) {
            frames.add(WebPAnimFrameAddress(
              address: result[i],
              durationMs: result[i + 1],
            ));
          }
          final avgPerFrame = n > 0 ? dt ~/ n : 0;
          debugPrint('[WebP-T] w$workerIndex recv $n frames rtt=${dt}ms avg=$avgPerFrame ms/f gen=${job.generation}');
          job.onComplete(frames);
        } else {
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

  final int canvasWidth;
  final int canvasHeight;
  final int targetWidth;
  final int targetHeight;
  final int frameCount;
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

  /// 从 Worker Isolate 返回的原始地址重建解码器（主线程零 C 堆分配）
  WebPAnimDecoder._fromWorker({
    required _WebPBindings bindings,
    required int ctxAddress,
    required int nativeDataAddress,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.frameCount,
    required this.loopCount,
    required this.targetWidth,
    required this.targetHeight,
  })  : _bindings = bindings,
        _ctx = Pointer.fromAddress(ctxAddress),
        _nativeData = Pointer.fromAddress(nativeDataAddress);

  int get address => _ctx.address;

  bool get hasMoreFrames {
    _checkNotDisposed();
    return _bindings.animHasMore(_ctx) != 0;
  }

  void setThreadLimit(int useThreads) {
    _checkNotDisposed();
    _bindings.animSetThreadLimit(_ctx, useThreads);
  }

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

  void reset() {
    _checkNotDisposed();
    _bindings.animReset(_ctx);
  }

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