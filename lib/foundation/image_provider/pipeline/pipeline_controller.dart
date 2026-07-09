import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/image_provider/cache/decoded_image_cache.dart';

import 'download_progress_publisher.dart';
import 'download_ranker.dart';
import 'pipeline_policy_applier.dart';
import 'pipeline_window.dart';
import 'preload_policy.dart';
import 'pipeline_work_submitter.dart';
import 'resource_entry.dart';
import 'resource_manager.dart';
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
  final PipelineWindowPlanner _windowPlanner = const PipelineWindowPlanner();
  final PipelinePolicyApplier _policyApplier = const PipelinePolicyApplier();

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
  int _sessionId = 0;
  int? _provisionalIdx;
  Timer? _jumpProtectionTimer;
  List<String> _images = const [];
  String? _sourceKey;
  String _cid = '';
  String _eid = '';
  final WebPStreamDecodeCoordinator _streamDecodes =
      WebPStreamDecodeCoordinator();
  late final PipelineWorkSubmitter _workSubmitter = PipelineWorkSubmitter(
    resources: resources,
    scheduler: _scheduler,
    streamDecodes: _streamDecodes,
    progress: _progress,
    currentKey: () => _currentKey,
    isSessionActive: (session) => session == _sessionId,
  );

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
      _applyPolicies(markDistant: false);
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
    final plan = _windowPlanner.build(
      currentIdx: _currentIdx,
      stableIdx: _stableIdx,
      images: _images,
      currentBufferedFrames: _currentBufferedFrames,
      preloadCount: _preloadCount,
      existingRuleIndex: _windowRuleIndex,
      readDirection: _readDirection,
      interaction: _interaction,
      protectJump: protectJump,
    );
    _windowRuleIndex = plan.ruleIndex;
    _windowKey = plan.windowKey;
    _currentKey = plan.currentKey;
    _nearKeys
      ..clear()
      ..addAll(plan.nearKeys);
    _prevKeys
      ..clear()
      ..addAll(plan.prevKeys);
    _farKeys
      ..clear()
      ..addAll(plan.farKeys);
    _keepKeys
      ..clear()
      ..addAll(plan.keepKeys);
    _offsetByKey
      ..clear()
      ..addAll(plan.offsetByKey);

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

    final activeImageKeys = _applyPolicies();
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
    _workSubmitter.submit(
      sourceKey: _sourceKey,
      cid: _cid,
      eid: _eid,
      targetWidth: _targetW,
      targetHeight: _targetH,
      cache: _cache,
      session: _sessionId,
    );
    _workSubmitter.syncCurrentDownloadProgress();
  }

  void dispose() {
    _jumpProtectionTimer?.cancel();
    _jumpProtectionTimer = null;
    _sessionId++;
    _progress.reset();
    _streamDecodes.clear();
    _scheduler.clear();
    resources.dispose();
  }

  void detachReaderSession() {
    _sessionId++;
    _jumpProtectionTimer?.cancel();
    _jumpProtectionTimer = null;
    _provisionalIdx = null;
    onWindowChanged = null;
    _progress.reset();
    _streamDecodes.clear();
    _scheduler.migrateTasks(const <String>{}, const <String, int>{});
    resources.clear();
    _images = const [];
    _cache = null;
    _currentKey = '';
    _nearKeys.clear();
    _prevKeys.clear();
    _farKeys.clear();
    _keepKeys.clear();
    _offsetByKey.clear();
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
    _workSubmitter.publishBytes(imageKey, bytes);
  }

  void publishExternalDownloadProgress(
    String imageKey,
    int current,
    int? total, {
    bool done = false,
  }) {
    _workSubmitter.publishDownloadProgress(
      imageKey,
      current,
      total,
      done: done,
    );
  }

  bool hasStreamDecodeAttached(String fullKey) =>
      _streamDecodes.hasAttached(fullKey);

  // ── Internal: priorities & policies ────────────────────────

  Set<String> _applyPolicies({bool markDistant = true}) {
    return _policyApplier.apply(
      resources: resources,
      interaction: _interaction,
      currentKey: _currentKey,
      nearKeys: _nearKeys,
      prevKeys: _prevKeys,
      farKeys: _farKeys,
      keepKeys: _keepKeys,
      downloadRank: (entry, priority) => _downloadRank(
        entry,
        priority: priority,
      ),
      markDistant: markDistant,
    );
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

}
