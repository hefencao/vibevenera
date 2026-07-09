part of '../task_scheduler.dart';

// ───────────────────────────────────────────────────────────────
// 5. SchedulerTask — base with explicit lifecycle
// ───────────────────────────────────────────────────────────────

abstract class SchedulerTask {
  final String key;
  final int generation;
  int priority;
  bool cancelable;

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
      debugPrint('[Task] CANCEL-POLICY $key (permission revoked)');
      cancel();
      TaskScheduler.instance.onTaskCompleted(this);
      return;
    }

    try {
      await doExecute(ctx);
      if (!isCancelled && !_finished) {
        _finish(true);
      }
    } catch (e) {
      if (!isCancelled && !_finished) {
        _finish(false);
        TaskScheduler.instance.onTaskFailed(this);
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
  CancelToken? _cancelToken;

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

  // ── PolicyAwareTask impl ────────────────────────────────────

  @override
  bool permissionValid(ExecutionContext ctx) => ctx.downloadAllowed;

  @override
  Future<void> doExecute(ExecutionContext ctx) async {
    debugPrint('[DownloadTask] START $key (gen=$generation pri=$priority)');

    _cancelToken = CancelToken();

    // [FIX-9] Runtime policy check via CancelToken
    _cancelToken!.whenCancel.then((_) {
      debugPrint('[DownloadTask] cancel token triggered for $key');
    });

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
        debugPrint('[DownloadTask] CANCEL-POLICY-RUNTIME $key');
        if (isCancelled) {
          _rejectAll('Policy changed mid-download');
          TaskScheduler.instance.onTaskFailed(this);
          return;
        }
      }

      debugPrint('[DownloadTask] DONE $key (${bytes.length ~/ 1024}KB)');
      _resolveAll(bytes);
      TaskScheduler.instance.onTaskCompleted(this);
    } catch (e) {
      if (!isCancelled) {
        _rejectAll(e);
        TaskScheduler.instance.onTaskFailed(this);
      }
    } finally {
      disposeResources();
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
    if (_finished) return;
    _finished = true;
    for (final c in _completers) {
      if (!c.isCompleted) c.complete(bytes);
    }
    _completers.clear();
  }

  void _rejectAll(Object error) {
    if (_finished) return;
    _finished = true;
    for (final c in _completers) {
      if (!c.isCompleted) c.completeError(error);
    }
    _completers.clear();
  }
}

// ───────────────────────────────────────────────────────────────
// 9. PrecreateTask — pre-creates WebP decoder holders
// ───────────────────────────────────────────────────────────────

class PrecreateTask extends PolicyAwareTask {
  final DecodedImageCache? cache;
  final int targetWidth, targetHeight;
  final double scale;
  final Uint8List? providedBytes;
  final String _imageKey;
  final String? _sourceKey;
  final String _cid, _eid;

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
    required this.targetWidth,
    required this.targetHeight,
    required this.scale,
    this.providedBytes,
  }) : _imageKey = imageKey,
       _sourceKey = sourceKey,
       _cid = cid,
       _eid = eid;

  /// Register interest in the decoder holder. Returns a Future that
  /// completes with the holder when it's created.
  Future<dynamic> register() {
    final c = Completer<dynamic>();
    _holderCompleters.add(c);
    return c.future;
  }

  @override
  bool permissionValid(ExecutionContext ctx) => ctx.decodeAllowed;

  @override
  Future<void> doExecute(ExecutionContext ctx) async {
    debugPrint('[Precreate] EXEC $_imageKey (gen=$generation pri=$priority)');
    final holder = await WebPImageProvider.ensureHolder(
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
    debugPrint('[Precreate] DONE $_imageKey');
    TaskScheduler.instance.onTaskCompleted(this);
  }

  @override
  void disposeResources() {
    for (final c in _holderCompleters) {
      if (!c.isCompleted) c.completeError('Task disposed');
    }
    _holderCompleters.clear();
  }
}
