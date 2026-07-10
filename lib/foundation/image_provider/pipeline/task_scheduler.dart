import 'dart:async';

import 'package:venera/foundation/log.dart';

import 'tasks.dart';

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
class _TaskLaneScheduler {
  final _TaskRegistry _registry = _TaskRegistry();
  final _MigrationManager _migration = _MigrationManager();
  final List<SchedulerTask> _queue = [];
  final int maxConcurrent;
  final int preemptionThreshold;
  final void Function(SchedulerTask task) onCompleted;
  final void Function(SchedulerTask task) onFailed;

  _TaskLaneScheduler({
    required this.maxConcurrent,
    required this.preemptionThreshold,
    required this.onCompleted,
    required this.onFailed,
  });

  void submit(SchedulerTask task) {
    task.setCompletionHandlers(
      onCompleted: onCompleted,
      onFailed: onFailed,
    );
    final existing = _registry.find(task.key);
    if (existing != null) {
      final int oldPriority = existing.priority;
      if (_shouldPreempt(existing, task, oldPriority)) {
        _maybePreempt(existing, task);
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
  int get runningCount => _registry.runningCount;

  void taskCompleted(SchedulerTask task) {
    _registry.remove(task.key);
    _dispatchNext();
  }

  void taskFailed(SchedulerTask task) {
    _registry.remove(task.key);
    _dispatchNext();
  }

  void _sortQueue() => _queue.sort((a, b) => b.priority.compareTo(a.priority));

  void _mergeWaiters(SchedulerTask existing, SchedulerTask incoming) {
    if (existing is DownloadTask && incoming is DownloadTask) {
      existing.mergeWaitersFrom(incoming);
    } else if (existing is PrecreateTask && incoming is PrecreateTask) {
      existing.mergeWaitersFrom(incoming);
    }
  }

  bool _shouldPreempt(
    SchedulerTask existing,
    SchedulerTask incoming,
    int oldPriority,
  ) {
    if (existing is DownloadTask && incoming is DownloadTask) return false;
    return existing.cancelable &&
        incoming.priority - oldPriority >= preemptionThreshold;
  }

  void _dispatchNext() {
    while (_queue.isNotEmpty) {
      if (_registry.runningCount >= maxConcurrent) {
        _preemptLowestRunningFor(_queue.first);
        if (_registry.runningCount >= maxConcurrent) return;
      }
      final task = _queue.removeAt(0);
      _registry.promoteToRunning(task);
      scheduleMicrotask(() {
        try {
          task.execute();
        } catch (e, st) {
          Log.error('ImagePipeline.TaskScheduler', e, st);
          onFailed(task);
        }
      });
    }
  }

  void _maybePreempt(
    SchedulerTask existing,
    SchedulerTask incoming,
  ) {
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
    if (incoming.priority - lowest.priority < preemptionThreshold) return;

    lowest.cancel();
    _registry.remove(lowest.key);
  }
}

/// Independent network/decode/upload dispatch lanes. A decode/precreate task
/// can no longer occupy a transport permit or delay a current-page download.
class TaskScheduler {
  static final TaskScheduler instance = TaskScheduler._();

  late final Map<SchedulerLane, _TaskLaneScheduler> _lanes;

  TaskScheduler._() {
    _lanes = {
      SchedulerLane.network: _createLane(3),
      SchedulerLane.decode: _createLane(2),
      SchedulerLane.upload: _createLane(2),
    };
  }

  _TaskLaneScheduler _createLane(int maxConcurrent) => _TaskLaneScheduler(
    maxConcurrent: maxConcurrent,
    preemptionThreshold: 40,
    onCompleted: onTaskCompleted,
    onFailed: onTaskFailed,
  );

  void submit(SchedulerTask task) => _lanes[task.lane]!.submit(task);

  void cancel(String key) {
    for (final lane in _lanes.values) {
      lane.cancel(key);
    }
  }

  void migrateTasks(Set<String> activeKeys, Map<String, int> newPriorities) {
    for (final lane in _lanes.values) {
      lane.migrateTasks(activeKeys, newPriorities);
    }
  }

  void clear() {
    for (final lane in _lanes.values) {
      lane.clear();
    }
  }

  int get pendingCount =>
      _lanes.values.fold(0, (sum, lane) => sum + lane.pendingCount);
  bool hasTask(String key) => _lanes.values.any((lane) => lane.hasTask(key));
  int get maxConcurrent => _lanes[SchedulerLane.network]!.maxConcurrent;
  int get runningCount =>
      _lanes.values.fold(0, (sum, lane) => sum + lane.runningCount);
  int get runningDownloadCount =>
      _lanes[SchedulerLane.network]!._registry.runningCount;
  int get queuedDownloadCount =>
      _lanes[SchedulerLane.network]!._queue.length;

  void onTaskCompleted(SchedulerTask task) =>
      _lanes[task.lane]!.taskCompleted(task);

  void onTaskFailed(SchedulerTask task) =>
      _lanes[task.lane]!.taskFailed(task);
}
