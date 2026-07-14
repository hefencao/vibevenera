import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:venera/utils/webp_perf.dart';
import 'package:venera/foundation/image_provider/io/image_data_validator.dart';
import 'package:venera/foundation/image_provider/renderer/frame_renderer.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/foundation/image_provider/session/webp_decode_session.dart';
import 'package:venera/network/webp_download_transport.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'resource_entry.dart';

// ───────────────────────────────────────────────────────────────
// 5. SchedulerTask — base with explicit lifecycle
// ───────────────────────────────────────────────────────────────

enum SchedulerLane { network, decode, upload }

abstract class SchedulerTask {
  final String key;
  final int generation;
  int priority;
  bool cancelable;
  SchedulerLane get lane;
  bool get retainWhenInactive => false;

  /// [FIX-7] Explicit lifecycle state.
  TaskState _state = TaskState.queued;
  TaskState get taskState => _state;

  SchedulerTask({
    required this.key,
    required this.generation,
    required this.priority,
    required this.cancelable,
  });

  void execute();

  void Function(SchedulerTask task)? _onCompleted;
  void Function(SchedulerTask task)? _onFailed;
  bool _terminalNotified = false;

  void setCompletionHandlers({
    required void Function(SchedulerTask task) onCompleted,
    required void Function(SchedulerTask task) onFailed,
  }) {
    _onCompleted = onCompleted;
    _onFailed = onFailed;
  }

  void notifyCompleted() {
    if (_terminalNotified) return;
    _terminalNotified = true;
    _onCompleted?.call(this);
  }

  void notifyFailed() {
    if (_terminalNotified) return;
    _terminalNotified = true;
    _onFailed?.call(this);
  }

  void cancel() {
    if (_state == TaskState.queued || _state == TaskState.running) {
      _state = TaskState.cancelled;
    }
  }

  bool get isCancelled => _state == TaskState.cancelled;
  bool get isFinished =>
      _state == TaskState.completed ||
      _state == TaskState.cancelled ||
      _state == TaskState.failed;

  /// Called by TaskScheduler when this task begins execution.
  void onDispatch() {
    if (_state == TaskState.queued) _state = TaskState.running;
  }
}

final class WebPDownloadTask extends SchedulerTask {
  final DownloadSession session;
  final WebPTransport transport;
  final void Function(WebPTransportProgress progress)? onProgress;
  final List<Completer<File>> _waiters = [];
  CancelToken? _cancelToken;
  bool _finished = false;

  WebPDownloadTask({
    required super.key,
    required super.generation,
    required super.priority,
    required super.cancelable,
    required this.session,
    required this.transport,
    this.onProgress,
  });

  @override
  SchedulerLane get lane => SchedulerLane.network;
  @override
  bool get retainWhenInactive => true;

  Future<File> register() {
    final waiter = Completer<File>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void mergeWaitersFrom(WebPDownloadTask incoming) =>
      _waiters.addAll(incoming._waiters);

  @override
  void onDispatch() {
    super.onDispatch();
    session.markQueued();
  }

  @override
  void execute() {
    unawaited(_run());
  }

  Future<void> _run() async {
    if (isCancelled) {
      _finished = true;
      notifyCompleted();
      return;
    }

    DownloadWriterLease? writer;
    try {
      _cancelToken = CancelToken();
      final activeWriter = session.beginTransport();
      writer = activeWriter;
      final file = await transport.execute(
        session,
        cancelToken: _cancelToken,
        onProgress: onProgress,
      );

      // New transports seal atomically before returning. Legacy/custom
      // transports may only return the completed file; finish the same active
      // writer here so their old execute signature remains valid.
      if (activeWriter.active) {
        session.seal(activeWriter, file);
      }

      // A late cancellation must not turn a completed download into a failure.
      _state = TaskState.completed;
      _finished = true;
      for (final waiter in _waiters) {
        if (!waiter.isCompleted) waiter.complete(file);
      }
      _waiters.clear();
      notifyCompleted();
    } catch (error, stack) {
      final cancelled = isCancelled || error is WebPTransportCancelled;
      if (cancelled) {
        if (writer?.active == true) session.pause(writer!);
        _rejectWaiters(error, stack);
        _finished = true;
        notifyCompleted();
      } else {
        if (writer?.active == true) {
          session.fail(
            writer!,
            error,
            retryable: _isRetryableWebPDownloadError(error),
          );
        }
        _state = TaskState.failed;
        _finished = true;
        _rejectWaiters(error, stack);
        notifyFailed();
      }
    } finally {
      _cancelToken = null;
    }
  }

  @override
  void cancel() {
    if (_finished || isCancelled) return;
    _cancelToken?.cancel('WebP transport paused');
    super.cancel();
    _rejectWaiters(const WebPTransportCancelled('cancelled'));
    // Do not mark the session paused here. The task remains registered as a
    // running task until transport.execute has unwound and flushed its artifact.
  }

  bool _isRetryableWebPDownloadError(Object error) {
    if (error is WebPSourceInvariantError) return false;
    if (error is InvalidImageDataException) {
      // The transport discards the corrupt artifact and advances the source
      // epoch before rethrowing. Allow one clean redownload, then surface a
      // terminal error instead of looping on a server text/error response.
      return session.failureCount == 0;
    }
    int? statusCode;
    try {
      final dynamic dynamicError = error;
      final dynamic value = dynamicError.response?.statusCode;
      if (value is int) statusCode = value;
    } catch (_) {
      // The downloader may throw a non-Dio exception.
    }
    if (statusCode != null && statusCode >= 400 && statusCode < 500) {
      return statusCode == 408 ||
          statusCode == 409 ||
          statusCode == 425 ||
          statusCode == 429;
    }
    final message = error.toString();
    if (message.contains('Invalid Status Code: 403') ||
        message.contains('Invalid Status Code: 404')) {
      return false;
    }
    return true;
  }

  void _rejectWaiters(Object error, [StackTrace? stack]) {
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.completeError(error, stack);
    }
    _waiters.clear();
  }
}

final class WebPDecodeTask extends SchedulerTask {
  final WebPDecodeSession session;
  final bool current;
  final int maxBatch;
  final webp.WorkerPoolScheduler _pool = webp.WorkerPoolScheduler.instance;

  WebPDecodeTask({
    required super.key,
    required super.generation,
    required super.priority,
    required this.session,
    this.maxBatch = 2,
  }) : current = session.isCurrent,
       super(cancelable: true);

  @override
  SchedulerLane get lane => SchedulerLane.decode;

  @override
  void execute() {
    if (isCancelled) {
      notifyCompleted();
      return;
    }
    final claim = session.tryClaimDecode(
      expectedRevision: generation,
      maxBatch: current ? maxBatch : 1,
    );
    if (claim == null) {
      _state = TaskState.completed;
      notifyCompleted();
      session.requestReconcile();
      return;
    }

    final cursor = session.cursor;
    // 全画布 VP8 熵解码严格串行，libwebp 多线程只并行少量重建，实测在此 workload
    // 上多线程抖动更差（4线程 40-120ms vs 单线程稳定 50ms）。恒单线程，性能靠
    // native 侧解码线程绑大核（webp_decoder.c bind_current_thread_to_big_cores）。
    cursor.setThreadLimit(1);
    WebPPerf.count(current ? 'decodeDispatch.current' : 'decodeDispatch.near');
    // 诊断：dispatch 时的需求构成，定位「播放页为何 isCurrent=false」。
    WebPPerf.count(
      'dispatchDemand.dc${session.demandCount}.cur${session.isCurrent ? 1 : 0}',
    );
    _pool.dispatch(
      webp.DecodeJob(
        generation: generation,
        decoderAddress: cursor.address,
        decoderEpoch: _pool.decoderEpoch(cursor.address),
        usePlaybackCursor: true,
        framesToDecode: claim.reservedFrames,
        targetW: session.identity.targetWidth,
        targetH: session.identity.targetHeight,
        onComplete: (decoded) => _complete(claim, decoded),
        onError: (error) => _fail(claim, error),
      ),
      current
          ? webp.DecodePriority.current
          : webp.DecodePriority.next,
    );
  }

  @override
  void cancel() {
    if (isFinished) return;
    super.cancel();
    _pool.invalidateDecoder(session.cursor.address);
  }

  void _complete(
    WebPDecodeClaim claim,
    List<webp.WebPAnimFrameAddress> decoded,
  ) {
    List<NativeFrameHandle> frames = const [];
    try {
      frames = WebPPerf.sync(
        'importDecodedFrames',
        () => session.importDecodedFrames(claim, decoded),
      );
      session.completeDecode(claim, frames, discard: isCancelled);
      _state = isCancelled ? TaskState.cancelled : TaskState.completed;
      notifyCompleted();
    } catch (error) {
      session.completeDecode(claim, frames, error: error, discard: isCancelled);
      if (isCancelled) {
        notifyCompleted();
      } else {
        _state = TaskState.failed;
        notifyFailed();
      }
    }
  }

  void _fail(WebPDecodeClaim claim, Object error) {
    session.completeDecode(claim, const [], error: error, discard: isCancelled);
    if (isCancelled) {
      notifyCompleted();
    } else {
      _state = TaskState.failed;
      notifyFailed();
    }
  }
}

final class WebPFrameUploadTask extends SchedulerTask {
  final WebPDecodeSession session;
  final FrameRenderer renderer;

  WebPFrameUploadTask({
    required super.key,
    required super.generation,
    required super.priority,
    required this.session,
    required this.renderer,
  }) : super(cancelable: true);

  @override
  SchedulerLane get lane => SchedulerLane.upload;

  @override
  void execute() {
    if (isCancelled) {
      notifyCompleted();
      return;
    }

    WebPUploadClaim? claim;
    try {
      claim = session.tryClaimUpload(expectedRevision: generation);
    } catch (_) {
      _state = TaskState.failed;
      notifyFailed();
      return;
    }
    if (claim == null) {
      _state = TaskState.completed;
      notifyCompleted();
      session.requestReconcile();
      return;
    }
    unawaited(_render(claim));
  }

  Future<void> _render(WebPUploadClaim claim) async {
    RenderedFrameHandle? rendered;
    try {
      rendered = await renderer.render(claim.frame);
      // The renderer contract owns the input handle, but release is idempotent
      // and closes leaks from third-party renderer implementations that forget
      // to release after a successful upload.
      claim.frame.release();
      session.completeUpload(claim, rendered, discard: isCancelled);
      _state = isCancelled ? TaskState.cancelled : TaskState.completed;
      notifyCompleted();
    } catch (error) {
      // Renderer owns the native frame after render() is called, but release is
      // idempotent and protects custom renderer implementations on failure.
      claim.frame.release();
      session.completeUpload(
        claim,
        rendered,
        error: error,
        discard: isCancelled,
      );
      if (isCancelled) {
        notifyCompleted();
      } else {
        _state = TaskState.failed;
        notifyFailed();
      }
    }
  }
}
