import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:venera/utils/webp_decoder.dart' as webp;

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
  final ui.Image image;
  @override
  final int durationMs;

  FlutterImageFrameHandle(this.image, this.durationMs);

  @override
  void dispose() => image.dispose();
}

final class FlutterImageRenderer implements FrameRenderer {
  const FlutterImageRenderer();

  @override
  Future<RenderedFrameHandle> render(NativeFrameHandle frame) {
    final rgba = Pointer<Uint8>.fromAddress(
      frame.address,
    ).asTypedList(frame.width * frame.height * 4);
    final completer = Completer<RenderedFrameHandle>();
    ui.decodeImageFromPixels(
      rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        frame.release();
        completer.complete(FlutterImageFrameHandle(image, frame.durationMs));
      },
    );
    return completer.future;
  }
}
