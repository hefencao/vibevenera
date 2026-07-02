import 'dart:async';
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
/// Isolate Worker 池：N 个持久化 Worker。
/// 消息协议：[replyTo, ctxAddr, gen] — 3 元素为 decode 请求，2 元素为控制消息。
class _WorkerPool {
  final List<SendPort> _workers = [];
  bool _init = false;
  static int _nextGen = 1;

  static int nextGen() => _nextGen++;

  Future<void> _ensureInit() async {
    if (_init) return;
    _init = true;
    for (int i = 0; i < 3; i++) {
      final r = ReceivePort();
      await Isolate.spawn((SendPort mainPort) {
        final workerR = ReceivePort();
        mainPort.send(workerR.sendPort);
        final lib = DynamicLibrary.open('libvenera_webp.so');
        final animGetFrame = lib.lookupFunction<_WebPAnimDecoderGetFrameNative, _WebPAnimDecoderGetFrameDart>('webp_anim_decoder_get_frame');
        // 每个 ctx 的当前有效 generation
        final Map<int, int> validGens = {};
        workerR.listen((msg) {
          final list = msg as List<Object?>;
          final replyTo = list[0];
          final ctxAddr = list[1] as int;
          if (replyTo == null) {
            // 控制消息：gen=0 表示移除该 ctx 的 generation 记录
            if (list[2] as int == 0) {
              validGens.remove(ctxAddr);
            }
            return;
          }
          // Decode 消息：[replyTo, ctxAddr, gen]
          final gen = list[2] as int;
          if (validGens.containsKey(ctxAddr) && validGens[ctxAddr] != gen) {
            (replyTo as SendPort).send(null); // generation 不匹配，丢弃
            return;
          }
          validGens[ctxAddr] = gen; // 首次使用或匹配成功
          final durationMs = calloc<Int32>();
          try {
            final ctx = Pointer<Void>.fromAddress(ctxAddr);
            final rgbaPtr = animGetFrame(ctx, durationMs);
            (replyTo as SendPort).send(rgbaPtr != Pointer.fromAddress(0) ? [rgbaPtr.address, durationMs.value] : null);
          } finally {
            calloc.free(durationMs);
          }
        });
      }, r.sendPort);
      _workers.add(await r.first as SendPort);
      r.close();
    }
  }

  Future<SendPort> acquire(int ctxAddress) async {
    await _ensureInit();
    // 按 ctx 地址哈希分配到固定 worker，确保同一 ctx 的所有调用
    // 都路由到同一个 worker → 顺序处理，避免并发访问非线程安全的 C 状态。
    final hash = ctxAddress.hashCode;
    return _workers[(hash & 0x7FFFFFFF) % _workers.length];
  }

  /// 使指定 ctx 的所有在途消息失效。
  /// gen=0 表示 remove：worker 删除该 ctx 的 generation 记录。
  /// 由于 _workerGen 全局唯一，新 decoder 不会复用旧 generation，remove 安全。
  void cancelCtx(int ctxAddress) {
    if (!_init || _workers.isEmpty) return;
    for (final w in _workers) {
      w.send(<Object?>[null, ctxAddress, 0]);
    }
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

  /// 当前是否仍有帧可获取（委托 C 层判断）
  bool get hasMoreFrames {
    _checkNotDisposed();
    return _bindings.animHasMore(_ctx) != 0;
  }

  /// 获取下一帧（目标尺寸 RGBA，deep copy 到 dart heap）。
  /// 注意：热路径走 [getNextFrameAsync]（零拷贝），此方法仅用于离线批量解码。
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

  final int _workerGen = _WorkerPool.nextGen();

  /// 通过 Isolate Worker 池获取下一帧（零拷贝，返回 C buffer 地址）。
  /// 消息携带 generation 计数器，Worker 校验通过后才执行 decode，
  /// 防止 dispose 后 Worker 仍访问已释放的 ctx。
  Future<WebPAnimFrameAddress?> getNextFrameAsync() async {
    _checkNotDisposed();
    final sp = await _workerPool.acquire(_ctx.address);
    final reply = ReceivePort();
    try {
      sp.send([reply.sendPort, _ctx.address, _workerGen]);
      final result = await reply.first;
      if (result == null) return null;
      final list = result as List<Object?>;
      return WebPAnimFrameAddress(address: list[0] as int, durationMs: list[1] as int);
    } finally {
      reply.close();
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
    // 通知 Worker 取消该 ctx 的所有在途消息
    _workerPool.cancelCtx(_ctx.address);
    final ctxAddr = _ctx.address.toRadixString(16);
    _bindings.animDelete(_ctx);
    final alive = _bindings.animAliveCount();
    debugPrint('[WebP-DECODER] DISPOSE ctx=$ctxAddr remaining=$alive');
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
