import 'dart:async';

import 'task_scheduler.dart';

// ═══════════════════════════════════════════════════════════════
// PipelineController — coordinates Policy → Resource → Scheduler
//
// Responsibilities:
//   - Owns ResourceEntry lifecycle (create / update / evict)
//   - Computes policies on page range changes
//   - Submits download and decode tasks for policy gaps
//   - Listens for resource state changes to cascade pipeline stages
//
// Non-responsibilities:
//   - Does NOT download, decode, or manage threads
//   - Does NOT implement the pipeline state machine (Entry does)
// ═══════════════════════════════════════════════════════════════

/// Manages the lifecycle of [ResourceEntry] objects and orchestrates
/// the download → decode pipeline for a set of image pages.
class ResourceManager {
  final Map<String, ResourceEntry> _entries = {};
  final Map<String, List<ResourceEntry>> _entriesByImageKey = {};

  /// Stream controller for resource state changes.
  final _stateController = StreamController<ResourceEvent>.broadcast();
  Stream<ResourceEvent> get events => _stateController.stream;

  int get entryCount => _entries.length;

  // ── Entry lifecycle ────────────────────────────────────────

  ResourceEntry ensure({
    required String imageKey,
    required String fullKey,
    String? sourceKey,
    required String cid,
    required String eid,
  }) {
    var entry = _entries[fullKey];
    if (entry == null) {
      entry = ResourceEntry(
        imageKey: imageKey,
        fullKey: fullKey,
        sourceKey: sourceKey,
        cid: cid,
        eid: eid,
      );
      _entries[fullKey] = entry;
      _entriesByImageKey.putIfAbsent(imageKey, () => []).add(entry);
    }
    return entry;
  }

  ResourceEntry? get(String key) {
    return _entries[key] ?? _entriesByImageKey[key]?.firstOrNull;
  }

  /// All entries for a given bare imageKey (supports multi-size).
  List<ResourceEntry> getAllForImage(String imageKey) {
    return _entriesByImageKey[imageKey] ?? [];
  }

  void forEach(void Function(ResourceEntry) fn) {
    for (final e in _entries.values) { fn(e); }
  }

  /// Release resources for an entry (bytes, holder, frame data).
  void release(ResourceEntry entry) {
    final holder = entry.holder;
    if (holder != null) {
      // holder.dispose() is called by DecoderManager eviction
      entry.holder = null;
    }
    entry.bytes = null;
    entry.download.reset();
    entry.decode.reset();
    _stateController.add(ResourceEvent(entry.fullKey, ResourceEventType.released));
  }

  void remove(String fullKey) {
    final entry = _entries.remove(fullKey);
    if (entry != null) {
      final list = _entriesByImageKey[entry.imageKey];
      if (list != null) {
        list.remove(entry);
        if (list.isEmpty) _entriesByImageKey.remove(entry.imageKey);
      }
    }
  }

  void clear() {
    _entries.clear();
    _entriesByImageKey.clear();
  }

  void dispose() {
    clear();
    _stateController.close();
  }
}

// ───────────────────────────────────────────────────────────────
// Resource events
// ───────────────────────────────────────────────────────────────

enum ResourceEventType {
  bytesReady,    // Download complete
  holderReady,   // Decoder created
  released,      // Resources freed
  policyChanged, // allowDownload/allowDecode changed
}

class ResourceEvent {
  final String fullKey;
  final ResourceEventType type;
  ResourceEvent(this.fullKey, this.type);
}

// ═══════════════════════════════════════════════════════════════
// PipelineController
// ═══════════════════════════════════════════════════════════════

class PipelineController {
  static final PipelineController instance = PipelineController._();
  PipelineController._();

  final ResourceManager resources = ResourceManager();
  final TaskScheduler _scheduler = TaskScheduler.instance;

  InteractionState _interaction = InteractionState.idle;
  int _targetW = 0, _targetH = 0;

  String _currentKey = '';
  final Set<String> _nearKeys = {};
  final Set<String> _farKeys = {};

  // ── Public API ──────────────────────────────────────────────

  void setTargetSize(int w, int h) { _targetW = w; _targetH = h; }

  void setInteractionState(InteractionState state) {
    if (_interaction == state) return;
    _interaction = state;
    _refreshPolicies();
    // executionEpoch handles running-task cancellation automatically
  }

  void onPageRangeChanged({
    required int currentIdx,
    required List<String> images,
    required String cid,
    required String eid,
    required String? sourceKey,
    int preloadCount = 5,
  }) {
    String fk(int i) => (i >= 0 && i < images.length) ? images[i] : '';

    _currentKey = fk(currentIdx);
    _nearKeys.clear(); _farKeys.clear();
    for (int i = 1; i <= 2; i++) {
      final k = fk(currentIdx + i);
      if (k.isNotEmpty) _nearKeys.add(k);
    }
    for (int i = 3; i <= preloadCount; i++) {
      final k = fk(currentIdx + i);
      if (k.isNotEmpty) _farKeys.add(k);
    }

    // Ensure entries exist
    String fullKey(String k) =>
        _targetW > 0 ? '$k@${_targetW}x$_targetH' : k;
    for (final key in {_currentKey, ..._nearKeys, ..._farKeys}) {
      if (key.isEmpty) continue;
      resources.ensure(
        imageKey: key, fullKey: fullKey(key),
        sourceKey: sourceKey, cid: cid, eid: eid,
      );
    }

    _assignPriorities();
    _refreshPolicies();

    // Migrate existing tasks
    final activeKeys = <String>{_currentKey, ..._nearKeys, ..._farKeys};
    final newPriorities = <String, int>{};
    resources.forEach((e) {
      if (e.policy.downloadPriority > 0) {
        newPriorities[e.imageKey] = e.policy.downloadPriority;
      }
    });
    _scheduler.migrateTasks(activeKeys, newPriorities);

    // Submit work
    _submitWork(sourceKey, cid, eid);

    // Mark distant entries
    resources.forEach((e) {
      if (!activeKeys.contains(e.imageKey)) {
        e.updatePriority(PagePriority.distant);
        e.updatePolicy(ResourcePolicy.compute(_interaction, PagePriority.distant));
      }
    });
  }

  void dispose() {
    _scheduler.clear();
    resources.dispose();
  }

  // ── Internal: priorities & policies ────────────────────────

  void _assignPriorities() {
    final byKey = <String, ResourceEntry>{};
    resources.forEach((e) => byKey[e.imageKey] = e);

    byKey[_currentKey]?.updatePriority(PagePriority.current);
    for (final k in _nearKeys) { byKey[k]?.updatePriority(PagePriority.near); }
    for (final k in _farKeys) { byKey[k]?.updatePriority(PagePriority.far); }
  }

  void _refreshPolicies() {
    final byKey = <String, ResourceEntry>{};
    resources.forEach((e) => byKey[e.imageKey] = e);

    byKey[_currentKey]?.updatePolicy(
      ResourcePolicy.compute(_interaction, PagePriority.current));
    for (final k in _nearKeys) {
      byKey[k]?.updatePolicy(
        ResourcePolicy.compute(_interaction, PagePriority.near));
    }
    for (final k in _farKeys) {
      byKey[k]?.updatePolicy(
        ResourcePolicy.compute(_interaction, PagePriority.far));
    }
  }

  // ── Internal: work submission (split by stage) ──────────────

  void _submitWork(String? sourceKey, String cid, String eid) {
    resources.forEach((entry) => _evaluateEntry(entry, sourceKey, cid, eid));
  }

  void _evaluateEntry(ResourceEntry entry, String? sourceKey,
      String cid, String eid) {
    _submitDownload(entry, sourceKey, cid, eid);
    _submitDecode(entry, sourceKey, cid, eid);
    _submitEviction(entry);
  }

  void _submitDownload(ResourceEntry entry, String? sourceKey,
      String cid, String eid) {
    if (entry.imageKey.startsWith('file://')) return;
    if (!entry.policy.allowDownload) return;
    if (entry.hasBytes) return;
    if (entry.download.inProgress) return;

    entry.download.inProgress = true;
    final task = DownloadTask(
      key: entry.imageKey,
      imageKey: entry.imageKey,
      fullKey: entry.fullKey,
      generation: entry.generation,
      priority: entry.policy.downloadPriority,
      cancelable: true,
      sourceKey: sourceKey,
      cid: cid,
      eid: eid,
    );
    task.register().then((bytes) {
      entry.bytes = bytes;
      entry.download.inProgress = false;
      // Cascade: bytes ready → maybe decode
      _submitDecode(entry, sourceKey, cid, eid);
    }).catchError((_) {
      entry.download.inProgress = false;
    });
    _scheduler.submit(task);
  }

  void _submitDecode(ResourceEntry entry, String? sourceKey,
      String cid, String eid) {
    if (!entry.policy.allowDecode) return;
    if (entry.hasHolder) return;
    if (!entry.hasBytes) return;
    if (entry.decode.inProgress) return;

    entry.decode.inProgress = true;
    final task = PrecreateTask(
      key: entry.fullKey,
      imageKey: entry.imageKey,
      generation: entry.generation,
      priority: entry.policy.decodePriority,
      cancelable: true,
      sourceKey: sourceKey,
      cid: cid,
      eid: eid,
      targetWidth: _targetW,
      targetHeight: _targetH,
      scale: 1.0,
    );
    task.register().then((holder) {
      entry.holder = holder;
      entry.decode.inProgress = false;
    }).catchError((_) {
      entry.decode.inProgress = false;
    });
    _scheduler.submit(task);
  }

  void _submitEviction(ResourceEntry entry) {
    if (!entry.policy.allowEviction) return;
    if (!entry.hasBytes && !entry.hasHolder) return;
    resources.release(entry);
  }
}
