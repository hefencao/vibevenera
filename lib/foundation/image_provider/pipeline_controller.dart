import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'preload_policy.dart';
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
    for (final e in _entries.values) {
      fn(e);
    }
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
    _stateController.add(
      ResourceEvent(entry.fullKey, ResourceEventType.released),
    );
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
  bytesReady, // Download complete
  holderReady, // Decoder created
  released, // Resources freed
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

  void Function(
    String currentKey,
    Set<String> decodeNextKeys,
    Set<String> decodePrevKeys,
    Set<String> downloadOnlyKeys,
  )?
  onWindowChanged;

  InteractionState _interaction = InteractionState.idle;
  int _targetW = 0, _targetH = 0;
  DecodedImageCache? _cache;
  int _currentIdx = 0;
  int _stableIdx = 0;
  int _readDirection = 1;
  bool _hasCurrentIdx = false;
  int _preloadCount = 5;
  int _currentBufferedFrames = 0;
  int _windowKey = -1;
  int? _provisionalIdx;
  Timer? _jumpProtectionTimer;
  List<String> _images = const [];
  String? _sourceKey;
  String _cid = '';
  String _eid = '';

  String _currentKey = '';
  final Set<String> _nearKeys = {};
  final Set<String> _prevKeys = {};
  final Set<String> _farKeys = {};
  final Set<String> _keepKeys = {};
  final Map<String, int> _offsetByKey = {};

  static const int _jumpProtectionDistance = 3;
  static const Duration _jumpProtectionWindow = Duration(milliseconds: 1200);
  static const int _mobilePrefetchBudgetBytes = 48 * 1024 * 1024;
  static const int _desktopPrefetchBudgetBytes = 192 * 1024 * 1024;
  static const int _mobileUnknownPrefetchBytes = 16 * 1024 * 1024;
  static const int _desktopUnknownPrefetchBytes = 32 * 1024 * 1024;

  // ── Public API ──────────────────────────────────────────────

  void setTargetSize(int w, int h) {
    _targetW = w;
    _targetH = h;
  }

  InteractionState get interactionState => _interaction;

  void setInteractionState(InteractionState state) {
    if (_interaction == state) return;
    _interaction = state;
    if (_images.isEmpty) {
      _refreshPolicies();
    } else {
      _applyWindow(protectJump: _provisionalIdx != null);
    }
  }

  void onPageRangeChanged({
    required int currentIdx,
    required List<String> images,
    required String cid,
    required String eid,
    required String? sourceKey,
    DecodedImageCache? cache,
    int preloadCount = 5,
  }) {
    final contextChanged =
        !identical(_images, images) || _cid != cid || _eid != eid;
    _cache = cache;
    _images = images;
    _cid = cid;
    _eid = eid;
    _sourceKey = sourceKey;
    _preloadCount = preloadCount;
    _currentBufferedFrames = 0;
    _windowKey = -1;
    if (contextChanged) {
      _hasCurrentIdx = false;
      _jumpProtectionTimer?.cancel();
      _provisionalIdx = null;
    }

    _setCurrentIndex(currentIdx);
  }

  void onCurrentOnlyChanged({
    required int currentIdx,
    required List<String> images,
    required String cid,
    required String eid,
    required String? sourceKey,
    DecodedImageCache? cache,
    int preloadCount = 5,
  }) {
    final contextChanged =
        !identical(_images, images) || _cid != cid || _eid != eid;
    _cache = cache;
    _images = images;
    _cid = cid;
    _eid = eid;
    _sourceKey = sourceKey;
    _preloadCount = preloadCount;
    _currentBufferedFrames = 0;
    _windowKey = -1;
    if (contextChanged || !_hasCurrentIdx) {
      _hasCurrentIdx = true;
      _stableIdx = currentIdx;
      _jumpProtectionTimer?.cancel();
      _provisionalIdx = null;
    }
    _currentIdx = currentIdx;
    _applyWindow(protectJump: true);
  }

  void updateCurrentBufferedFrames(int frames) {
    if (_images.isEmpty) return;
    final window = DynamicPreloadPolicy.windowFor(
      currentBufferedFrames: frames,
      preloadCount: _preloadCount,
    );
    if (window.key == _windowKey) return;
    _currentBufferedFrames = frames;
    _applyWindow(protectJump: _provisionalIdx != null);
  }

  void _setCurrentIndex(int currentIdx) {
    if (!_hasCurrentIdx) {
      _hasCurrentIdx = true;
      _currentIdx = currentIdx;
      _stableIdx = currentIdx;
      _provisionalIdx = null;
      _applyWindow();
      return;
    }

    final previousIdx = _currentIdx;
    _currentIdx = currentIdx;
    final delta = currentIdx - previousIdx;
    final isJump = delta.abs() > _jumpProtectionDistance;

    _jumpProtectionTimer?.cancel();
    if (isJump) {
      _provisionalIdx = currentIdx;
      _applyWindow(protectJump: true);
      _jumpProtectionTimer = Timer(_jumpProtectionWindow, () {
        if (_provisionalIdx != _currentIdx) return;
        if (delta != 0) _readDirection = delta > 0 ? 1 : -1;
        _stableIdx = _currentIdx;
        _provisionalIdx = null;
        _applyWindow();
      });
      return;
    }

    if (delta != 0) _readDirection = delta > 0 ? 1 : -1;
    _stableIdx = currentIdx;
    _provisionalIdx = null;
    _applyWindow();
  }

  void _applyWindow({bool protectJump = false}) {
    String fk(int i) => (i >= 0 && i < _images.length) ? _images[i] : '';

    final window = DynamicPreloadPolicy.windowFor(
      currentBufferedFrames: _currentBufferedFrames,
      preloadCount: _preloadCount,
    );
    _windowKey = window.key;

    _currentKey = fk(_currentIdx);
    _nearKeys.clear();
    _prevKeys.clear();
    _farKeys.clear();
    _keepKeys.clear();
    _offsetByKey.clear();

    final offsets = DynamicPreloadPolicy.offsetsFor(
      preloadCount: _preloadCount,
      window: window,
      direction: _readDirection,
    );

    for (final offset in offsets.decodeNext) {
      final k = fk(_currentIdx + offset);
      if (k.isNotEmpty) {
        _nearKeys.add(k);
        _offsetByKey[k] = offset;
      }
    }
    for (final offset in offsets.decodePrev) {
      final k = fk(_currentIdx + offset);
      if (k.isNotEmpty) {
        _prevKeys.add(k);
        _offsetByKey[k] = offset;
      }
    }
    for (final offset in offsets.downloadOnly) {
      final k = fk(_currentIdx + offset);
      if (k.isNotEmpty) {
        _farKeys.add(k);
        _offsetByKey[k] = offset;
      }
    }
    for (final offset in offsets.keep) {
      final k = fk(_currentIdx + offset);
      if (k.isNotEmpty) {
        _keepKeys.add(k);
        _offsetByKey[k] = offset;
      }
    }
    if (_interaction == InteractionState.dragging) {
      final offset = _readDirection >= 0 ? 1 : -1;
      final k = fk(_currentIdx + offset);
      if (k.isNotEmpty) {
        if (offset > 0) {
          _nearKeys.add(k);
        } else {
          _prevKeys.add(k);
        }
        _farKeys.remove(k);
        _keepKeys.remove(k);
        _offsetByKey[k] = offset;
      }
    }
    if (_currentKey.isNotEmpty) _offsetByKey[_currentKey] = 0;
    if (protectJump) {
      _nearKeys.clear();
      _prevKeys.clear();
      _farKeys.clear();
      _keepKeys.clear();
      _offsetByKey
        ..clear()
        ..[_currentKey] = 0;
      final stableKey = fk(_stableIdx);
      if (stableKey.isNotEmpty && stableKey != _currentKey) {
        _keepKeys.add(stableKey);
        _offsetByKey[stableKey] = _stableIdx - _currentIdx;
      }
    }

    // Ensure entries exist
    String fullKey(String k) => _targetW > 0 ? '$k@${_targetW}x$_targetH' : k;
    for (final key in {
      _currentKey,
      ..._nearKeys,
      ..._prevKeys,
      ..._farKeys,
      ..._keepKeys,
    }) {
      if (key.isEmpty) continue;
      resources.ensure(
        imageKey: key,
        fullKey: fullKey(key),
        sourceKey: _sourceKey,
        cid: _cid,
        eid: _eid,
      );
    }

    _assignPriorities();
    _refreshPolicies();

    final activeImageKeys = <String>{
      _currentKey,
      ..._nearKeys,
      ..._prevKeys,
      ..._farKeys,
      ..._keepKeys,
    };

    // Mark distant entries before migrating/submitting work so stale
    // pages cannot submit one more task under their previous policy.
    resources.forEach((e) {
      if (!activeImageKeys.contains(e.imageKey)) {
        e.updatePriority(PagePriority.distant);
        e.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.distant),
        );
      }
    });

    // Migrate existing tasks
    final activeTaskKeys = <String>{};
    final newPriorities = <String, int>{};
    resources.forEach((e) {
      if (activeImageKeys.contains(e.imageKey)) {
        if (e.policy.allowDownload) {
          activeTaskKeys.add(e.imageKey);
        }
        if (e.policy.allowDecode) {
          activeTaskKeys.add(e.fullKey);
        }
      }
      if (e.policy.downloadPriority > 0) {
        newPriorities[e.imageKey] = _downloadRank(e);
      }
      if (e.policy.decodePriority > 0) {
        newPriorities[e.fullKey] = e.policy.decodePriority;
      }
    });
    _scheduler.migrateTasks(activeTaskKeys, newPriorities);

    onWindowChanged?.call(_currentKey, _nearKeys, _prevKeys, {
      ..._farKeys,
      ..._keepKeys,
    });

    // Submit work after holder ranges are published so newly created
    // holders immediately receive the correct current/near/far policy.
    _submitWork(_sourceKey, _cid, _eid);
  }

  void dispose() {
    _jumpProtectionTimer?.cancel();
    _jumpProtectionTimer = null;
    _scheduler.clear();
    resources.dispose();
  }

  // ── Internal: priorities & policies ────────────────────────

  void _assignPriorities() {
    final byKey = <String, ResourceEntry>{};
    resources.forEach((e) => byKey[e.imageKey] = e);

    byKey[_currentKey]?.updatePriority(PagePriority.current);
    for (final k in _nearKeys) {
      byKey[k]?.updatePriority(PagePriority.near);
    }
    for (final k in _prevKeys) {
      byKey[k]?.updatePriority(PagePriority.near);
    }
    for (final k in _farKeys) {
      byKey[k]?.updatePriority(PagePriority.far);
    }
    for (final k in _keepKeys) {
      byKey[k]?.updatePriority(PagePriority.keep);
    }
  }

  void _refreshPolicies() {
    final byKey = <String, ResourceEntry>{};
    resources.forEach((e) => byKey[e.imageKey] = e);

    final current = byKey[_currentKey];
    if (current != null) {
      current.updatePolicy(_rankedPolicy(current, PagePriority.current));
    }
    for (final k in _nearKeys) {
      final entry = byKey[k];
      if (entry != null) {
        entry.updatePolicy(_rankedPolicy(entry, PagePriority.near));
      }
    }
    for (final k in _prevKeys) {
      final entry = byKey[k];
      if (entry != null) {
        entry.updatePolicy(_rankedPolicy(entry, PagePriority.near));
      }
    }
    for (final k in _farKeys) {
      final entry = byKey[k];
      if (entry != null) {
        entry.updatePolicy(_rankedPolicy(entry, PagePriority.far));
      }
    }
    for (final k in _keepKeys) {
      final entry = byKey[k];
      if (entry != null) {
        entry.updatePolicy(_rankedPolicy(entry, PagePriority.keep));
      }
    }
  }

  ResourcePolicy _rankedPolicy(ResourceEntry entry, PagePriority priority) {
    final base = ResourcePolicy.compute(_interaction, priority);
    if (!base.allowDownload) return base;
    return base.withDownloadPriority(_downloadRank(entry, priority: priority));
  }

  int _downloadRank(ResourceEntry entry, {PagePriority? priority}) {
    final p = priority ?? entry.priority;
    final offset = _offsetByKey[entry.imageKey] ?? 1 << 20;
    final distance = offset.abs();
    final progressBoost = (entry.download.progress * 20).round();

    final base = switch (p) {
      PagePriority.current => 1000,
      PagePriority.near when offset > 0 => 760,
      PagePriority.near => 720,
      PagePriority.far when offset > 0 => 520,
      PagePriority.far => 500,
      PagePriority.keep => 260,
      PagePriority.distant => 0,
    };

    if (base == 0) return 0;
    final directionBias = offset < 0 ? -8 : 0;
    return base - distance * 12 + directionBias + progressBoost;
  }

  // ── Internal: work submission (split by stage) ──────────────

  void _submitWork(String? sourceKey, String cid, String eid) {
    resources.forEach((entry) => _evaluateEntry(entry, sourceKey, cid, eid));
  }

  void _evaluateEntry(
    ResourceEntry entry,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    _submitDownload(entry, sourceKey, cid, eid);
    _submitDecode(entry, sourceKey, cid, eid);
    _submitEviction(entry);
  }

  void _submitDownload(
    ResourceEntry entry,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    if (!entry.policy.allowDownload) return;
    if (entry.hasBytes) return;
    final l2Bytes = _cache?.getL2(entry.imageKey);
    if (l2Bytes != null) {
      _publishBytes(entry.imageKey, l2Bytes);
      return;
    }
    for (final peer in resources.getAllForImage(entry.imageKey)) {
      if (peer.bytes != null) {
        _publishBytes(entry.imageKey, peer.bytes!);
        return;
      }
    }
    if (entry.download.inProgress) return;
    if (_prefetchBudgetExceededFor(entry)) return;

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
      onProgress: (current, total) {
        for (final peer in resources.getAllForImage(entry.imageKey)) {
          peer.download.updateProgress(current, total);
        }
      },
    );
    task
        .register()
        .then((bytes) {
          _publishBytes(entry.imageKey, bytes);
          if (_cache != null && webp.isWebP(bytes)) {
            _cache!.putL2(entry.imageKey, bytes);
          }
          // Cascade: bytes ready → maybe decode
          for (final peer in resources.getAllForImage(entry.imageKey)) {
            _submitDecode(peer, sourceKey, cid, eid);
          }
        })
        .catchError((_) {
          entry.download.inProgress = false;
        });
    task.setContext(ExecutionContext(entry));
    _scheduler.submit(task);
  }

  void _submitDecode(
    ResourceEntry entry,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    if (!entry.policy.allowDecode) return;
    if (entry.hasHolder) return;
    if (!entry.hasBytes) return;
    if (entry.decode.inProgress) return;
    if (entry.decode.isInBackoff) return;

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
      cache: _cache,
      providedBytes: entry.bytes,
    );
    task
        .register()
        .then((holder) {
          if (holder == null) {
            entry.decode.markFailure('No animated WebP holder created');
            return;
          }
          entry.holder = holder;
          entry.decode.markSuccess();
        })
        .catchError((e) {
          entry.decode.markFailure(e);
        });
    task.setContext(ExecutionContext(entry));
    _scheduler.submit(task);
  }

  void _submitEviction(ResourceEntry entry) {
    if (!entry.policy.allowEviction) return;
    if (!entry.hasBytes && !entry.hasHolder) return;
    resources.release(entry);
  }

  void _publishBytes(String imageKey, Uint8List bytes) {
    for (final peer in resources.getAllForImage(imageKey)) {
      peer.bytes = bytes;
      peer.download.inProgress = false;
      peer.download.lastError = null;
    }
  }

  bool _prefetchBudgetExceededFor(ResourceEntry entry) {
    if (entry.priority == PagePriority.current ||
        entry.priority == PagePriority.near) {
      return false;
    }
    final knownSize = entry.bytes?.length ?? entry.download.totalBytes;
    final budget = _prefetchBudgetBytes;
    if (knownSize != null && knownSize >= budget ~/ 2) {
      return _currentPrefetchBytes(excluding: entry.imageKey) > 0;
    }
    return _currentPrefetchBytes() >= budget;
  }

  int _currentPrefetchBytes({String? excluding}) {
    var total = 0;
    resources.forEach((entry) {
      if (entry.imageKey == excluding) return;
      if (entry.priority == PagePriority.current ||
          entry.priority == PagePriority.near) {
        return;
      }
      total +=
          entry.bytes?.length ??
          entry.download.totalBytes ??
          (entry.download.inProgress ? _unknownPrefetchBytes : 0);
    });
    return total;
  }

  int get _prefetchBudgetBytes {
    if (Platform.isAndroid || Platform.isIOS) return _mobilePrefetchBudgetBytes;
    return _desktopPrefetchBudgetBytes;
  }

  int get _unknownPrefetchBytes {
    if (Platform.isAndroid || Platform.isIOS) {
      return _mobileUnknownPrefetchBytes;
    }
    return _desktopUnknownPrefetchBytes;
  }
}
