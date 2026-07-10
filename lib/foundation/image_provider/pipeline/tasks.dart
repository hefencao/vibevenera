import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/image_provider/cache/decoded_image_cache.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/image_provider/io/image_loader.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/network/images.dart';
import 'package:venera/network/webp_download_transport.dart';

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

  void setCompletionHandlers({
    required void Function(SchedulerTask task) onCompleted,
    required void Function(SchedulerTask task) onFailed,
  }) {
    _onCompleted = onCompleted;
    _onFailed = onFailed;
  }

  void notifyCompleted() => _onCompleted?.call(this);
  void notifyFailed() => _onFailed?.call(this);

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

// ───────────────────────────────────────────────────────────────
// 6. PolicyAwareTask — shared policy-check + lifecycle logic
// ───────────────────────────────────────────────────────────────

/// [FIX-7] Common base for DownloadTask and PrecreateTask.
/// Provides: execution context, finished guard, resource cleanup,
/// policy validation. Subclasses implement [doExecute].
abstract class PolicyAwareTask extends SchedulerTask {
  ExecutionContext? _ctx;

  /// Guard against double-completion.
  bool _finished = false;

  PolicyAwareTask({
    required super.key,
    required super.generation,
    required super.priority,
    required super.cancelable,
  });

  /// Subclasses implement their specific work here.
  /// The context is already validated before this is called.
  Future<void> doExecute(ExecutionContext ctx);

  /// Override to release resources after completion/failure.
  void disposeResources() {}

  /// Check if the execution permission is still valid.
  bool permissionValid(ExecutionContext ctx);

  @override
  void execute() async {
    if (isCancelled) return;

    final ctx = _ctx;
    if (ctx == null || !permissionValid(ctx)) {
      cancel();
      notifyCompleted();
      return;
    }

    try {
      await doExecute(ctx);
      if (!isCancelled && !_finished) {
        _finish(true);
        notifyCompleted();
      }
    } catch (e) {
      if (!isCancelled && !_finished) {
        _finish(false);
        notifyFailed();
        return;
      }
    }
  }

  void _finish(bool success) {
    if (_finished) return;
    _finished = true;
    _state = success ? TaskState.completed : TaskState.failed;
    disposeResources();
    _ctx = null;
  }

  @override
  void cancel() {
    if (isFinished) return;
    _state = TaskState.cancelled;
    disposeResources();
    _ctx = null;
  }

  /// Set the execution context before dispatching.
  void setContext(ExecutionContext ctx) => _ctx = ctx;
}

// ───────────────────────────────────────────────────────────────
// 7. DownloadExecution — pure network/cache I/O
// ───────────────────────────────────────────────────────────────

/// [FIX-5] Extracted from DownloadTask. Pure I/O: knows nothing
/// about Scheduler, Policy, or ResourceEntry. Testable in isolation.
class DownloadExecution {
  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;

  DownloadExecution({
    required this.imageKey,
    this.sourceKey,
    required this.cid,
    required this.eid,
  });

  /// Execute the download with optional cancellation and progress.
  /// Returns the raw bytes.
  Future<Uint8List> execute({
    CancelToken? cancelToken,
    void Function(int current, int? total)? onProgress,
    void Function(ImageDownloadProgress event)? onEvent,
  }) async {
    if (cancelToken?.isCancelled == true) throw Exception('Cancelled');

    final chunkEvents = StreamController<ImageChunkEvent>();
    final chunkSub = chunkEvents.stream.listen((event) {
      onProgress?.call(
        event.cumulativeBytesLoaded,
        event.expectedTotalBytes == 0 ? null : event.expectedTotalBytes,
      );
    });

    final fetch = fetchImageBytes(
      imageKey,
      sourceKey,
      cid,
      eid,
      chunkEvents: chunkEvents,
      debugLabel: 'pipeline-download:$imageKey',
      onEvent: onEvent,
      cancelToken: cancelToken,
    );

    try {
      if (cancelToken == null) return await fetch;
      return await Future.any([
        fetch,
        cancelToken.whenCancel.then<Uint8List>((_) {
          throw Exception('Cancelled');
        }),
      ]);
    } finally {
      await chunkSub.cancel();
      await chunkEvents.close();
    }
  }
}

// ───────────────────────────────────────────────────────────────
// 8. DownloadTask — scheduler-facing wrapper
// ───────────────────────────────────────────────────────────────

/// [FIX-4] Thin wrapper: policy check + lifecycle management.
/// The actual I/O is delegated to [DownloadExecution].
class DownloadTask extends PolicyAwareTask {
  final DownloadExecution _exec;
  final String? fullKey;

  final List<Completer<Uint8List>> _completers = [];
  final List<StreamController<ImageChunkEvent>> _chunkControllers = [];
  final List<void Function(int current, int? total)> _progressCallbacks = [];
  final List<void Function(ImageDownloadProgress event)> _eventCallbacks = [];
  final List<void Function()> _disposeCallbacks = [];
  bool _waitersCompleted = false;
  CancelToken? _cancelToken;

  @override
  SchedulerLane get lane => SchedulerLane.network;
  @override
  bool get retainWhenInactive => true;

  DownloadTask({
    required super.key,
    required super.generation,
    required super.priority,
    required super.cancelable,
    required String imageKey,
    String? sourceKey,
    required String cid,
    required String eid,
    this.fullKey,
    void Function(int current, int? total)? onProgress,
    void Function(ImageDownloadProgress event)? onEvent,
    void Function()? onDispose,
  }) : _exec = DownloadExecution(
         imageKey: imageKey,
         sourceKey: sourceKey,
         cid: cid,
         eid: eid,
       ) {
    if (onProgress != null) _progressCallbacks.add(onProgress);
    if (onEvent != null) _eventCallbacks.add(onEvent);
    if (onDispose != null) _disposeCallbacks.add(onDispose);
  }

  // ── Public API ──────────────────────────────────────────────

  Future<Uint8List> register() {
    if (_finished) {
      // If task already finished, resolve immediately from state.
      // (bytes are held by ResourceEntry, not here)
      final c = Completer<Uint8List>();
      scheduleMicrotask(() {
        if (!c.isCompleted) c.completeError('Task already finished');
      });
      return c.future;
    }
    final c = Completer<Uint8List>();
    _completers.add(c);
    return c.future;
  }

  void registerChunkEvents(StreamController<ImageChunkEvent> sc) {
    _chunkControllers.add(sc);
  }

  void mergeWaitersFrom(DownloadTask incoming) {
    _completers.addAll(incoming._completers);
    _chunkControllers.addAll(incoming._chunkControllers);
    _progressCallbacks.addAll(incoming._progressCallbacks);
    _eventCallbacks.addAll(incoming._eventCallbacks);
    _disposeCallbacks.addAll(incoming._disposeCallbacks);
  }

  // ── PolicyAwareTask impl ────────────────────────────────────

  @override
  bool permissionValid(ExecutionContext ctx) => ctx.downloadAllowed;

  @override
  Future<void> doExecute(ExecutionContext ctx) async {
    _cancelToken = CancelToken();
    Log.info('WebP.Pipeline.Flow', 'DOWNLOAD-START ${_exec.imageKey.split('/').last}');

    try {
      final bytes = await _exec.execute(
        cancelToken: _cancelToken,
        onProgress: (current, total) {
          for (final callback in _progressCallbacks) {
            callback(current, total);
          }
          for (final sc in _chunkControllers) {
            if (!sc.isClosed) {
              sc.add(
                ImageChunkEvent(
                  cumulativeBytesLoaded: current,
                  expectedTotalBytes: total ?? 0,
                ),
              );
            }
          }
        },
        onEvent: (event) {
          for (final callback in _eventCallbacks) {
            callback(event);
          }
        },
      );

      // [FIX-9] Check context still valid after async gap
      if (!ctx.downloadAllowed) {
        if (isCancelled) {
          _rejectAll('Policy changed mid-download');
          throw Exception('Policy changed mid-download');
        }
      }

      _resolveAll(bytes);
    } catch (e) {
      if (!isCancelled) {
        _rejectAll(e);
      }
      rethrow;
    }
  }

  @override
  void disposeResources() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _chunkControllers.clear();
    _progressCallbacks.clear();
    _eventCallbacks.clear();
    for (final callback in _disposeCallbacks) {
      callback();
    }
    _disposeCallbacks.clear();
  }

  @override
  void cancel() {
    _cancelToken?.cancel();
    super.cancel();
    if (!_finished) _rejectAll('Cancelled');
  }

  // ── Internal ────────────────────────────────────────────────

  void _resolveAll(Uint8List bytes) {
    if (_waitersCompleted) return;
    _waitersCompleted = true;
    for (final c in _completers) {
      if (!c.isCompleted) c.complete(bytes);
    }
    _completers.clear();
  }

  void _rejectAll(Object error) {
    if (_waitersCompleted) return;
    _waitersCompleted = true;
    for (final c in _completers) {
      if (!c.isCompleted) c.completeError(error);
    }
    _completers.clear();
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
  void execute() async {
    if (isCancelled) return;
    _cancelToken = CancelToken();
    try {
      final file = await transport.execute(
        session,
        cancelToken: _cancelToken,
        onProgress: onProgress,
      );
      if (isCancelled) return;
      _state = TaskState.completed;
      _finished = true;
      for (final waiter in _waiters) {
        if (!waiter.isCompleted) waiter.complete(file);
      }
      _waiters.clear();
      notifyCompleted();
    } catch (error, stack) {
      if (isCancelled) return;
      _state = TaskState.failed;
      _finished = true;
      for (final waiter in _waiters) {
        if (!waiter.isCompleted) waiter.completeError(error, stack);
      }
      _waiters.clear();
      notifyFailed();
    } finally {
      _cancelToken = null;
    }
  }

  @override
  void cancel() {
    if (_finished || isCancelled) return;
    _cancelToken?.cancel('WebP transport paused');
    super.cancel();
    session.markPaused();
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.completeError('WebP transport paused');
    }
    _waiters.clear();
  }
}

// ───────────────────────────────────────────────────────────────
// 9. PrecreateTask — pre-creates decoder holders
// ───────────────────────────────────────────────────────────────

typedef PrecreateHolderFactory = Future<dynamic> Function({
  required String imageKey,
  required String fullKey,
  DecodedImageCache? cache,
  String? sourceKey,
  required String cid,
  required String eid,
  int targetWidth,
  int targetHeight,
  double scale,
  Uint8List? providedBytes,
  bool onlyIfCached,
});

class PrecreateTask extends PolicyAwareTask {
  final DecodedImageCache? cache;
  final int targetWidth, targetHeight;
  final double scale;
  final Uint8List? providedBytes;
  final String _imageKey;
  final String? _sourceKey;
  final String _cid, _eid;
  final PrecreateHolderFactory _holderFactory;

  @override
  SchedulerLane get lane => SchedulerLane.decode;

  /// Completers waiting for the holder to be created.
  final List<Completer<dynamic>> _holderCompleters = [];

  PrecreateTask({
    required super.key,
    required super.generation,
    required super.priority,
    required super.cancelable,
    this.cache,
    required String imageKey,
    required String? sourceKey,
    required String cid,
    required String eid,
    required PrecreateHolderFactory holderFactory,
    required this.targetWidth,
    required this.targetHeight,
    required this.scale,
    this.providedBytes,
  }) : _imageKey = imageKey,
       _sourceKey = sourceKey,
       _cid = cid,
       _eid = eid,
       _holderFactory = holderFactory;

  /// Register interest in the decoder holder. Returns a Future that
  /// completes with the holder when it's created.
  Future<dynamic> register() {
    final c = Completer<dynamic>();
    _holderCompleters.add(c);
    return c.future;
  }

  void mergeWaitersFrom(PrecreateTask incoming) {
    _holderCompleters.addAll(incoming._holderCompleters);
  }

  @override
  bool permissionValid(ExecutionContext ctx) => ctx.decodeAllowed;

  @override
  Future<void> doExecute(ExecutionContext ctx) async {
    final holder = await _holderFactory(
      imageKey: _imageKey,
      fullKey: key,
      cache: cache,
      sourceKey: _sourceKey,
      cid: _cid,
      eid: _eid,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      scale: scale,
      providedBytes: providedBytes,
      onlyIfCached: true,
    );
    // Resolve all waiters
    for (final c in _holderCompleters) {
      if (!c.isCompleted) c.complete(holder);
    }
    _holderCompleters.clear();
  }

  @override
  void disposeResources() {
    for (final c in _holderCompleters) {
      if (!c.isCompleted) c.completeError('Task disposed');
    }
    _holderCompleters.clear();
  }
}
