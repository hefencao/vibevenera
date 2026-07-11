import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:venera/utils/webp_decoder.dart' as webp;
import 'package:venera/utils/webp_perf.dart';

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
}

abstract interface class RenderedFrameHandle {
  int get durationMs;
  void dispose();
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
          WebPPerf.event(
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
