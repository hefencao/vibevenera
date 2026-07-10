import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/image_provider/cache/decoded_image_cache.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/foundation/image_provider/session/webp_decode_session.dart';
import 'package:venera/foundation/image_provider/session/webp_session_coordinator.dart';
import 'package:venera/network/webp_download_transport.dart';

import 'download_progress_publisher.dart';
import 'download_ranker.dart';
import 'pipeline_policy_applier.dart';
import 'pipeline_window.dart';
import 'preload_policy.dart';
import 'resource_entry.dart';
import 'resource_manager.dart';
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

// ═══════════════════════════════════════════════════════════════
// PipelineController
// ═══════════════════════════════════════════════════════════════

class PipelineController {
  static final PipelineController instance = PipelineController._();
  PipelineController._() {
    _sessions = WebPSessionCoordinator(
      scheduler: _scheduler,
      transportFactory: (identity) => ImageDownloaderWebPTransport(identity),
      onProgress: _onSessionProgress,
    );
  }

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
  late final WebPSessionCoordinator _sessions;
  final Map<String, WebPResourceLease> _policyLeases = {};

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
    if (_targetW == w && _targetH == h) return;
    _targetW = w;
    _targetH = h;
    if (_images.isEmpty) return;

    // ResourceEntry is only a policy projection, but its fullKey includes the
    // decode size. Drop that projection on rotation/viewport changes so one
    // image cannot accidentally receive policy through two size entries.
    _detachPolicyScope();
    _sessionId++;
    resources.clear();
    _windowKey = -1;
    _windowRuleIndex = -1;
  }

  InteractionState get interactionState => _interaction;

  void setInteractionState(InteractionState state) {
    if (_interaction == state) return;
    _interaction = state;
    if (_images.isEmpty) {
      _applyPolicies(markDistant: false);
      _syncPolicyLeases();
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
        !identical(_images, images) ||
        _cid != cid ||
        _eid != eid ||
        _sourceKey != sourceKey;
    if (contextChanged && _images.isNotEmpty) {
      _detachPolicyScope();
      _sessionId++;
    }
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
        !identical(_images, images) ||
        _cid != cid ||
        _eid != eid ||
        _sourceKey != sourceKey;
    if (contextChanged && _images.isNotEmpty) {
      _detachPolicyScope();
      _sessionId++;
    }
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
    final previousCurrent = _currentKey;
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
    if (_currentKey != previousCurrent) {
      Log.info(
        'WebP.Pipeline.Flow',
        'CURRENT ${_flowKey(previousCurrent)} -> ${_flowKey(_currentKey)}',
      );
    }

    // Ensure entries exist
    String fullKey(String k) => _targetW > 0 || _targetH > 0
        ? '$k@${_targetW}x$_targetH'
        : k;
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

    _applyPolicies();
    _syncPolicyLeases();

    onWindowChanged?.call(_currentKey, _nearKeys, _prevKeys, {
      ..._farKeys,
      ..._keepKeys,
    });
  }

  void dispose() {
    _jumpProtectionTimer?.cancel();
    _jumpProtectionTimer = null;
    _detachPolicyScope();
    _sessionId++;
    _progress.reset();
    _sessions.dispose();
    _scheduler.clear();
    resources.dispose();
  }

  void detachReaderSession() {
    _detachPolicyScope();
    _sessionId++;
    _jumpProtectionTimer?.cancel();
    _jumpProtectionTimer = null;
    _provisionalIdx = null;
    onWindowChanged = null;
    _progress.reset();
    // Logical detach only. Native sources and decode sessions survive while
    // visible or other policy leases still reference them.
    resources.clear();
    _images = const [];
    _currentKey = '';
    _nearKeys.clear();
    _prevKeys.clear();
    _farKeys.clear();
    _keepKeys.clear();
    _offsetByKey.clear();
  }

  /// Temporary compatibility projection for legacy callers. The session
  /// pipeline does not consume these values and remains the sole authority.
  void publishExternalHolder(String imageKey, String fullKey, dynamic holder) {
    for (final peer in resources.getAllForImage(imageKey)) {
      if (peer.fullKey == fullKey) {
        peer.holder = holder;
        peer.decode.markSuccess();
      }
    }
  }

  void publishExternalBytes(String imageKey, Uint8List bytes) {
    for (final peer in resources.getAllForImage(imageKey)) {
      peer.bytes = bytes;
    }
  }

  void publishExternalDownloadProgress(
    String imageKey,
    int current,
    int? total, {
    bool done = false,
  }) {
    for (final peer in resources.getAllForImage(imageKey)) {
      peer.download.updateProgress(current, total);
      peer.download.inProgress = !done;
    }
    _progress.update(
      imageKey,
      current,
      total,
      currentKey: _currentKey,
      done: done,
    );
  }

  bool hasStreamDecodeAttached(String fullKey) => false;

  bool isManagingFullKey(String fullKey) => resources.get(fullKey) != null;

  Future<dynamic> waitForStreamResult(String fullKey) => Future.value(null);

  void ensureStreamWork(String fullKey) => _syncPolicyLeases();

  WebPResourceLease acquireVisibleWebP({
    required String imageKey,
    required String? sourceKey,
    required String cid,
    required String eid,
    required String fullKey,
    required int targetWidth,
    required int targetHeight,
    required String scopeId,
  }) {
    return _sessions.acquire(
      downloadIdentity: DownloadIdentity(
        imageKey: imageKey,
        sourceKey: sourceKey,
        cid: cid,
        eid: eid,
      ),
      decodeIdentity: WebPDecodeIdentity(
        fullKey: fullKey,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      ),
      scopeId: scopeId,
      // The ImageStream is a display subscriber, not the page-policy owner.
      // Current/near promotion comes from _syncPolicyLeases; this baseline
      // demand requests frame production but never starts or retains transport.
      demand: const WebPResourceDemand(
        downloadPriority: 0,
        decodePriority: 60,
        allowDownload: false,
        allowDecode: true,
        allowUpload: true,
        current: false,
      ),
    );
  }

  void evictUndemandedSessions() => _sessions.evictUndemanded();

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

  String get _policyScopeId => 'reader:$_sessionId';

  void _syncPolicyLeases() {
    final liveFullKeys = <String>{};
    resources.forEach((entry) {
      final policy = entry.policy;
      final demanded = policy.allowDownload ||
          policy.allowDecode ||
          policy.allowGpuUpload;
      final downloadIdentity = DownloadIdentity(
        imageKey: entry.imageKey,
        sourceKey: entry.sourceKey,
        cid: entry.cid,
        eid: entry.eid,
      );
      final decodeIdentity = WebPDecodeIdentity(
        fullKey: entry.fullKey,
        targetWidth: _targetW,
        targetHeight: _targetH,
      );

      if (!demanded) {
        _policyLeases.remove(entry.fullKey)?.detach();
        if (policy.allowEviction) {
          _sessions.tryEvict(decodeIdentity, downloadIdentity);
        }
        return;
      }

      liveFullKeys.add(entry.fullKey);
      final demand = WebPResourceDemand(
        downloadPriority: policy.allowDownload ? _downloadRank(entry) : 0,
        decodePriority: policy.decodePriority,
        allowDownload: policy.allowDownload,
        allowDecode: policy.allowDecode,
        allowUpload: policy.allowGpuUpload,
        current: entry.priority == PagePriority.current,
      );

      var lease = _policyLeases[entry.fullKey];
      final identityChanged = lease != null &&
          (lease.download.identity != downloadIdentity ||
              lease.decode.identity != decodeIdentity);
      if (identityChanged) {
        lease.detach();
        _policyLeases.remove(entry.fullKey);
        lease = null;
      }

      if (lease == null) {
        lease = _sessions.acquire(
          downloadIdentity: downloadIdentity,
          decodeIdentity: decodeIdentity,
          scopeId: _policyScopeId,
          demand: demand,
        );
        _policyLeases[entry.fullKey] = lease;
      } else {
        lease.update(demand);
      }
    });

    for (final fullKey in _policyLeases.keys.toList()) {
      if (liveFullKeys.contains(fullKey)) continue;
      _policyLeases.remove(fullKey)?.detach();
    }
  }

  void _detachPolicyScope() {
    for (final lease in _policyLeases.values.toList()) {
      lease.detach();
    }
    _policyLeases.clear();
    _sessions.detachScope(_policyScopeId);
  }

  void _onSessionProgress(
    DownloadIdentity identity,
    WebPTransportProgress progress,
  ) {
    for (final entry in resources.getAllForImage(identity.imageKey)) {
      entry.download.updateProgress(
        progress.currentBytes,
        progress.totalBytes,
      );
      entry.download.inProgress = !progress.done;
      if (progress.done) entry.download.lastError = null;
    }
    _progress.update(
      identity.imageKey,
      progress.currentBytes,
      progress.totalBytes,
      currentKey: _currentKey,
      done: progress.done,
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

  static String _flowKey(String key) => key.isEmpty ? '-' : key.split('/').last;

}
