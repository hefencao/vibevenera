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
//                                      WebPDownloadTask  WebPDecodeTask   (future)
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
      if (t.retainWhenInactive) continue;
      // Keep running tasks registered until their async cancellation path has
      // unwound and notified the scheduler. Releasing the permit early allows
      // two transports to write the same DownloadSession concurrently.
      t.cancel();
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
  int maxConcurrent;
  final int preemptionThreshold;
  final int reservedHighPrioritySlots;
  final int highPriorityThreshold;
  final void Function(SchedulerTask task) onCompleted;
  final void Function(SchedulerTask task) onFailed;

  _TaskLaneScheduler({
    required this.maxConcurrent,
    required this.preemptionThreshold,
    this.reservedHighPrioritySlots = 0,
    this.highPriorityThreshold = 1 << 30,
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

  void setMaxConcurrent(int value) {
    if (maxConcurrent == value) return;
    maxConcurrent = value;
    _dispatchNext();
  }

  void cancel(String key) {
    final task = _registry.find(key);
    if (task == null) return;
    task.cancel();
    if (_registry.isQueued(key)) {
      _queue.remove(task);
      _registry.remove(key);
      _dispatchNext();
    }
    // Running tasks keep their permit until notifyCompleted/notifyFailed.
  }

  void updatePriority(String key, int priority) {
    final task = _registry.find(key);
    if (task == null || task.priority == priority) return;
    final increased = priority > task.priority;
    task.priority = priority;
    _sortQueue();
    // 提权后必须重新派发。翻页时下一页此前多为近邻页，其下载/解码任务已排队；变
    // current 后走 updatePriority 提到高优先级，但只排序不派发就不会触发高优先级抢
    // 占，得等运行中任务自然结束才启动 → 这正是「切换页到开始下载/首帧延迟高」的
    // 主因。仅在提权时派发（降权不改变队首派发结果，派发也只是 no-op）。
    if (increased) _dispatchNext();
  }

  void migrateTasks(Set<String> activeKeys, Map<String, int> newPriorities) {
    _migration.migrate(_registry, _queue, activeKeys, newPriorities);
    _sortQueue();
    _dispatchNext();
  }

  void clear() {
    for (final t in _queue.toList()) {
      t.cancel();
      _registry.remove(t.key);
    }
    _queue.clear();
    for (final t in _registry.runningTasks) {
      // Keep running tasks registered until their async cleanup completes.
      // Otherwise a later submit can overlap the old native/network writer.
      t.cancel();
    }
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
    if (existing is WebPDownloadTask && incoming is WebPDownloadTask) {
      existing.mergeWaitersFrom(incoming);
    }
  }

  bool _shouldPreempt(
    SchedulerTask existing,
    SchedulerTask incoming,
    int oldPriority,
  ) {
    // Same-key work represents the same session. Promotion updates the task in
    // place; it must never cancel/recreate a running transport.
    if (_registry.isRunning(existing.key)) return false;
    if (existing is WebPDownloadTask && incoming is WebPDownloadTask) {
      return false;
    }
    return existing.cancelable &&
        incoming.priority - oldPriority >= preemptionThreshold;
  }

  void _dispatchNext() {
    while (_queue.isNotEmpty) {
      final next = _queue.first;
      final highPriority = next.priority >= highPriorityThreshold;
      final running = _registry.runningCount;

      if (!highPriority && running >= maxConcurrent) return;

      if (highPriority && running >= maxConcurrent) {
        // Normal work may fully use the lane. When current-page work arrives,
        // request cancellation of the lowest-ranked task and use at most one
        // temporary hand-off slot while that asynchronous cancellation unwinds.
        // This avoids permanently reducing network capacity from 3 to 2 and
        // still prevents a current page from waiting on a slow transport close.
        final handoffLimit = maxConcurrent + reservedHighPrioritySlots;
        if (reservedHighPrioritySlots <= 0 || running >= handoffLimit) {
          _preemptLowestRunningFor(next);
          return;
        }
        if (!_preemptLowestRunningFor(next)) return;
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

  bool _preemptLowestRunningFor(SchedulerTask incoming) {
    SchedulerTask? lowest;
    for (final task in _registry.runningTasks) {
      if (!task.cancelable || task.isCancelled) continue;
      if (lowest == null || task.priority < lowest.priority) {
        lowest = task;
      }
    }
    if (lowest == null) return false;
    if (incoming.priority - lowest.priority < preemptionThreshold) return false;

    // Cancellation is a request. The task remains registered until its async
    // cleanup notifies completion. A single high-priority hand-off slot may be
    // used meanwhile; same-key work is never preempted/recreated.
    lowest.cancel();
    return true;
  }
}

/// Independent network/decode/upload dispatch lanes. A decode/precreate task
/// can no longer occupy a transport permit or delay a current-page download.
class TaskScheduler {
  static final TaskScheduler instance = TaskScheduler._();

  late final Map<SchedulerLane, _TaskLaneScheduler> _lanes;

  TaskScheduler._() {
    _lanes = {
      // One controlled handoff lets a current-page request start while the
      // preempted transport is still unwinding, avoiding a visible stall.
      SchedulerLane.network: _createLane(
        5,
        reservedHighPrioritySlots: 1,
        highPriorityThreshold: 950,
      ),
      // Keep one dispatch slot available for current-page decode/upload. Near
      // prefetch can fill the remaining slots but cannot make a page switch
      // wait behind two long 4K jobs.
      SchedulerLane.decode: _createLane(
        3,
        reservedHighPrioritySlots: 1,
        highPriorityThreshold: 90,
      ),
      SchedulerLane.upload: _createLane(
        2,
        reservedHighPrioritySlots: 1,
        highPriorityThreshold: 90,
      ),
    };
  }

  _TaskLaneScheduler _createLane(
    int maxConcurrent, {
    int reservedHighPrioritySlots = 0,
    int highPriorityThreshold = 1 << 30,
  }) =>
      _TaskLaneScheduler(
        maxConcurrent: maxConcurrent,
        preemptionThreshold: 40,
        reservedHighPrioritySlots: reservedHighPrioritySlots,
        highPriorityThreshold: highPriorityThreshold,
        onCompleted: onTaskCompleted,
        onFailed: onTaskFailed,
      );

  void submit(SchedulerTask task) => _lanes[task.lane]!.submit(task);

  void setNetworkConcurrency(int value) =>
      _lanes[SchedulerLane.network]!.setMaxConcurrent(value.clamp(1, 16));

  bool hasTaskInLane(SchedulerLane lane, String key) =>
      _lanes[lane]!.hasTask(key);

  bool decodeTaskMatchesCurrent(String key, bool current) {
    final task = _lanes[SchedulerLane.decode]!._registry.find(key);
    return task is WebPDecodeTask && task.current == current;
  }

  void updatePriority(SchedulerLane lane, String key, int priority) =>
      _lanes[lane]!.updatePriority(key, priority);

  void cancelInLane(SchedulerLane lane, String key) =>
      _lanes[lane]!.cancel(key);

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
