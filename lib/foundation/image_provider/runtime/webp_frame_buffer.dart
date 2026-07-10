part of '../webp_image.dart';

class WebPFrameBuffer {
  final Queue<BufferedFrame> _frames = Queue();
  final Queue<webp.WebPAnimFrameAddress> _rawFrames = Queue();

  int get bufferLength => _frames.length;
  int get rawLength => _rawFrames.length;
  int get queuedFrameCount => _frames.length + _rawFrames.length;
  bool get hasUploadedFrames => _frames.isNotEmpty;
  bool get hasRawFrames => _rawFrames.isNotEmpty;

  BufferedFrame removeUploadedFrame() => _frames.removeFirst();
  webp.WebPAnimFrameAddress removeRawFrame() => _rawFrames.removeFirst();

  void addUploadedFrame(BufferedFrame frame) => _frames.add(frame);
  void addRawFrames(List<webp.WebPAnimFrameAddress> frames) =>
      _rawFrames.addAll(frames);

  static void releaseRawFrames(Iterable<webp.WebPAnimFrameAddress> frames) {
    for (final f in frames) {
      webp.nativePoolRelease(f.address);
    }
  }

  void clearRawFrames() {
    while (_rawFrames.isNotEmpty) {
      webp.nativePoolRelease(_rawFrames.removeFirst().address);
    }
  }

  void clearUploadedFrames() {
    for (final f in _frames) {
      f.image.dispose();
    }
    _frames.clear();
  }

  void clear() {
    clearUploadedFrames();
    clearRawFrames();
  }
}
