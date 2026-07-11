import 'dart:async';
import 'dart:collection';

import 'package:venera/foundation/image_provider/renderer/frame_renderer.dart';

final class WebPFrameDemand {
  final bool current;
  final bool decode;
  final bool upload;
  final bool retainRaw;

  /// 本页目标缓冲帧深（rank 水位表按 offset+阅读方向+当前页缓冲档位算出）。
  /// 0 表示不预解（仅下载/keep）。holder 缓冲 < 目标才继续解码。
  final int targetFrames;

  const WebPFrameDemand({
    required this.current,
    required this.decode,
    required this.upload,
    required this.retainRaw,
    this.targetFrames = 0,
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
  /// 无 demand 时的兜底目标（正常情况下 demand.targetFrames 覆盖它）。current
  /// 页至少要 1 帧才能出图；具体水位由 PipelineController 按 rank 表下发。
  static const int fallbackCurrentTarget = 1;

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

  /// Emits an atomic initial snapshot before live holder changes.
  Stream<WebPFrameHolderSnapshot> watch() {
    _checkActive();
    return Stream<WebPFrameHolderSnapshot>.multi((controller) {
      final subscription = _states.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.add(snapshot);
      controller.onCancel = subscription.cancel;
    });
  }

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
  int get targetFrameCount {
    // demand 带来的水位目标优先；缺省时给 current 页最低 1 帧兜底（保证能出首帧），
    // 非 current 页缺省 0（不预解）。
    if (_demand.targetFrames > 0) return _demand.targetFrames;
    return _demand.current ? fallbackCurrentTarget : 0;
  }
  bool get needsDecode =>
      !_disposed &&
      _demand.decode &&
      _decodeInFlight == 0 &&
      effectiveBufferedFrameCount < targetFrameCount;
  bool get needsUpload =>
      !_disposed && _demand.upload && _uploadInFlight == 0 && _raw.isNotEmpty;

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
        _demand.retainRaw == demand.retainRaw &&
        _demand.targetFrames == demand.targetFrames) {
      return;
    }
    final wasDecodable = _demand.decode || _demand.upload;
    _demand = demand;
    if (!demand.retainRaw) clearRawFrames();
    // Download-only/far demand retains the cursor and source, not expensive
    // uploaded frame resources. This is buffer trimming, not holder eviction.
    // 仅在「真正从可解码降级为不可解码」时清帧；targetFrames 变化(仍可解码)绝不清
    // 帧，否则近邻页目标深浅调节会反复丢弃已解帧 → 无谓重解。
    if (wasDecodable && !demand.decode && !demand.upload) clearRenderedFrames();
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
    _decodeInFlight = (_decodeInFlight - reservedFrames)
        .clamp(0, 1 << 30)
        .toInt();
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
