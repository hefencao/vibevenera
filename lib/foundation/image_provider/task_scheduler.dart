import 'dart:async';

import 'package:dio/dio.dart'; // CancelToken
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
import 'package:venera/network/images.dart';

import 'webp_image_provider.dart';

// ═══════════════════════════════════════════════════════════════
// Image Pipeline — Policy → Resource → Scheduler
//
//   InteractionState → ResourcePolicy → ResourceEntry → PipelineController
//                                                              │
//                                              ┌───────────────┼───────────────┐
//                                              ▼               ▼               ▼
//                                        DownloadTask    PrecreateTask    (future)
//
//   TaskScheduler — pure dispatcher (priority queue + concurrency)
//   TaskRegistry  — key→task lookup + dedup
//   MigrationMgr  — priority-based task migration
// ═══════════════════════════════════════════════════════════════

// ───────────────────────────────────────────────────────────────
// 1. Enums
// ───────────────────────────────────────────────────────────────

enum InteractionState { idle, dragging, jumping, settling }

enum PagePriority { current, near, far, distant }

/// Explicit task lifecycle state.
/// [FIX-7] Replaces implicit state spread across Registry + Queue + bool flags.
enum TaskState { queued, running, completed, cancelled, failed }

// ───────────────────────────────────────────────────────────────
// 2. ResourcePolicy
// ───────────────────────────────────────────────────────────────

class ResourcePolicy {
  final bool allowDownload;
  final bool allowDecode;
  final bool allowGpuUpload;
  final bool allowEviction;
  final int downloadPriority;
  final int decodePriority;

  const ResourcePolicy({
    this.allowDownload = false,
    this.allowDecode = false,
    this.allowGpuUpload = false,
    this.allowEviction = false,
    this.downloadPriority = 0,
    this.decodePriority = 0,
  });

  static const _none = ResourcePolicy();

  static const _current = ResourcePolicy(
    allowDownload: true,
    allowDecode: true,
    allowGpuUpload: true,
    downloadPriority: 100,
    decodePriority: 100,
  );

  static const _near = ResourcePolicy(
    allowDownload: true,
    allowDecode: true,
    allowGpuUpload: true,
    downloadPriority: 50,
    decodePriority: 50,
  );

  static const _far = ResourcePolicy(
    allowDownload: true,
    allowDecode: false,
    allowGpuUpload: false,
    downloadPriority: 20,
    decodePriority: 0,
  );

  static const _distant = ResourcePolicy(allowEviction: true);

  static const _draggingCurrent = ResourcePolicy(
    allowDownload: true,
    allowGpuUpload: true,
    downloadPriority: 100,
  );

  static const _draggingNear = ResourcePolicy(
    allowDownload: true,
    downloadPriority: 30,
  );

  static const _draggingFar = ResourcePolicy(
    allowDownload: true,
    downloadPriority: 10,
  );

  static const _settlingNear = ResourcePolicy(
    allowDownload: true,
    allowDecode: true,
    downloadPriority: 40,
    decodePriority: 40,
  );

  static const _settlingFar = ResourcePolicy(
    allowDownload: true,
    downloadPriority: 15,
  );

  static const _table = <InteractionState, Map<PagePriority, ResourcePolicy>>{
    InteractionState.dragging: {
      PagePriority.current: _draggingCurrent,
      PagePriority.near: _draggingNear,
      PagePriority.far: _draggingFar,
      PagePriority.distant: _distant,
    },
    InteractionState.jumping: {
      PagePriority.current: _current,
      PagePriority.near: _distant,
      PagePriority.far: _distant,
      PagePriority.distant: _distant,
    },
    InteractionState.settling: {
      PagePriority.current: _current,
      PagePriority.near: _settlingNear,
      PagePriority.far: _settlingFar,
      PagePriority.distant: _distant,
    },
    InteractionState.idle: {
      PagePriority.current: _current,
      PagePriority.near: _near,
      PagePriority.far: _far,
      PagePriority.distant: _distant,
    },
  };

  static ResourcePolicy compute(InteractionState i, PagePriority p) =>
      _table[i]?[p] ?? _none;
}

// ───────────────────────────────────────────────────────────────
// 3. ResourceEntry — single source of truth
// ───────────────────────────────────────────────────────────────

/// Sub-state for the download phase.
class DownloadState {
  bool inProgress = false;
  Object? lastError;
  void reset() {
    inProgress = false;
    lastError = null;
  }
}

/// Sub-state for the decode phase.
class DecodeState {
  bool inProgress = false;
  int decodedFrameCount = 0;
  int uploadedFrameCount = 0;
  void reset() {
    inProgress = false;
    decodedFrameCount = 0;
    uploadedFrameCount = 0;
  }
}

/// Single source of truth for one image resource.
///
/// [FIX-1] Removed the `ResourceState` enum. Overall state is derived
/// dynamically from sub-states — no more dual-source conflicts.
class ResourceEntry {
  final String imageKey;
  final String fullKey;
  final String? sourceKey;
  final String cid;
  final String eid;

  PagePriority _priority = PagePriority.distant;
  PagePriority get priority => _priority;

  ResourcePolicy _policy = ResourcePolicy._none;
  ResourcePolicy get policy => _policy;

  /// [FIX-2] Monotonic counter. Incremented ONLY when allowDownload
  /// or allowDecode changes (not priority). Running tasks compare
  /// their snapshot against this to detect permission revocation.
  int executionEpoch = 0;

  Uint8List? bytes;
  dynamic holder; // DecoderHolder
  Object? error;

  final DownloadState download = DownloadState();
  final DecodeState decode = DecodeState();

  int generation = 0;
  int lastAccessMs = 0;

  ResourceEntry({
    required this.imageKey,
    required this.fullKey,
    this.sourceKey,
    required this.cid,
    required this.eid,
  });

  // ── Derived state ──────────────────────────────────────────

  /// [FIX-1] Dynamically derived overall state. No more dual-source
  /// conflicts with DownloadState/DecodeState.
  String get overallState {
    if (error != null) return 'error';
    if (holder != null) return 'decoded';
    if (decode.inProgress) return 'decoding';
    if (bytes != null) return 'downloaded';
    if (download.inProgress) return 'downloading';
    return 'none';
  }

  bool get hasBytes => bytes != null;
  bool get hasHolder => holder != null;

  // ── Mutations ──────────────────────────────────────────────

  void updatePriority(PagePriority p) => _priority = p;

  void updatePolicy(ResourcePolicy newPolicy) {
    // [FIX-2] Only increment epoch when execution permissions change
    if (_policy.allowDownload != newPolicy.allowDownload ||
        _policy.allowDecode != newPolicy.allowDecode) {
      executionEpoch++;
    }
    _policy = newPolicy;
  }

  void logTransition(String from, String to) {
    debugPrint(
      '[Resource] $_shortKey $from → $to '
      '(dl=${_policy.allowDownload} dec=${_policy.allowDecode})',
    );
  }

  String get _shortKey {
    final s = imageKey.split('/').last;
    return s.length > 20 ? s.substring(s.length - 20) : s;
  }
}

// ───────────────────────────────────────────────────────────────
// 4. ExecutionContext — decouples Tasks from Policy/Entry
// ───────────────────────────────────────────────────────────────

/// [FIX-6] Tasks interact with the pipeline exclusively through
/// this context. They never access Policy, ResourceEntry, or
/// DecoderManager directly. This means Policy can change freely
/// without touching Task code.
class ExecutionContext {
  final ResourceEntry entry;
  final int _capturedEpoch;

  ExecutionContext(this.entry) : _capturedEpoch = entry.executionEpoch;

  /// Whether the task is still allowed to continue.
  bool get canContinue {
    return entry.executionEpoch == _capturedEpoch;
  }

  /// Type-specific permission checks.
  bool get downloadAllowed => canContinue && entry.policy.allowDownload;
  bool get decodeAllowed => canContinue && entry.policy.allowDecode;

  /// The entry's current policy (read-only for tasks).
  ResourcePolicy get policy => entry.policy;
}

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
      _finish(false);
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
  }) async {
    // 1. Disk cache
    final cacheKey = '$imageKey@$sourceKey@$cid@$eid';
    try {
      final cacheFile = await CacheManager().findCache(cacheKey);
      if (cacheFile != null && await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (bytes.isNotEmpty) {
          debugPrint(
            '[DownloadExec] HIT-CACHE $imageKey (${bytes.length ~/ 1024}KB)',
          );
          return bytes;
        }
      }
    } catch (e) {
      debugPrint('[DownloadExec] cache check error: $e');
    }

    if (cancelToken?.isCancelled == true) throw Exception('Cancelled');

    // 2. Network
    debugPrint('[DownloadExec] NETWORK $imageKey');
    final completer = Completer<Uint8List>();

    final sub =
        ImageDownloader.loadComicImage(
          imageKey,
          sourceKey,
          cid,
          eid,
          cancelToken: cancelToken,
        ).listen(
          (event) {
            if (cancelToken?.isCancelled == true) {
              if (!completer.isCompleted) completer.completeError('Cancelled');
              return;
            }
            if (event.currentBytes > 0 && onProgress != null) {
              onProgress(event.currentBytes, event.totalBytes);
            }
            if (event.imageBytes != null) {
              if (!completer.isCompleted) completer.complete(event.imageBytes!);
            }
          },
          onError: (e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.completeError('Download completed without data');
            }
          },
        );

    // Propagate cancel
    cancelToken?.whenCancel.then((_) {
      sub.cancel();
      if (!completer.isCompleted) completer.completeError('Cancelled');
    });

    return completer.future;
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
  }) : _exec = DownloadExecution(
         imageKey: imageKey,
         sourceKey: sourceKey,
         cid: cid,
         eid: eid,
       );

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
      );

      // [FIX-9] Check context still valid after async gap
      if (!ctx.downloadAllowed) {
        debugPrint('[DownloadTask] CANCEL-POLICY-RUNTIME $key');
        _rejectAll('Policy changed mid-download');
        return;
      }

      debugPrint('[DownloadTask] DONE $key (${bytes.length ~/ 1024}KB)');
      _resolveAll(bytes);
      TaskScheduler.instance.onTaskCompleted(this);
    } catch (e) {
      if (!isCancelled) {
        _rejectAll(e);
        TaskScheduler.instance.onTaskFailed(this);
      }
    }
  }

  @override
  void disposeResources() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _chunkControllers.clear();
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

// ───────────────────────────────────────────────────────────────
// 10. TaskRegistry — key→task lookup with dedup
// ───────────────────────────────────────────────────────────────

class _TaskRegistry {
  final Map<String, SchedulerTask> _queued = {};
  final Map<String, SchedulerTask> _running = {};

  SchedulerTask? find(String key) => _running[key] ?? _queued[key];
  bool contains(String key) =>
      _running.containsKey(key) || _queued.containsKey(key);
  bool isRunning(String key) => _running.containsKey(key);
  bool isQueued(String key) => _queued.containsKey(key);

  void addQueued(SchedulerTask task) => _queued[task.key] = task;

  void promoteToRunning(SchedulerTask task) {
    _queued.remove(task.key);
    _running[task.key] = task;
    task.onDispatch();
  }

  SchedulerTask? remove(String key) =>
      _running.remove(key) ?? _queued.remove(key);

  /// [FIX-6] Update priorities only for queued tasks.
  void updateQueuedPriorities(Map<String, int> newPriorities) {
    for (final entry in _queued.entries) {
      if (newPriorities.containsKey(entry.key)) {
        entry.value.priority = newPriorities[entry.key]!;
      }
    }
  }

  List<SchedulerTask> get queuedTasks => _queued.values.toList();
  List<SchedulerTask> get runningTasks => _running.values.toList();
  int get runningCount => _running.length;

  List<SchedulerTask> runningNotIn(Set<String> activeKeys) => _running.entries
      .where((e) => !activeKeys.contains(e.key))
      .map((e) => e.value)
      .toList();

  void clear() {
    _queued.clear();
    _running.clear();
  }
}

// ───────────────────────────────────────────────────────────────
// 11. MigrationManager — priority-based task migration
// ───────────────────────────────────────────────────────────────

/// [FIX-8] Extracted from TaskScheduler. Handles priority updates
/// and cancellation of tasks that left the working set.
class _MigrationManager {
  void migrate(
    _TaskRegistry registry,
    List<SchedulerTask> queue,
    Set<String> activeKeys,
    Map<String, int> newPriorities,
  ) {
    // 1. Cancel queued tasks not in active set
    final toCancel = <SchedulerTask>[];
    for (final t in queue) {
      if (!activeKeys.contains(t.key) && t.cancelable) {
        toCancel.add(t);
      }
    }
    for (final t in toCancel) {
      debugPrint('[Migration] CANCEL ${t.key} (out of range)');
      t.cancel();
      queue.remove(t);
      registry.remove(t.key);
    }

    // 2. Update priorities for queued tasks (not running)
    registry.updateQueuedPriorities(newPriorities);

    // 3. Cancel running tasks not in active set
    for (final t in registry.runningNotIn(activeKeys)) {
      if (!t.cancelable) continue;
      debugPrint('[Migration] CANCEL-RUNNING ${t.key}');
      t.cancel();
      registry.remove(t.key);
    }
  }
}

// ───────────────────────────────────────────────────────────────
// 12. TaskScheduler — pure dispatcher
// ───────────────────────────────────────────────────────────────

/// Execution layer. Knows only: queue, dispatch, concurrency.
/// Policy decisions live in [PipelineController].
/// Migration logic lives in [_MigrationManager].
class TaskScheduler {
  static final TaskScheduler instance = TaskScheduler._();
  TaskScheduler._();

  final _TaskRegistry _registry = _TaskRegistry();
  final _MigrationManager _migration = _MigrationManager();
  final List<SchedulerTask> _queue = [];

  static const int _maxConcurrent = 3;
  static const int _preemptionThreshold = 40;

  // ── Public API ──────────────────────────────────────────────

  void submit(SchedulerTask task) {
    final existing = _registry.find(task.key);
    if (existing != null) {
      final int oldPriority = existing.priority;
      if (task.priority > existing.priority) {
        existing.priority = task.priority;
        existing.cancelable = task.cancelable;
        if (existing is DownloadTask && task is DownloadTask) {
          existing._completers.addAll(task._completers);
          existing._chunkControllers.addAll(task._chunkControllers);
        }
        _sortQueue();
        _maybePreempt(existing, task, oldPriority);
      }
      return;
    }

    _registry.addQueued(task);
    _queue.add(task);
    _sortQueue();
    _dispatchNext();
  }

  void cancel(String key) {
    final task = _registry.find(key);
    if (task != null) {
      task.cancel();
      _queue.remove(task);
      _registry.remove(key);
    }
  }

  void migrateTasks(Set<String> activeKeys, Map<String, int> newPriorities) {
    _migration.migrate(_registry, _queue, activeKeys, newPriorities);
    _sortQueue();
    _dispatchNext();
  }

  void clear() {
    for (final t in _queue) {
      t.cancel();
    }
    _queue.clear();
    for (final t in _registry.runningTasks) {
      t.cancel();
    }
    _registry.clear();
  }

  int get pendingCount => _queue.length + _registry.runningCount;

  // ── Callbacks ───────────────────────────────────────────────

  void onTaskCompleted(SchedulerTask task) {
    _registry.remove(task.key);
    _dispatchNext();
  }

  void onTaskFailed(SchedulerTask task) {
    _registry.remove(task.key);
    _dispatchNext();
  }

  // ── Internal ────────────────────────────────────────────────

  void _sortQueue() => _queue.sort((a, b) => b.priority.compareTo(a.priority));

  void _dispatchNext() {
    if (_registry.runningCount >= _maxConcurrent || _queue.isEmpty) return;
    final task = _queue.removeAt(0);
    _registry.promoteToRunning(task);
    scheduleMicrotask(() {
      try {
        task.execute();
      } catch (e, st) {
        debugPrint('[TaskScheduler] task execute error: $e\n$st');
        onTaskFailed(task);
      }
    });
  }

  void _maybePreempt(
    SchedulerTask existing,
    SchedulerTask incoming,
    int oldPriority,
  ) {
    if (!existing.cancelable) return;
    if (incoming.priority - oldPriority < _preemptionThreshold) return;
    debugPrint(
      '[TaskScheduler] PREEMPT ${existing.key} ($oldPriority → ${incoming.priority})',
    );
    existing.cancel();
    _queue.remove(existing);
    _registry.remove(existing.key);
    _registry.addQueued(incoming);
    _queue.add(incoming);
    _sortQueue();
    _dispatchNext();
  }
}
