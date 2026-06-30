import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
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

typedef _WebPAnimDecoderAliveCountNative = Int32 Function();
typedef _WebPAnimDecoderAliveCountDart = int Function();

typedef _WebPFreeBufferNative = Void Function(Pointer<Uint8> buf);
typedef _WebPFreeBufferDart = void Function(Pointer<Uint8> buf);

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
  late final _WebPAnimDecoderAliveCountDart animAliveCount;
  late final _WebPFreeBufferDart freeBuffer;
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
    animAliveCount = _lib.lookupFunction<_WebPAnimDecoderAliveCountNative,
        _WebPAnimDecoderAliveCountDart>('webp_anim_decoder_alive_count');
    freeBuffer = _lib.lookupFunction<_WebPFreeBufferNative, _WebPFreeBufferDart>(
        'webp_free_buffer');
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

/// 帧缓存最大数量（防止内存爆炸导致系统节流）
const int _kMaxCachedFrames = 20;

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
    debugPrint('[WebP-DECODER] CREATE #${_bind.animAliveCount()} ctx=${ctx.address.toRadixString(16)} frames=${decoder.frameCount} target=${decoder.targetWidth}x${decoder.targetHeight}');
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
// 动画解码器类
// ═══════════════════════════════════════════════════════════════

/// 动画 WebP 解码器。
///
/// 内部持有 native 的 demuxer + 合成画布。
/// 帧解码直接得到目标尺寸的 RGBA（C 层已完成 composite + downscale）。
///
/// **第一次循环时缓存所有帧 RGBA，后续循环直接从缓存读取，不再调用 C。**
/// Isolate Worker 池：N 个持久化 Worker，匹配活跃动画数。
/// 消除 Isolate.run() 创建/销毁开销，同时保持 N 路并发避免串行瓶颈。
class _WorkerPool {
  final List<SendPort> _workers = [];
  int _next = 0;
  bool _init = false;

  Future<void> _ensureInit() async {
    if (_init) return;
    _init = true;
    // 匹配 _maxActive=3，创建 3 个 worker
    for (int i = 0; i < 3; i++) {
      final r = ReceivePort();
      await Isolate.spawn((SendPort mainPort) {
        final workerR = ReceivePort();
        mainPort.send(workerR.sendPort);
        final lib = DynamicLibrary.open('libvenera_webp.so');
        final animGetFrame = lib.lookupFunction<_WebPAnimDecoderGetFrameNative, _WebPAnimDecoderGetFrameDart>('webp_anim_decoder_get_frame');
        workerR.listen((msg) {
          final list = msg as List<Object?>;
          final replyTo = list[0] as SendPort;
          final ctxAddr = list[1] as int;
          final durationMs = calloc<Int32>();
          try {
            final ctx = Pointer<Void>.fromAddress(ctxAddr);
            final rgbaPtr = animGetFrame(ctx, durationMs);
            replyTo.send(rgbaPtr != Pointer.fromAddress(0) ? [rgbaPtr.address, durationMs.value] : null);
          } finally {
            calloc.free(durationMs);
          }
        });
      }, r.sendPort);
      _workers.add(await r.first as SendPort);
      r.close();
    }
  }

  Future<SendPort> acquire() async {
    await _ensureInit();
    return _workers[_next++ % _workers.length]; // 轮询分配
  }
}
final _workerPool = _WorkerPool();

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

  /// 当前解码到的帧序号（0-based，缓存遍历）
  int _cacheIndex = -1;

  /// 帧 RGBA 缓存 + 时间戳（第一轮解码时填充）
  final List<Uint8List?> _cachedFrames = [];
  final List<int> _cachedTimestamps = [];

  /// 缓存是否已填满
  bool get _cacheFull => _cachedFrames.length >= frameCount;

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

  /// 当前是否仍有帧可获取
  bool get hasMoreFrames {
    _checkNotDisposed();
    if (_cacheFull) {
      // 缓存已满：从缓存遍历，缓存仅存前 _kMaxCachedFrames 帧
      // 超出缓存范围的帧不再重复解码（直接返回 false 表示本轮结束）
      if (_cacheIndex + 1 >= frameCount) return false;
      // 超过缓存范围的帧不重复解码，继续消耗缓存
      return true;
    }
    // 由 C 层控制（它也处理循环逻辑）
    return _bindings.animHasMore(_ctx) != 0;
  }

  /// 已返回的帧数（从0开始）
  int get currentIndex => _cacheIndex;

  /// 获取下一帧（目标尺寸 RGBA）
  ///
  /// 返回 [WebPAnimFrame] 或 null（已到末尾）。
  WebPAnimFrame? getNextFrame() {
    _checkNotDisposed();
    return _getNextFrameInternal();
  }

  /// 通过 Isolate Worker 池获取下一帧（3 个持久化 Worker，轮询分配）
  Future<WebPAnimFrameAddress?> getNextFrameAsync({bool pool = false}) async {
    _checkNotDisposed();
    final sp = await _workerPool.acquire();
    final reply = ReceivePort();
    sp.send([reply.sendPort, _ctx.address]);
    final result = await reply.first;
    reply.close();
    if (result == null) return null;
    final list = result as List<Object?>;
    return WebPAnimFrameAddress(address: list[0] as int, durationMs: list[1] as int);
  }

  WebPAnimFrame? _getNextFrameInternal() {
    if (!hasMoreFrames) return null;

    _cacheIndex++;

    // 缓存命中：直接返回
    if (_cacheFull && _cacheIndex < _cachedFrames.length) {
      final cached = _cachedFrames[_cacheIndex];
      if (cached != null) {
        return WebPAnimFrame(
          rgba: cached,
          durationMs: _cachedTimestamps[_cacheIndex],
        );
      }
    }

    // 缓存未命中：从 C 解码
    final durationMs = calloc<Int32>();

    try {
      final rgbaPtr = _bindings.animGetFrame(_ctx, durationMs);
      if (rgbaPtr == Pointer.fromAddress(0)) {
        _cacheIndex--;
        return null;
      }

      final length = targetWidth * targetHeight * 4;
      final rgba = rgbaPtr.asTypedList(length);
      final dartRgba = Uint8List.fromList(rgba);

      // 限制缓存大小
      if (_cachedFrames.length < _kMaxCachedFrames) {
        _cachedFrames.add(dartRgba);
        _cachedTimestamps.add(durationMs.value);
      }

      return WebPAnimFrame(
        rgba: dartRgba,
        durationMs: durationMs.value,
      );
    } finally {
      calloc.free(durationMs);
    }
  }

  /// 重置到第一帧（不清除缓存，后续循环走缓存）
  void reset() {
    _checkNotDisposed();

    if (_cacheFull) {
      // 缓存已满：不调 C，直接重置游标
      _cacheIndex = -1;
      debugPrint('[WebP] anim reset (cached, skip C)');
      return;
    }

    // 缓存未满：调 C 重置
    _bindings.animReset(_ctx);
    _cacheIndex = -1;
  }

  /// 释放所有原生资源
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final ctxAddr = _ctx.address.toRadixString(16);
    _bindings.animDelete(_ctx);
    final alive = _bindings.animAliveCount();
    debugPrint('[WebP-DECODER] DISPOSE ctx=$ctxAddr remaining=$alive');
    _nativeData._free();
    _cachedFrames.clear();
    _cachedTimestamps.clear();
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
