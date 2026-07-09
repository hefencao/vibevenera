part of '../task_scheduler.dart';

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

  /// Update priorities for queued and running tasks. Running priority matters
  /// for later preemption decisions: a far-download promoted to current must
  /// not remain the lowest-priority running task.
  void updatePriorities(Map<String, int> newPriorities) {
    for (final entry in _queued.entries) {
      if (newPriorities.containsKey(entry.key)) {
        entry.value.priority = newPriorities[entry.key]!;
      }
    }
    for (final entry in _running.entries) {
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

    // 2. Update priorities before running-task cancellation/preemption checks.
    registry.updatePriorities(newPriorities);

    // 3. Decode/precreate work outside the active set is disposable. Running
    // downloads are different: if a slot is already occupied and there is no
    // stronger task waiting, cancelling wastes bandwidth and hurts the common
    // "look a few pages ahead then come back" path. Keep them running; normal
    // scheduler preemption below will still cancel the lowest ranked download
    // when a high-priority current/near task needs the slot.
    for (final t in registry.runningNotIn(activeKeys)) {
      if (!t.cancelable) continue;
      if (t is DownloadTask) continue;
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
      if (_shouldPreempt(existing, task, oldPriority)) {
        _maybePreempt(existing, task, oldPriority);
        return;
      }
      _mergeWaiters(existing, task);
      if (task.priority > existing.priority) {
        existing.priority = task.priority;
        existing.cancelable = task.cancelable;
        _sortQueue();
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
  bool hasTask(String key) => _registry.contains(key);
  int get maxConcurrent => _maxConcurrent;
  int get runningCount => _registry.runningCount;
  int get runningDownloadCount =>
      _registry.runningTasks.whereType<DownloadTask>().length;
  int get queuedDownloadCount => _queue.whereType<DownloadTask>().length;

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

  void _mergeWaiters(SchedulerTask existing, SchedulerTask incoming) {
    if (existing is DownloadTask && incoming is DownloadTask) {
      existing._completers.addAll(incoming._completers);
      existing._chunkControllers.addAll(incoming._chunkControllers);
      existing._progressCallbacks.addAll(incoming._progressCallbacks);
      existing._eventCallbacks.addAll(incoming._eventCallbacks);
      existing._disposeCallbacks.addAll(incoming._disposeCallbacks);
    } else if (existing is PrecreateTask && incoming is PrecreateTask) {
      existing._holderCompleters.addAll(incoming._holderCompleters);
    }
  }

  bool _shouldPreempt(
    SchedulerTask existing,
    SchedulerTask incoming,
    int oldPriority,
  ) {
    if (existing is DownloadTask && incoming is DownloadTask) return false;
    return existing.cancelable &&
        incoming.priority - oldPriority >= _preemptionThreshold;
  }

  void _dispatchNext() {
    while (_queue.isNotEmpty) {
      if (_registry.runningCount >= _maxConcurrent) {
        _preemptLowestRunningFor(_queue.first);
        if (_registry.runningCount >= _maxConcurrent) return;
      }
      final task = _queue.removeAt(0);
      _registry.promoteToRunning(task);
      debugPrint(
        '[TaskScheduler] DISPATCH ${task.key} pri=${task.priority} '
        'running=${_registry.runningCount}/$_maxConcurrent',
      );
      scheduleMicrotask(() {
        try {
          task.execute();
        } catch (e, st) {
          debugPrint('[TaskScheduler] task execute error: $e\n$st');
          onTaskFailed(task);
        }
      });
    }
  }

  void _maybePreempt(
    SchedulerTask existing,
    SchedulerTask incoming,
    int oldPriority,
  ) {
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

  void _preemptLowestRunningFor(SchedulerTask incoming) {
    SchedulerTask? lowest;
    for (final task in _registry.runningTasks) {
      if (!task.cancelable) continue;
      if (lowest == null || task.priority < lowest.priority) {
        lowest = task;
      }
    }
    if (lowest == null) return;
    if (incoming.priority - lowest.priority < _preemptionThreshold) return;

    debugPrint(
      '[TaskScheduler] PREEMPT-RUNNING ${lowest.key} '
      '(${lowest.priority} → ${incoming.priority})',
    );
    lowest.cancel();
    _registry.remove(lowest.key);
  }
}
