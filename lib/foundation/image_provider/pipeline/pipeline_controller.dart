import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/image_provider/cache/decoded_image_cache.dart';
import 'package:venera/foundation/image_provider/webp_image_provider.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'download_progress_publisher.dart';
import 'download_ranker.dart';
import 'preload_policy.dart';
import 'prefetch_budget.dart';
import 'resource_entry.dart';
import 'resource_manager.dart';
import 'tasks.dart';
import 'task_scheduler.dart';
import 'webp_stream_decode_coordinator.dart';

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

// ═══════════════════════════════════════════════════════════════
// PipelineController
// ═══════════════════════════════════════════════════════════════

class PipelineController {
  static final PipelineController instance = PipelineController._();
  PipelineController._();

  final ResourceManager resources = ResourceManager();
  final TaskScheduler _scheduler = TaskScheduler.instance;
  final DownloadProgressPublisher _progress = DownloadProgressPublisher();
  ValueNotifier<ReaderDownloadProgress> get currentDownloadProgress =>
      _progress.notifier;
  final PrefetchBudget _prefetchBudget = const PrefetchBudget();

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
  int _windowRuleIndex = -1;
  int? _provisionalIdx;
  Timer? _jumpProtectionTimer;
  List<String> _images = const [];
  String? _sourceKey;
  String _cid = '';
  String _eid = '';
  final WebPStreamDecodeCoordinator _streamDecodes =
      WebPStreamDecodeCoordinator();

  String _currentKey = '';
  final Set<String> _nearKeys = {};
  final Set<String> _prevKeys = {};
  final Set<String> _farKeys = {};
  final Set<String> _keepKeys = {};
  final Map<String, int> _offsetByKey = {};

  static const int _jumpProtectionDistance = 3;
  static const Duration _jumpProtectionWindow = Duration(milliseconds: 1200);

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
    _windowRuleIndex = -1;
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
    _windowRuleIndex = -1;
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
    final nextRule = DynamicPreloadPolicy.ruleIndexFor(
      currentBufferedFrames: frames,
      preloadCount: _preloadCount,
    );
    if (_windowRuleIndex >= 0 && nextRule > _windowRuleIndex) {
      final min = waterLevelRules[_windowRuleIndex].minBufferedFrames;
      if (frames >= (min - 2).clamp(0, min)) {
        _currentBufferedFrames = frames;
        return;
      }
    }
    final window = DynamicPreloadPolicy.windowAt(nextRule);
    if (window.key == _windowKey) {
      _currentBufferedFrames = frames;
      return;
    }
    _currentBufferedFrames = frames;
    _windowRuleIndex = nextRule;
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

    if (_windowRuleIndex < 0) {
      _windowRuleIndex = DynamicPreloadPolicy.ruleIndexFor(
        currentBufferedFrames: _currentBufferedFrames,
        preloadCount: _preloadCount,
      );
    }
    final window = DynamicPreloadPolicy.windowAt(_windowRuleIndex);
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
      final stableKey = fk(_stableIdx);
      if (stableKey.isNotEmpty && stableKey != _currentKey) {
        _nearKeys.remove(stableKey);
        _prevKeys.remove(stableKey);
        _farKeys.remove(stableKey);
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
    _streamDecodes.detachInactive(activeImageKeys, resources);

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
      if (e.policy.downloadPriority > 0 || e.download.inProgress) {
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
    _syncCurrentDownloadProgress();
  }

  void dispose() {
    _jumpProtectionTimer?.cancel();
    _jumpProtectionTimer = null;
    _progress.reset();
    _scheduler.clear();
    resources.dispose();
  }

  void publishExternalHolder(String imageKey, String fullKey, dynamic holder) {
    for (final peer in resources.getAllForImage(imageKey)) {
      if (peer.fullKey == fullKey) {
        peer.holder = holder;
        peer.decode.markSuccess();
      }
    }
  }

  void publishExternalBytes(String imageKey, Uint8List bytes) {
    _publishBytes(imageKey, bytes);
  }

  void publishExternalDownloadProgress(
    String imageKey,
    int current,
    int? total, {
    bool done = false,
  }) {
    _publishDownloadProgress(imageKey, current, total, done: done);
  }

  bool hasStreamDecodeAttached(String fullKey) =>
      _streamDecodes.hasAttached(fullKey);

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
    return DownloadRanker(
      runningDownloads: _scheduler.runningDownloadCount,
      queuedDownloads: _scheduler.queuedDownloadCount,
      maxConcurrent: _scheduler.maxConcurrent,
      offsetFor: (key) => _offsetByKey[key] ?? _offsetFor(key),
    ).rank(entry, priority: priority);
  }

  int _offsetFor(String imageKey) {
    final idx = _images.indexOf(imageKey);
    return idx < 0 ? 1 << 20 : idx - _currentIdx;
  }

  // ── Internal: work submission (split by stage) ──────────────

  void _submitWork(String? sourceKey, String cid, String eid) {
    final entries = <ResourceEntry>[];
    resources.forEach(entries.add);
    entries.sort((a, b) => _entrySubmitRank(b).compareTo(_entrySubmitRank(a)));
    for (final entry in entries) {
      _evaluateEntry(entry, sourceKey, cid, eid);
    }
  }

  int _entrySubmitRank(ResourceEntry entry) {
    final d = entry.policy.downloadPriority;
    final p = entry.policy.decodePriority;
    return d > p ? d : p;
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
    if (entry.priority == PagePriority.current) {
      debugPrint(
        '[WebP-Stream][pipeline] download-eval key=${entry.imageKey} '
        'hasBytes=${entry.hasBytes} inProgress=${entry.download.inProgress} '
        'allowD=${entry.policy.allowDownload} allowDecode=${entry.policy.allowDecode}',
      );
    }
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
    if (entry.download.inProgress) {
      final attached = _streamDecodes.attachToRunningDownload(
        entry,
        sourceKey,
        cid,
        eid,
        resources: resources,
        targetWidth: _targetW,
        targetHeight: _targetH,
      );
      if (attached ||
          _scheduler.hasTask(entry.imageKey) ||
          _streamDecodes.isDownloadLoading(
            entry.imageKey,
            sourceKey,
            cid,
            eid,
          )) {
        return;
      }
      debugPrint('[WebP-Stream][pipeline] STALE-DOWNLOAD ${entry.imageKey}');
      entry.download.inProgress = false;
      _streamDecodes.markDownloadStale(entry);
    }
    if (_prefetchBudgetExceededFor(entry)) return;

    entry.download.inProgress = true;
    final streamDecode = _streamDecodes.start(
      entry,
      resources: resources,
      targetWidth: _targetW,
      targetHeight: _targetH,
    );
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
        _publishDownloadProgress(entry.imageKey, current, total);
      },
      onEvent: streamDecode?.onEvent,
      onDispose: streamDecode?.dispose,
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
          _streamDecodes.detach(entry.fullKey);
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
    if (entry.priority == PagePriority.current) {
      debugPrint(
        '[WebP-Stream][pipeline] decode-eval key=${entry.imageKey} '
        'hasBytes=${entry.hasBytes} hasHolder=${entry.hasHolder} '
        'inProgress=${entry.decode.inProgress} allow=${entry.policy.allowDecode}',
      );
    }
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
      holderFactory: WebPImageProvider.ensureHolder,
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
    _progress.complete(imageKey, _currentKey);
  }

  void _publishDownloadProgress(
    String imageKey,
    int current,
    int? total, {
    bool done = false,
  }) {
    for (final peer in resources.getAllForImage(imageKey)) {
      peer.download.updateProgress(current, total);
    }
    _progress.update(
      imageKey,
      current,
      total,
      currentKey: _currentKey,
      done: done,
    );
  }

  void _syncCurrentDownloadProgress() {
    _progress.syncCurrent(_currentKey, resources.get(_currentKey));
  }

  bool _prefetchBudgetExceededFor(ResourceEntry entry) {
    return _prefetchBudget.exceededFor(entry, resources);
  }
}
