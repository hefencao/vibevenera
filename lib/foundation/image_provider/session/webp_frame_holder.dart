import 'dart:async';
import 'dart:collection';

import 'package:venera/foundation/image_provider/renderer/frame_renderer.dart';

final class WebPFrameDemand {
  final bool current;
  final bool decode;
  final bool upload;

  const WebPFrameDemand({
    required this.current,
    required this.decode,
    required this.upload,
  });
}

final class WebPFrameHolderSnapshot {
  final WebPFrameDemand demand;
  final int rawFrames;
  final int renderedFrames;
  final bool disposed;

  const WebPFrameHolderSnapshot({
    required this.demand,
    required this.rawFrames,
    required this.renderedFrames,
    required this.disposed,
  });
}

final class WebPFrameHolder {
  static const int currentTarget = 7;
  static const int nearTarget = 5;

  final Queue<NativeFrameHandle> _raw = Queue();
  final Queue<RenderedFrameHandle> _rendered = Queue();
  final StreamController<WebPFrameHolderSnapshot> _states =
      StreamController.broadcast(sync: true);
  final void Function() onDemand;
  WebPFrameDemand _demand = const WebPFrameDemand(
    current: false,
    decode: false,
    upload: false,
  );
  bool _disposed = false;

  WebPFrameHolder({required this.onDemand});

  Stream<WebPFrameHolderSnapshot> get states => _states.stream;
  WebPFrameDemand get demand => _demand;
  int get rawFrameCount => _raw.length;
  int get renderedFrameCount => _rendered.length;
  int get queuedFrameCount => _raw.length + _rendered.length;
  bool get hasRawFrames => _raw.isNotEmpty;
  bool get hasRenderedFrames => _rendered.isNotEmpty;
  bool get isDisposed => _disposed;
  int get targetFrameCount => _demand.current ? currentTarget : nearTarget;
  bool get needsDecode =>
      !_disposed && _demand.decode && queuedFrameCount < targetFrameCount;
  bool get needsUpload =>
      !_disposed && _demand.upload && _raw.isNotEmpty;

  WebPFrameHolderSnapshot get snapshot => WebPFrameHolderSnapshot(
    demand: _demand,
    rawFrames: _raw.length,
    renderedFrames: _rendered.length,
    disposed: _disposed,
  );

  void updateDemand(WebPFrameDemand demand) {
    _checkActive();
    if (_demand.current == demand.current &&
        _demand.decode == demand.decode &&
        _demand.upload == demand.upload) {
      return;
    }
    _demand = demand;
    if (!demand.upload) clearRawFrames();
    _changed();
  }

  void addRawFrames(Iterable<NativeFrameHandle> frames) {
    _checkActive();
    _raw.addAll(frames);
    _changed();
  }

  NativeFrameHandle takeRawFrame() {
    _checkActive();
    final frame = _raw.removeFirst();
    _changed();
    return frame;
  }

  void addRenderedFrame(RenderedFrameHandle frame) {
    _checkActive();
    _rendered.add(frame);
    _changed();
  }

  RenderedFrameHandle? consumeFrame() {
    _checkActive();
    if (_rendered.isEmpty) {
      onDemand();
      return null;
    }
    final frame = _rendered.removeFirst();
    _changed();
    return frame;
  }

  void clearRawFrames() {
    while (_raw.isNotEmpty) {
      _raw.removeFirst().release();
    }
  }

  void clearRenderedFrames() {
    while (_rendered.isNotEmpty) {
      _rendered.removeFirst().dispose();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clearRawFrames();
    clearRenderedFrames();
    _states.add(snapshot);
    _states.close();
  }

  void _changed() {
    _states.add(snapshot);
    onDemand();
  }

  void _checkActive() {
    if (_disposed) throw StateError('WebP frame holder is disposed');
  }
}
