import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:venera/utils/webp_decoder.dart' as webp;
import 'package:venera/utils/image_pipeline_perf.dart';

/// Owns one native RGBA frame returned by the WebP playback cursor.
///
/// Ownership rules:
/// - before [FrameRenderer.render] is called, the caller owns the frame;
/// - after [FrameRenderer.render] is called, the renderer owns the frame;
/// - renderer implementations must release it exactly once on success or error.
final class NativeFrameHandle {
  final int address;
  final int width;
  final int height;
  final int durationMs;
  bool _released = false;

  NativeFrameHandle({
    required this.address,
    required this.width,
    required this.height,
    required this.durationMs,
  });

  bool get released => _released;

  void release() {
    if (_released) return;
    _released = true;
    webp.nativePoolRelease(address);
  }

  /// 伪 release：把 native 缓冲区的所有权移交给调用方，返回其地址，并让本 handle
  /// 的 [release] 从此变为 no-op（不调用 nativePoolRelease）。
  ///
  /// 用于 native texture 渲染：上传任务在 `renderer.render()` 返回后会立即
  /// `frame.release()`，但纹理路径需要 native 帧存活到「按播放节奏上传纹理」时。
  /// 通过本方法把地址转进 [NativeAddressFrameHandle] 持有，其 dispose 时才真正
  /// 释放，保证所有权始终单一、无 double-free。
  int detachAddress() {
    if (_released) {
      throw StateError('NativeFrameHandle already released/detached');
    }
    _released = true;
    return address;
  }
}

abstract interface class RenderedFrameHandle {
  int get durationMs;
  void dispose();
}

/// [RenderedFrameHandle] 变体：持有一块存活的 native RGBA 帧（Premul RGBA8888），
/// 不产生 ui.Image。用于 native texture 通路——显示层按播放节奏把 [address]
/// 上传到平台纹理后调用 [dispose] 归还缓冲池。
final class NativeAddressFrameHandle implements RenderedFrameHandle {
  final int width;
  final int height;
  @override
  final int durationMs;

  int _address;
  bool _disposed = false;

  NativeAddressFrameHandle({
    required int address,
    required this.width,
    required this.height,
    required this.durationMs,
  }) : _address = address;

  /// 存活的 native RGBA 缓冲区地址；已 dispose 后抛错。
  int get address {
    if (_disposed) throw StateError('NativeAddressFrameHandle disposed');
    return _address;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    webp.nativePoolRelease(_address);
    _address = 0;
  }
}

abstract interface class FrameRenderer {
  Future<RenderedFrameHandle> render(NativeFrameHandle frame);
}

final class FlutterImageFrameHandle implements RenderedFrameHandle {
  ui.Image? _image;

  @override
  final int durationMs;

  FlutterImageFrameHandle(ui.Image image, this.durationMs) : _image = image;

  ui.Image get image {
    final value = _image;
    if (value == null) throw StateError('Rendered frame image was detached');
    return value;
  }

  /// Transfers the ui.Image to ImageInfo. The returned ImageInfo then owns it.
  ui.Image detachImage() {
    final value = image;
    _image = null;
    return value;
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
  }
}

final class FlutterImageRenderer implements FrameRenderer {
  const FlutterImageRenderer();

  @override
  Future<RenderedFrameHandle> render(NativeFrameHandle frame) {
    final completer = Completer<RenderedFrameHandle>();
    final uploadSw = Stopwatch()..start();
    try {
      final rgba = Pointer<Uint8>.fromAddress(
        frame.address,
      ).asTypedList(frame.width * frame.height * 4);
      ui.decodeImageFromPixels(
        rgba,
        frame.width,
        frame.height,
        ui.PixelFormat.rgba8888,
        (image) {
          uploadSw.stop();
          ImagePipelinePerf.event(
            'gpuUpload(${frame.width}x${frame.height})',
            micros: uploadSw.elapsedMicroseconds,
          );
          frame.release();
          if (completer.isCompleted) {
            image.dispose();
            return;
          }
          completer.complete(FlutterImageFrameHandle(image, frame.durationMs));
        },
      );
    } catch (error, stack) {
      frame.release();
      if (!completer.isCompleted) completer.completeError(error, stack);
    }
    return completer.future;
  }
}

/// Platform-facing backend used by [NativeTextureRenderer].
///
/// Android/iOS implementations may upload or bind the native RGBA handle to a
/// texture without changing DownloadSession, WebPDecodeSession, or holder APIs.
/// The backend takes ownership of [frame] when [submit] is called and must
/// release it exactly once on both success and failure.
abstract interface class NativeTextureFrameBackend {
  Future<RenderedFrameHandle> submit(NativeFrameHandle frame);
}

/// Renderer adapter for a native texture backend.
///
/// The concrete platform backend is intentionally injected so the stable Dart
/// source/session boundary does not import a particular MethodChannel, FFI, or
/// texture plugin implementation.
final class NativeTextureRenderer implements FrameRenderer {
  final NativeTextureFrameBackend backend;

  const NativeTextureRenderer(this.backend);

  @override
  Future<RenderedFrameHandle> render(NativeFrameHandle frame) =>
      backend.submit(frame);
}
