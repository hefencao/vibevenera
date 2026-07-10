import 'dart:async';
import 'dart:collection';

import 'package:venera/foundation/image_provider/renderer/frame_renderer.dart';

final class WebPFrameDemand {
  final bool current;
  final bool decode;
  final bool upload;
  final bool retainRaw;

  const WebPFrameDemand({
    required this.current,
    required this.decode,
    required this.upload,
    required this.retainRaw,
  });
}

final class WebPFrameHolderSnapshot {
  final WebPFrameDemand demand;
  final int rawFrames;
  final int renderedFrames;
  final int decodeInFlight;
  final int uploadInFlight;
  final bool disposed;

  const WebPFrameHolderSnapshot({
    required this.demand,
    required this.rawFrames,
    required this.renderedFrames,
    required this.decodeInFlight,
    required this.uploadInFlight,
    required this.disposed,
  });
}

/// Rendering-side state only. It deliberately knows nothing about transport,
/// source reset, resume, stream ownership, or cache persistence.
final class WebPFrameHolder {
  static const int currentTarget = 7;
  static const int nearTarget = 5;

  final Queue<NativeFrameHandle> _raw = Queue();
  final Queue<RenderedFrameHandle> _rendered = Queue();
  final StreamController<WebPFrameHolderSnapshot> _states =
      StreamController.broadcast();
  final void Function() onDemand;

  WebPFrameDemand _demand = const WebPFrameDemand(
    current: false,
    decode: false,
    upload: false,
    retainRaw: false,
  );
  bool _disposed = false;
  bool _statePublishScheduled = false;
  bool _demandCallbackScheduled = false;
  int _decodeInFlight = 0;
  int _uploadInFlight = 0;

  WebPFrameHolder({required this.onDemand});

  Stream<WebPFrameHolderSnapshot> get states => _states.stream;
  WebPFrameDemand get demand => _demand;
  int get rawFrameCount => _raw.length;
  int get renderedFrameCount => _rendered.length;
  int get decodeInFlight => _decodeInFlight;
  int get uploadInFlight => _uploadInFlight;
  int get queuedFrameCount => _raw.length + _rendered.length;
  int get effectiveBufferedFrameCount =>
      queuedFrameCount + _decodeInFlight + _uploadInFlight;
  bool get hasRawFrames => _raw.isNotEmpty;
  bool get hasRenderedFrames => _rendered.isNotEmpty;
  bool get isDisposed => _disposed;
  int get targetFrameCount => _demand.current ? currentTarget : nearTarget;
  bool get needsDecode =>
      !_disposed &&
      _demand.decode &&
      _decodeInFlight == 0 &&
      effectiveBufferedFrameCount < targetFrameCount;
  bool get needsUpload =>
      !_disposed &&
      _demand.upload &&
      _uploadInFlight == 0 &&
      _raw.isNotEmpty;

  WebPFrameHolderSnapshot get snapshot => WebPFrameHolderSnapshot(
        demand: _demand,
        rawFrames: _raw.length,
        renderedFrames: _rendered.length,
        decodeInFlight: _decodeInFlight,
        uploadInFlight: _uploadInFlight,
        disposed: _disposed,
      );

  void updateDemand(WebPFrameDemand demand) {
    _checkActive();
    if (_demand.current == demand.current &&
        _demand.decode == demand.decode &&
        _demand.upload == demand.upload &&
        _demand.retainRaw == demand.retainRaw) {
      return;
    }
    _demand = demand;
    if (!demand.retainRaw) clearRawFrames();
    _changed();
  }

  int claimDecodeBudget({int maxBatch = 2}) {
    _checkActive();
    if (!needsDecode) return 0;
    final missing = targetFrameCount - effectiveBufferedFrameCount;
    final count = missing.clamp(1, maxBatch).toInt();
    _decodeInFlight += count;
    _changed(requestDemand: false);
    return count;
  }

  void finishDecodeClaim(
    int reservedFrames,
    Iterable<NativeFrameHandle> frames,
  ) {
    if (_disposed) {
      for (final frame in frames) {
        frame.release();
      }
      return;
    }
    _decodeInFlight = (_decodeInFlight - reservedFrames).clamp(0, 1 << 30).toInt();
    _raw.addAll(frames);
    _changed();
  }

  NativeFrameHandle? claimRawFrame() {
    _checkActive();
    if (!needsUpload) return null;
    final frame = _raw.removeFirst();
    _uploadInFlight++;
    _changed(requestDemand: false);
    return frame;
  }

  void finishUploadClaim(RenderedFrameHandle? frame) {
    if (_disposed) {
      frame?.dispose();
      return;
    }
    _uploadInFlight = (_uploadInFlight - 1).clamp(0, 1 << 30).toInt();
    if (frame != null) _rendered.add(frame);
    _changed();
  }

  RenderedFrameHandle? consumeFrame() {
    _checkActive();
    if (_rendered.isEmpty) {
      _scheduleDemandCallback();
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

  void clearBufferedFrames() {
    clearRawFrames();
    clearRenderedFrames();
    _changed();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clearRawFrames();
    clearRenderedFrames();
    if (!_states.isClosed) {
      _states.add(snapshot);
      _states.close();
    }
  }

  void _changed({bool requestDemand = true}) {
    _scheduleStatePublish();
    if (requestDemand) _scheduleDemandCallback();
  }

  void _scheduleStatePublish() {
    if (_statePublishScheduled || _states.isClosed) return;
    _statePublishScheduled = true;
    scheduleMicrotask(() {
      _statePublishScheduled = false;
      if (!_states.isClosed) _states.add(snapshot);
    });
  }

  void _scheduleDemandCallback() {
    if (_demandCallbackScheduled || _disposed) return;
    _demandCallbackScheduled = true;
    scheduleMicrotask(() {
      _demandCallbackScheduled = false;
      if (!_disposed) onDemand();
    });
  }

  void _checkActive() {
    if (_disposed) throw StateError('WebP frame holder is disposed');
  }
}
