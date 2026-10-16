import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:venera/utils/trace_log.dart';
import 'package:venera/utils/image_pipeline_perf.dart';

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

typedef _WebPAnimStreamDecoderNewNative = Pointer<Void> Function(
  Int32 targetWidth,
  Int32 targetHeight,
);
typedef _WebPAnimStreamDecoderNewDart = Pointer<Void> Function(
  int targetWidth,
  int targetHeight,
);

typedef _WebPAnimStreamDecoderAppendNative = Int32 Function(
  Pointer<Void> ctx,
  Pointer<Uint8> data,
  Uint64 size,
  Int32 isFinal,
);
typedef _WebPAnimStreamDecoderAppendDart = int Function(
  Pointer<Void> ctx,
  Pointer<Uint8> data,
  int size,
  int isFinal,
);

typedef _WebPAnimStreamDecoderResetInputNative = Void Function(
  Pointer<Void> ctx,
);
typedef _WebPAnimStreamDecoderResetInputDart = void Function(
  Pointer<Void> ctx,
);

typedef _WebPAnimStreamDecoderRestartPlaybackNative = Void Function(
  Pointer<Void> ctx,
);
typedef _WebPAnimStreamDecoderRestartPlaybackDart = void Function(
  Pointer<Void> ctx,
);

typedef _WebPAnimStreamDecoderGetInfoNative = Int32 Function(
  Pointer<Void> ctx,
  Pointer<Int32> canvasWidth,
  Pointer<Int32> canvasHeight,
  Pointer<Int32> frameCount,
  Pointer<Int32> loopCount,
  Pointer<Int32> actualWidth,
  Pointer<Int32> actualHeight,
  Pointer<Int32> isAnimated,
  Pointer<Int32> isReady,
  Pointer<Int32> isFinal,
);
typedef _WebPAnimStreamDecoderGetInfoDart = int Function(
  Pointer<Void> ctx,
  Pointer<Int32> canvasWidth,
  Pointer<Int32> canvasHeight,
  Pointer<Int32> frameCount,
  Pointer<Int32> loopCount,
  Pointer<Int32> actualWidth,
  Pointer<Int32> actualHeight,
  Pointer<Int32> isAnimated,
  Pointer<Int32> isReady,
  Pointer<Int32> isFinal,
);

typedef _WebPAnimStreamDecoderGetFramesNative = Int32 Function(
  Pointer<Void> ctx, Int32 count, Pointer<Int64> outResults);
typedef _WebPAnimStreamDecoderGetFramesDart = int Function(
  Pointer<Void> ctx, int count, Pointer<Int64> outResults);

typedef _WebPAnimStreamDecoderSetThreadLimitNative = Void Function(
  Pointer<Void> ctx,
  Int32 useThreads,
);
typedef _WebPAnimStreamDecoderSetThreadLimitDart = void Function(
  Pointer<Void> ctx,
  int useThreads,
);

typedef _WebPAnimStreamDecoderDeleteNative = Void Function(Pointer<Void> ctx);
typedef _WebPAnimStreamDecoderDeleteDart = void Function(Pointer<Void> ctx);

final class _NativeWebPSourceState extends Struct {
  @Uint64()
  external int epoch;
  @Uint64()
  external int expectedLength;
  @Uint64()
  external int committedLength;
  @Uint64()
  external int declaredLength;
  @Uint64()
  external int parsedOffset;
  @Int32()
  external int sealed;
  @Int32()
  external int failed;
  @Int32()
  external int lastError;
  @Int32()
  external int canvasWidth;
  @Int32()
  external int canvasHeight;
  @Int32()
  external int loopCount;
  @Int32()
  external int frameCount;
  @Int32()
  external int animated;
}

class NativeWebPSourceState {
  final int epoch;
  final int expectedLength;
  final int committedLength;
  final int declaredLength;
  final int parsedOffset;
  final bool sealed;
  final bool failed;
  final int lastError;
  final int canvasWidth;
  final int canvasHeight;
  final int loopCount;
  final int frameCount;
  final bool animated;

  const NativeWebPSourceState({
    required this.epoch,
    required this.expectedLength,
    required this.committedLength,
    required this.declaredLength,
    required this.parsedOffset,
    required this.sealed,
    required this.failed,
    required this.lastError,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.loopCount,
    required this.frameCount,
    required this.animated,
  });
}

class NativeWebPFrameDescriptor {
  final int payloadOffset;
  final int payloadLength;
  final int xOffset;
  final int yOffset;
  final int width;
  final int height;
  final int durationMs;
  final int disposeMethod;
  final int blendMethod;
  final bool hasAlpha;

  const NativeWebPFrameDescriptor({
    required this.payloadOffset,
    required this.payloadLength,
    required this.xOffset,
    required this.yOffset,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.disposeMethod,
    required this.blendMethod,
    required this.hasAlpha,
  });
}

abstract interface class WebPByteSource {
  int get epoch;
  bool get isDisposed;
  NativeWebPSourceState get state;
  void append(Uint8List bytes, {required int offset});
  void seal();
  void reset({int expectedLength = 0, required int epoch});
  NativeWebPFrameDescriptor frameAt(int index);
  void dispose();
}

final class _NativeWebPSourceFrame extends Struct {
  @Uint64()
  external int payloadOffset;
  @Uint64()
  external int payloadLength;
  @Int32()
  external int xOffset;
  @Int32()
  external int yOffset;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int durationMs;
  @Int32()
  external int disposeMethod;
  @Int32()
  external int blendMethod;
  @Int32()
  external int hasAlpha;
}

typedef _WebPSourceNewNative = Pointer<Void> Function(Uint64, Uint64);
typedef _WebPSourceNewDart = Pointer<Void> Function(int, int);
typedef _WebPSourceReserveNative = Pointer<Uint8> Function(
  Pointer<Void>, Uint64, Uint64, Uint64);
typedef _WebPSourceReserveDart = Pointer<Uint8> Function(
  Pointer<Void>, int, int, int);
typedef _WebPSourceCommitNative = Int32 Function(
  Pointer<Void>, Uint64, Uint64, Uint64);
typedef _WebPSourceCommitDart = int Function(Pointer<Void>, int, int, int);
typedef _WebPSourceSealNative = Int32 Function(Pointer<Void>, Uint64);
typedef _WebPSourceSealDart = int Function(Pointer<Void>, int);
typedef _WebPSourceResetNative = Int32 Function(
  Pointer<Void>, Uint64, Uint64);
typedef _WebPSourceResetDart = int Function(Pointer<Void>, int, int);
typedef _WebPSourceGetStateNative = Int32 Function(
  Pointer<Void>, Pointer<_NativeWebPSourceState>);
typedef _WebPSourceGetStateDart = int Function(
  Pointer<Void>, Pointer<_NativeWebPSourceState>);
typedef _WebPSourceGetFrameNative = Int32 Function(
  Pointer<Void>, Int32, Pointer<_NativeWebPSourceFrame>);
typedef _WebPSourceGetFrameDart = int Function(
  Pointer<Void>, int, Pointer<_NativeWebPSourceFrame>);
typedef _WebPSourceDeleteNative = Void Function(Pointer<Void>);
typedef _WebPSourceDeleteDart = void Function(Pointer<Void>);

final class _NativeWebPPlaybackCursorState extends Struct {
  @Uint64()
  external int sourceEpoch;
  @Uint64()
  external int committedLength;
  @Int32()
  external int canvasWidth;
  @Int32()
  external int canvasHeight;
  @Int32()
  external int targetWidth;
  @Int32()
  external int targetHeight;
  @Int32()
  external int availableFrames;
  @Int32()
  external int nextFrame;
  @Int32()
  external int loopCount;
  @Int32()
  external int ready;
  @Int32()
  external int sourceSealed;
  @Int32()
  external int atAvailableEnd;
  @Int32()
  external int complete;
  @Int32()
  external int failed;
  @Int32()
  external int lastError;
}

typedef _WebPPlaybackCursorNewNative = Pointer<Void> Function(
  Pointer<Void>, Int32, Int32);
typedef _WebPPlaybackCursorNewDart = Pointer<Void> Function(
  Pointer<Void>, int, int);
typedef _WebPPlaybackCursorGetStateNative = Int32 Function(
  Pointer<Void>, Pointer<_NativeWebPPlaybackCursorState>);
typedef _WebPPlaybackCursorGetStateDart = int Function(
  Pointer<Void>, Pointer<_NativeWebPPlaybackCursorState>);
typedef _WebPPlaybackCursorGetFramesNative = Int32 Function(
  Pointer<Void>, Int32, Pointer<Int64>);
typedef _WebPPlaybackCursorGetFramesDart = int Function(
  Pointer<Void>, int, Pointer<Int64>);
typedef _WebPPlaybackCursorRestartNative = Int32 Function(Pointer<Void>);
typedef _WebPPlaybackCursorRestartDart = int Function(Pointer<Void>);
typedef _WebPPlaybackCursorRebindSourceNative = Int32 Function(Pointer<Void>);
typedef _WebPPlaybackCursorRebindSourceDart = int Function(Pointer<Void>);
typedef _WebPPlaybackCursorSetThreadLimitNative = Void Function(
  Pointer<Void>, Int32);
typedef _WebPPlaybackCursorSetThreadLimitDart = void Function(
  Pointer<Void>, int);
typedef _WebPPlaybackCursorDeleteNative = Void Function(Pointer<Void>);
typedef _WebPPlaybackCursorDeleteDart = void Function(Pointer<Void>);

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
  late final _WebPAnimStreamDecoderNewDart streamNew;
  late final _WebPAnimStreamDecoderAppendDart streamAppend;
  late final _WebPAnimStreamDecoderResetInputDart streamResetInput;
  late final _WebPAnimStreamDecoderRestartPlaybackDart streamRestartPlayback;
  late final _WebPAnimStreamDecoderGetInfoDart streamGetInfo;
  late final _WebPAnimStreamDecoderGetFramesDart streamGetFrames;
  late final _WebPAnimStreamDecoderSetThreadLimitDart streamSetThreadLimit;
  late final _WebPAnimStreamDecoderDeleteDart streamDelete;
  late final _WebPSourceNewDart sourceNew;
  late final _WebPSourceReserveDart sourceReserve;
  late final _WebPSourceCommitDart sourceCommit;
  late final _WebPSourceSealDart sourceSeal;
  late final _WebPSourceResetDart sourceReset;
  late final _WebPSourceGetStateDart sourceGetState;
  late final _WebPSourceGetFrameDart sourceGetFrame;
  late final _WebPSourceDeleteDart sourceDelete;
  late final _WebPPlaybackCursorNewDart cursorNew;
  late final _WebPPlaybackCursorGetStateDart cursorGetState;
  late final _WebPPlaybackCursorGetFramesDart cursorGetFrames;
  late final _WebPPlaybackCursorRestartDart cursorRestart;
  late final _WebPPlaybackCursorRebindSourceDart cursorRebindSource;
  late final _WebPPlaybackCursorSetThreadLimitDart cursorSetThreadLimit;
  late final _WebPPlaybackCursorDeleteDart cursorDelete;
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
    streamNew = _lib.lookupFunction<_WebPAnimStreamDecoderNewNative,
        _WebPAnimStreamDecoderNewDart>('webp_anim_stream_decoder_new');
    streamAppend = _lib.lookupFunction<_WebPAnimStreamDecoderAppendNative,
        _WebPAnimStreamDecoderAppendDart>('webp_anim_stream_decoder_append');
    streamResetInput = _lib.lookupFunction<_WebPAnimStreamDecoderResetInputNative,
        _WebPAnimStreamDecoderResetInputDart>('webp_anim_stream_decoder_reset_input');
    streamRestartPlayback = _lib.lookupFunction<_WebPAnimStreamDecoderRestartPlaybackNative,
        _WebPAnimStreamDecoderRestartPlaybackDart>('webp_anim_stream_decoder_restart_playback');
    streamGetInfo = _lib.lookupFunction<_WebPAnimStreamDecoderGetInfoNative,
        _WebPAnimStreamDecoderGetInfoDart>('webp_anim_stream_decoder_get_info');
    streamGetFrames = _lib.lookupFunction<_WebPAnimStreamDecoderGetFramesNative,
        _WebPAnimStreamDecoderGetFramesDart>('webp_anim_stream_decoder_get_frames');
    streamSetThreadLimit = _lib.lookupFunction<_WebPAnimStreamDecoderSetThreadLimitNative,
        _WebPAnimStreamDecoderSetThreadLimitDart>('webp_anim_stream_decoder_set_thread_limit');
    streamDelete = _lib.lookupFunction<_WebPAnimStreamDecoderDeleteNative,
        _WebPAnimStreamDecoderDeleteDart>('webp_anim_stream_decoder_delete');
    sourceNew = _lib.lookupFunction<_WebPSourceNewNative,
        _WebPSourceNewDart>('webp_source_new');
    sourceReserve = _lib.lookupFunction<_WebPSourceReserveNative,
        _WebPSourceReserveDart>('webp_source_reserve');
    sourceCommit = _lib.lookupFunction<_WebPSourceCommitNative,
        _WebPSourceCommitDart>('webp_source_commit');
    sourceSeal = _lib.lookupFunction<_WebPSourceSealNative,
        _WebPSourceSealDart>('webp_source_seal');
    sourceReset = _lib.lookupFunction<_WebPSourceResetNative,
        _WebPSourceResetDart>('webp_source_reset');
    sourceGetState = _lib.lookupFunction<_WebPSourceGetStateNative,
        _WebPSourceGetStateDart>('webp_source_get_state');
    sourceGetFrame = _lib.lookupFunction<_WebPSourceGetFrameNative,
        _WebPSourceGetFrameDart>('webp_source_get_frame');
    sourceDelete = _lib.lookupFunction<_WebPSourceDeleteNative,
        _WebPSourceDeleteDart>('webp_source_delete');
    cursorNew = _lib.lookupFunction<_WebPPlaybackCursorNewNative,
        _WebPPlaybackCursorNewDart>('webp_playback_cursor_new');
    cursorGetState = _lib.lookupFunction<_WebPPlaybackCursorGetStateNative,
        _WebPPlaybackCursorGetStateDart>('webp_playback_cursor_get_state');
    cursorGetFrames = _lib.lookupFunction<_WebPPlaybackCursorGetFramesNative,
        _WebPPlaybackCursorGetFramesDart>('webp_playback_cursor_get_frames');
    cursorRestart = _lib.lookupFunction<_WebPPlaybackCursorRestartNative,
        _WebPPlaybackCursorRestartDart>('webp_playback_cursor_restart');
    cursorRebindSource = _lib.lookupFunction<
        _WebPPlaybackCursorRebindSourceNative,
        _WebPPlaybackCursorRebindSourceDart>(
      'webp_playback_cursor_rebind_source',
    );
    cursorSetThreadLimit = _lib.lookupFunction<
        _WebPPlaybackCursorSetThreadLimitNative,
        _WebPPlaybackCursorSetThreadLimitDart>(
      'webp_playback_cursor_set_thread_limit',
    );
    cursorDelete = _lib.lookupFunction<_WebPPlaybackCursorDeleteNative,
        _WebPPlaybackCursorDeleteDart>('webp_playback_cursor_delete');
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
    final dartRgba = Uint8List.fromList(rgba);

    _bind.freeBuffer(result);

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
      TraceLog.error('WebP.Decoder', 'createAnimDecoder FAILED');
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

WebPAnimDecoder? createStreamingAnimDecoder({
  required int targetWidth,
  required int targetHeight,
}) {
  final ctx = _bind.streamNew(targetWidth, targetHeight);
  if (ctx == Pointer.fromAddress(0)) return null;
  return WebPAnimDecoder._stream(bindings: _bind, ctx: ctx);
}

NativeWebPSource createNativeWebPSource({
  int expectedLength = 0,
  int epoch = 1,
}) {
  final handle = _bind.sourceNew(expectedLength, epoch);
  if (handle == nullptr) throw StateError('Failed to create native WebP source');
  return NativeWebPSource._(handle, epoch);
}

class NativeWebPSource implements WebPByteSource {
  Pointer<Void> _handle;
  int _epoch;

  NativeWebPSource._(this._handle, this._epoch);

  int get address => _handle.address;
  @override
  int get epoch => _epoch;
  @override
  bool get isDisposed => _handle == nullptr;

  @override
  void append(Uint8List bytes, {required int offset}) {
    _checkActive();
    if (bytes.isEmpty) return;
    final target = _bind.sourceReserve(_handle, _epoch, offset, bytes.length);
    if (target == nullptr) throw _sourceError('reserve');
    target.asTypedList(bytes.length).setAll(0, bytes);
    final result = _bind.sourceCommit(_handle, _epoch, offset, bytes.length);
    if (result != 0) throw _sourceError('commit', result);
  }

  @override
  void seal() {
    _checkActive();
    final result = _bind.sourceSeal(_handle, _epoch);
    if (result != 0) throw _sourceError('seal', result);
  }

  @override
  void reset({int expectedLength = 0, required int epoch}) {
    _checkActive();
    final result = _bind.sourceReset(_handle, expectedLength, epoch);
    if (result != 0) throw _sourceError('reset', result);
    _epoch = epoch;
  }

  @override
  NativeWebPSourceState get state {
    _checkActive();
    final out = calloc<_NativeWebPSourceState>();
    try {
      final result = _bind.sourceGetState(_handle, out);
      if (result != 0) throw StateError('Native WebP source state failed: $result');
      final value = out.ref;
      return NativeWebPSourceState(
        epoch: value.epoch,
        expectedLength: value.expectedLength,
        committedLength: value.committedLength,
        declaredLength: value.declaredLength,
        parsedOffset: value.parsedOffset,
        sealed: value.sealed != 0,
        failed: value.failed != 0,
        lastError: value.lastError,
        canvasWidth: value.canvasWidth,
        canvasHeight: value.canvasHeight,
        loopCount: value.loopCount,
        frameCount: value.frameCount,
        animated: value.animated != 0,
      );
    } finally {
      calloc.free(out);
    }
  }

  @override
  NativeWebPFrameDescriptor frameAt(int index) {
    _checkActive();
    final out = calloc<_NativeWebPSourceFrame>();
    try {
      final result = _bind.sourceGetFrame(_handle, index, out);
      if (result != 0) throw StateError('Native WebP frame $index unavailable: $result');
      final value = out.ref;
      return NativeWebPFrameDescriptor(
        payloadOffset: value.payloadOffset,
        payloadLength: value.payloadLength,
        xOffset: value.xOffset,
        yOffset: value.yOffset,
        width: value.width,
        height: value.height,
        durationMs: value.durationMs,
        disposeMethod: value.disposeMethod,
        blendMethod: value.blendMethod,
        hasAlpha: value.hasAlpha != 0,
      );
    } finally {
      calloc.free(out);
    }
  }

  @override
  void dispose() {
    if (_handle == nullptr) return;
    _bind.sourceDelete(_handle);
    _handle = nullptr;
  }

  StateError _sourceError(String operation, [int? result]) {
    final current = state;
    return StateError(
      'Native WebP source $operation failed: '
      '${result ?? current.lastError} epoch=${current.epoch} '
      'committed=${current.committedLength}',
    );
  }

  void _checkActive() {
    if (_handle == nullptr) throw StateError('Native WebP source is disposed');
  }
}

class NativeWebPPlaybackCursorState {
  final int sourceEpoch;
  final int committedLength;
  final int canvasWidth;
  final int canvasHeight;
  final int targetWidth;
  final int targetHeight;
  final int availableFrames;
  final int nextFrame;
  final int loopCount;
  final bool ready;
  final bool sourceSealed;
  final bool atAvailableEnd;
  final bool complete;
  final bool failed;
  final int lastError;

  const NativeWebPPlaybackCursorState({
    required this.sourceEpoch,
    required this.committedLength,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.targetWidth,
    required this.targetHeight,
    required this.availableFrames,
    required this.nextFrame,
    required this.loopCount,
    required this.ready,
    required this.sourceSealed,
    required this.atAvailableEnd,
    required this.complete,
    required this.failed,
    required this.lastError,
  });
}

abstract interface class WebPFrameCursor {
  int get address;
  bool get isDisposed;
  NativeWebPPlaybackCursorState get state;
  List<WebPAnimFrameAddress> decodeFrames(int count);
  void restart();
  void rebindSource();
  void setThreadLimit(int useThreads);
  void dispose();
}

NativeWebPPlaybackCursor createNativeWebPPlaybackCursor(
  NativeWebPSource source, {
  required int targetWidth,
  required int targetHeight,
}) {
  source._checkActive();
  final handle = _bind.cursorNew(source._handle, targetWidth, targetHeight);
  if (handle == nullptr) {
    throw StateError('Failed to create native WebP playback cursor');
  }
  return NativeWebPPlaybackCursor._(handle);
}

final class NativeWebPPlaybackCursor implements WebPFrameCursor {
  Pointer<Void> _handle;

  NativeWebPPlaybackCursor._(this._handle);

  @override
  int get address => _handle.address;
  @override
  bool get isDisposed => _handle == nullptr;

  @override
  NativeWebPPlaybackCursorState get state {
    _checkActive();
    final out = calloc<_NativeWebPPlaybackCursorState>();
    try {
      final result = _bind.cursorGetState(_handle, out);
      final value = out.ref;
      if (result == -20) throw StateError('Native WebP cursor state failed: $result');
      return NativeWebPPlaybackCursorState(
        sourceEpoch: value.sourceEpoch,
        committedLength: value.committedLength,
        canvasWidth: value.canvasWidth,
        canvasHeight: value.canvasHeight,
        targetWidth: value.targetWidth,
        targetHeight: value.targetHeight,
        availableFrames: value.availableFrames,
        nextFrame: value.nextFrame,
        loopCount: value.loopCount,
        ready: value.ready != 0,
        sourceSealed: value.sourceSealed != 0,
        atAvailableEnd: value.atAvailableEnd != 0,
        complete: value.complete != 0,
        failed: value.failed != 0,
        lastError: value.lastError,
      );
    } finally {
      calloc.free(out);
    }
  }

  @override
  List<WebPAnimFrameAddress> decodeFrames(int count) {
    _checkActive();
    if (count <= 0) throw ArgumentError.value(count, 'count');
    final results = calloc<Int64>(count * 2);
    try {
      final decoded = _bind.cursorGetFrames(_handle, count, results);
      if (decoded < 0) {
        throw StateError('Native WebP cursor decode failed: $decoded');
      }
      return List.generate(
        decoded,
        (index) => WebPAnimFrameAddress(
          address: results[index * 2],
          durationMs: results[index * 2 + 1],
        ),
        growable: false,
      );
    } finally {
      calloc.free(results);
    }
  }

  @override
  void restart() {
    _checkActive();
    final result = _bind.cursorRestart(_handle);
    if (result != 0) throw StateError('Native WebP cursor restart failed: $result');
  }

  @override
  void rebindSource() {
    _checkActive();
    final result = _bind.cursorRebindSource(_handle);
    if (result != 0) {
      throw StateError('Native WebP cursor rebind failed: $result');
    }
  }

  @override
  void setThreadLimit(int useThreads) {
    _checkActive();
    _bind.cursorSetThreadLimit(_handle, useThreads);
  }

  @override
  void dispose() {
    if (_handle == nullptr) return;
    _bind.cursorDelete(_handle);
    _handle = nullptr;
  }

  void _checkActive() {
    if (_handle == nullptr) throw StateError('Native WebP cursor is disposed');
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
  final int decoderEpoch;
  final bool isStreaming;
  final bool usePlaybackCursor;
  final int framesToDecode;
  final int targetW;
  final int targetH;
  final void Function(List<WebPAnimFrameAddress> frames) onComplete;
  final void Function(Object error)? onError;
  final int dispatchedAt; // us, for queue wait time measurement

  DecodeJob({
    required this.generation,
    required this.decoderAddress,
    this.decoderEpoch = 0,
    this.isStreaming = false,
    this.usePlaybackCursor = false,
    required this.framesToDecode,
    required this.targetW,
    required this.targetH,
    required this.onComplete,
    this.onError,
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

  final List<SendPort?> _workerPorts = [null, null];
  final List<bool> _isInitializing = [false, false];
  final List<bool> _workerBusy = [false, false];
  final Set<int> _activeDecoders = {};
  final Map<int, int> _decoderEpochs = {};

  // 为 current 页保留一个 worker：非 current（next/bg）解码最多占用 worker 数-1 个
  // isolate，播放中的当前页续帧始终有一个 worker 可用，不被邻页预取批占满而饿死。
  int _nonCurrentBusy = 0;
  int _currentBusy = 0;
  int get _workerCount => _workerPorts.length;


  // Round-robin counter for decoder creation (avoids worker 0 bottleneck)
  int _nextDecoderWorker = 0; // ignore: unused_field

  int decoderEpoch(int decoderAddress) => _decoderEpochs[decoderAddress] ?? 0;

  bool invalidateDecoder(int decoderAddress) {
    _decoderEpochs[decoderAddress] = decoderEpoch(decoderAddress) + 1;
    final removed = <DecodeJob>[];
    bool remove(DecodeJob job) {
      if (job.decoderAddress != decoderAddress) return false;
      removed.add(job);
      return true;
    }
    _currentQueue.removeWhere(remove);
    _nextQueue.removeWhere(remove);
    _bgQueue.removeWhere(remove);
    for (final job in removed) {
      scheduleMicrotask(() => job.onComplete([]));
    }
    return _activeDecoders.contains(decoderAddress);
  }

  bool _isStale(DecodeJob job) =>
      job.decoderEpoch != decoderEpoch(job.decoderAddress);

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
      TraceLog.error(
        'WebP.Worker',
        'Failed to initialize worker $index',
        error: e,
      );
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
      TraceLog.error(
        'WebP.Worker',
        'w$workerIndex lib load FAILED',
        error: e,
      );
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
      final isStreaming = data.length > 6 && data[6] == true;
      final usePlaybackCursor = data.length > 7 && data[7] == true;

      try {
        if (decoderAddress == 0) {
          replyPort.send('Error: Null decoder');
          return;
        }

        final ctx = Pointer<Void>.fromAddress(decoderAddress);
        // 单次 FFI 调用批量解码 N 帧，消除 per-frame FFI 往返开销
        final cResults = calloc<Int64>(count * 2);
        var n = usePlaybackCursor
            ? bindings.cursorGetFrames(ctx, count, cResults)
            : isStreaming
                ? bindings.streamGetFrames(ctx, count, cResults)
                : bindings.animGetFrames(ctx, count, cResults);
        if (n <= 0 && !isStreaming && !usePlaybackCursor) {
          bindings.animReset(ctx);
          n = bindings.animGetFrames(ctx, count, cResults);
        }

        if (n > 0) {
          final results = Int64List.fromList(cResults.asTypedList(n * 2));
          calloc.free(cResults);
          replyPort.send(results);
        } else if (n == 0) {
          calloc.free(cResults);
          replyPort.send(Int64List(0));
        } else {
          calloc.free(cResults);
          replyPort.send('Error: Native decode failed: $n');
        }
      } catch (e, stack) {
        TraceLog.error(
          'WebP.Worker',
          'w$workerIndex crash',
          error: e,
          stackTrace: stack,
        );
        replyPort.send('Error: $e');
      }
    });
  }

  void dispatch(DecodeJob job, DecodePriority priority) {
    // [ANALYSIS-2] Reject stale jobs immediately — before they ever
    // enter the queue. Previously the generation check happened
    // AFTER the worker had already done the decode work.
    if (_isStale(job)) {
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
        TraceLog.error(
          'WebP.Worker',
          'scheduler error',
          error: e,
          stackTrace: stack,
        );
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

      var pickedIsCurrent = false;

      // 水位策略决定近页是否值得预解；worker 层只保证非 current 最多占一个槽。
      // 因此 current 正在一个 worker 解码时，另一个 worker 可与目标页预解重叠，
      // 但目标页永远不能占满池子、阻塞下一批 current 补帧。
      final allowNonCurrent = _nonCurrentBusy < _workerCount - 1;

      for (final w in [0, 1]) {
        if (_workerBusy[w]) continue;

        // Scan queues in priority order for a job matching worker w.
        // A WebPAnimDecoder is stateful; never run two jobs for the same
        // native decoder concurrently, even if another worker is idle.
        final queues = [
          (_currentQueue, true),
          (_nextQueue, false),
          (_bgQueue, false),
        ];

        for (final (queue, isCur) in queues) {
          if (queue.isEmpty) continue;
          if (!isCur && !allowNonCurrent) continue;
          // Find first job in this queue whose decoder hashes to worker w
          for (final j in queue) {
            if (_activeDecoders.contains(j.decoderAddress)) continue;
            if (j.decoderAddress % 2 == w) {
              job = j;
              assignedWorker = w;
              sourceQueue = queue;
              pickedIsCurrent = isCur;
              break;
            }
          }
          if (job != null) break;
        }

        // Fallback: if no job hashes to worker w, take any job
        if (job == null) {
          for (final (queue, isCur) in queues) {
            if (!isCur && !allowNonCurrent) continue;
            for (final j in queue) {
              if (_activeDecoders.contains(j.decoderAddress)) continue;
              job = j;
              assignedWorker = w;
              sourceQueue = queue;
              pickedIsCurrent = isCur;
              break;
            }
            if (job != null) break;
          }
        }

        if (job != null) break; // found work for this worker
      }

      if (job == null) break; // no work can be dispatched

      sourceQueue!.remove(job);
      _activeDecoders.add(job.decoderAddress);

      if (_isStale(job)) {
        _activeDecoders.remove(job.decoderAddress);
        job.onComplete([]);
        continue;
      }

      if (pickedIsCurrent) {
        _currentBusy++;
      } else {
        _nonCurrentBusy++;
      }
      _runJob(job, assignedWorker!, pickedIsCurrent);
    }
  }

  void _runJob(DecodeJob job, int workerIndex, bool isCurrent) async {
    final port = _workerPorts[workerIndex];
    if (port == null) {
      _activeDecoders.remove(job.decoderAddress);
      if (isCurrent && _currentBusy > 0) _currentBusy--;
      if (!isCurrent && _nonCurrentBusy > 0) _nonCurrentBusy--;
      job.onError?.call(StateError('WebP worker port is unavailable'));
      _scheduleNext();
      return;
    }

    _workerBusy[workerIndex] = true;
    final decodeSw = Stopwatch()..start();
    try {
      final replyPort = ReceivePort();
      port.send([replyPort.sendPort, job.decoderAddress, job.framesToDecode,
                 job.targetW, job.targetH, job.generation, job.isStreaming,
                 job.usePlaybackCursor]);

      final result = await replyPort.first;
      replyPort.close();
      // 诊断：单批解码往返耗时（含 isolate 通信）。除以 framesToDecode 得每帧解码
      // 时长，与帧显示间隔比较即可判定「解码是否追得上播放」。
      decodeSw.stop();
      ImagePipelinePerf.event(
        isCurrent ? 'decodeMs.cur' : 'decodeMs.near',
        micros: decodeSw.elapsedMicroseconds,
      );
      if (result is Int64List) {
        if (!_isStale(job)) {
          final List<WebPAnimFrameAddress> frames = [];
          for (int i = 0; i < result.length; i += 2) {
            frames.add(WebPAnimFrameAddress(
              address: result[i],
              durationMs: result[i + 1],
            ));
          }
          job.onComplete(frames);
        } else {
          for (int i = 0; i < result.length; i += 2) {
            nativePoolRelease(result[i]);
          }
          job.onComplete([]);
        }
      } else {
        TraceLog.error(
          'WebP.Worker',
          'w$workerIndex error: $result',
        );
        job.onError?.call(StateError(result.toString()));
      }
    } catch (e) {
      TraceLog.error(
        'WebP.Worker',
        'w$workerIndex exception',
        error: e,
      );
      job.onError?.call(e);
    } finally {
      _activeDecoders.remove(job.decoderAddress);
      _workerBusy[workerIndex] = false;
      if (isCurrent && _currentBusy > 0) _currentBusy--;
      if (!isCurrent && _nonCurrentBusy > 0) _nonCurrentBusy--;
      _scheduleNext();
    }
  }
}

class WebPAnimDecoder {
  final _WebPBindings _bindings;
  final Pointer<Void> _ctx;
  final Pointer<Uint8>? _nativeData;
  final bool isStreaming;
  bool _disposed = false;

  int canvasWidth;
  int canvasHeight;
  int targetWidth;
  int targetHeight;
  int frameCount;
  int loopCount;
  bool streamIsAnimated = true;
  bool streamIsComplete = false;

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
        _nativeData = nativeData,
        isStreaming = false;

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
        _nativeData = Pointer.fromAddress(nativeDataAddress),
        isStreaming = false;

  WebPAnimDecoder._stream({
    required _WebPBindings bindings,
    required Pointer<Void> ctx,
  })  : _bindings = bindings,
        _ctx = ctx,
        _nativeData = null,
        isStreaming = true,
        canvasWidth = 0,
        canvasHeight = 0,
        targetWidth = 0,
        targetHeight = 0,
        frameCount = 0,
        loopCount = 0;

  int get address => _ctx.address;
  bool get isDisposed => _disposed;

  bool get hasMoreFrames {
    _checkNotDisposed();
    if (isStreaming) return true;
    return _bindings.animHasMore(_ctx) != 0;
  }

  void setThreadLimit(int useThreads) {
    _checkNotDisposed();
    if (isStreaming) {
      _bindings.streamSetThreadLimit(_ctx, useThreads);
    } else {
      _bindings.animSetThreadLimit(_ctx, useThreads);
    }
  }

  bool appendStreamChunk(Uint8List data, {bool isFinal = false}) {
    _checkNotDisposed();
    if (!isStreaming) return false;
    final nativeData = data._asNative();
    try {
      _bindings.streamAppend(_ctx, nativeData, data.length, isFinal ? 1 : 0);
      return refreshStreamInfo();
    } finally {
      nativeData._free();
    }
  }

  void resetStreamInput() {
    _checkNotDisposed();
    if (isStreaming) _bindings.streamResetInput(_ctx);
  }

  void restartStreamPlayback() {
    _checkNotDisposed();
    if (isStreaming) _bindings.streamRestartPlayback(_ctx);
  }

  bool refreshStreamInfo() {
    _checkNotDisposed();
    if (!isStreaming) return true;
    final cW = calloc<Int32>(), cH = calloc<Int32>();
    final fC = calloc<Int32>(), lC = calloc<Int32>();
    final aW = calloc<Int32>(), aH = calloc<Int32>();
    final animated = calloc<Int32>();
    final ready = calloc<Int32>(), done = calloc<Int32>();
    try {
      _bindings.streamGetInfo(
        _ctx,
        cW,
        cH,
        fC,
        lC,
        aW,
        aH,
        animated,
        ready,
        done,
      );
      if (ready.value != 0) {
        canvasWidth = cW.value;
        canvasHeight = cH.value;
        frameCount = fC.value;
        loopCount = lC.value;
        targetWidth = aW.value;
        targetHeight = aH.value;
        streamIsAnimated = animated.value != 0;
        streamIsComplete = done.value != 0;
        return true;
      }
      return false;
    } finally {
      calloc.free(cW); calloc.free(cH); calloc.free(fC); calloc.free(lC);
      calloc.free(aW); calloc.free(aH); calloc.free(animated);
      calloc.free(ready); calloc.free(done);
    }
  }

  WebPAnimFrame? getNextFrame() {
    _checkNotDisposed();
    if (!hasMoreFrames) return null;
    if (isStreaming) {
      final results = calloc<Int64>(2);
      try {
        final n = _bindings.streamGetFrames(_ctx, 1, results);
        if (n <= 0) return null;
        final address = results[0];
        final duration = results[1];
        final rgbaPtr = Pointer<Uint8>.fromAddress(address);
        final rgba = rgbaPtr.asTypedList(targetWidth * targetHeight * 4);
        final copy = Uint8List.fromList(rgba);
        nativePoolRelease(address);
        return WebPAnimFrame(
          rgba: copy,
          durationMs: duration,
        );
      } finally {
        calloc.free(results);
      }
    }
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
    if (!isStreaming) _bindings.animReset(_ctx);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (isStreaming) {
      _bindings.streamDelete(_ctx);
    } else {
      _bindings.animDelete(_ctx);
    }
    _nativeData?._free();
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
