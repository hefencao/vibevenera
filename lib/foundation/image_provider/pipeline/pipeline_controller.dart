import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/cache/decoded_image_cache.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/image_pipeline_perf.dart';
import 'package:venera/foundation/image_provider/renderer/frame_renderer.dart';
import 'package:venera/foundation/image_provider/renderer/webp_texture_channel.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/foundation/image_provider/session/webp_decode_session.dart';
import 'package:venera/foundation/image_provider/session/streaming_session_coordinator.dart';
import 'package:venera/foundation/image_provider/streaming_source_registry.dart';
import 'package:venera/network/streaming_image_transport.dart';

import 'download_progress_publisher.dart';
import 'cache_download_progress_publisher.dart';
import 'download_ranker.dart';
import 'pipeline_policy_applier.dart';
import 'pipeline_window.dart';
import 'preload_policy.dart';
import 'reading_direction_predictor.dart';
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

final class ReaderPipelineSession {
  final Object owner;
  final List<String> images;
  final String cid;
  final String eid;
  final String? sourceKey;
  final DecodedImageCache? cache;
  final int targetWidth;
  final int targetHeight;
  final int preloadCount;

  const ReaderPipelineSession({
    required this.owner,
    required this.images,
    required this.cid,
    required this.eid,
    required this.sourceKey,
    required this.cache,
    required this.targetWidth,
    required this.targetHeight,
    required this.preloadCount,
  });
}

class PipelineController {
  static final PipelineController instance = PipelineController._();
  PipelineController._() {
    _sessions = StreamingSessionCoordinator(
      scheduler: _scheduler,
      transportFactory: (identity) =>
          ImageDownloaderStreamingTransport(identity),
      onProgress: _onSessionProgress,
      onDownloadSession: _cacheDownloads.observe,
      // Android 用 native texture 渲染动图帧：解码产出的 native RGBA 帧不转
      // ui.Image，而是交给显示层按播放节奏上传平台纹理，消除每帧 ui.Image 分配 +
      // setState 对主 isolate 的饱和。其它平台仍用 FlutterImageRenderer。
      renderer: WebPTextureChannel.instance.isSupported
          ? const NativeTextureRenderer(AndroidWebPTextureBackend())
          : const FlutterImageRenderer(),
    );
  }

  final ResourceManager resources = ResourceManager();
  final TaskScheduler _scheduler = TaskScheduler.instance;
  final DownloadProgressPublisher _progress = DownloadProgressPublisher();
  final CacheDownloadProgressPublisher _cacheDownloads =
      CacheDownloadProgressPublisher();
  ValueNotifier<ReaderDownloadProgress> get currentDownloadProgress =>
      _progress.notifier;
  ValueListenable<List<CacheDownloadProgress>> get cacheDownloadProgress =>
      _cacheDownloads.notifier;
  final PipelineWindowPlanner _windowPlanner = const PipelineWindowPlanner();
  final PipelinePolicyApplier _policyApplier = const PipelinePolicyApplier();

  InteractionState _interaction = InteractionState.idle;
  int _targetW = 0, _targetH = 0;
  int _currentIdx = 0;
  int _stableIdx = 0;
  int _readDirection = 1;
  final ReadingDirectionPredictor _directionPredictor =
      ReadingDirectionPredictor();
  bool _hasCurrentIdx = false;
  int _preloadCount = 5;
  int _currentBufferedFrames = 0;
  bool _currentUsesExternalCodec = false;
  int _windowRuleIndex = -1;
  int _sessionId = 0;
  int? _provisionalIdx;
  Timer? _jumpProtectionTimer;
  Timer? _dragCommitTimer;
  List<String> _images = const [];
  String? _sourceKey;
  String _cid = '';
  String _eid = '';
  DecodedImageCache? _cache;
  late final StreamingSessionCoordinator _sessions;
  final Map<String, StreamingResourceLease> _policyLeases = {};
  Map<String, CacheAliasTarget> _sessionAliases = const {};
  Object? _readerOwner;

  String _currentKey = '';
  final Set<String> _nearKeys = {};
  final Set<String> _prevKeys = {};
  final Set<String> _farKeys = {};
  final Set<String> _keepKeys = {};
  final Map<String, int> _offsetByKey = {};

  static const int _jumpProtectionDistance = 3;
  static const Duration _jumpProtectionWindow = Duration(milliseconds: 1200);

  // ── Public API ──────────────────────────────────────────────

  void attachReaderSession(ReaderPipelineSession session) {
    _syncNetworkConcurrency();
    if (_isLocalStaticSession(session)) {
      _readerOwner = session.owner;
      detachReaderSession(session.owner);
      return;
    }
    setTargetSize(session.targetWidth, session.targetHeight);
    final contextChanged =
        !identical(_readerOwner, session.owner) ||
        !_sameImages(_images, session.images) ||
        _cid != session.cid ||
        _eid != session.eid ||
        _sourceKey != session.sourceKey;
    if (contextChanged && _images.isNotEmpty) {
      _detachPolicyScope();
      _sessionId++;
    }
    _readerOwner = session.owner;
    if (contextChanged) _images = List<String>.unmodifiable(session.images);
    _cid = session.cid;
    _eid = session.eid;
    _sourceKey = session.sourceKey;
    _cache = session.cache;
    if (contextChanged) {
      _sessionAliases = {
        for (final imageKey in _images)
          if (CacheManager().resolveImageAlias(
                imageKey,
                _sourceKey,
                _cid,
                _eid,
              )
              case final alias?)
            imageKey: alias,
      };
    }
    if (_preloadCount != session.preloadCount || contextChanged) {
      _currentBufferedFrames = 0;
      _currentUsesExternalCodec = false;
      _windowRuleIndex = -1;
    }
    _preloadCount = session.preloadCount;
    if (contextChanged) {
      _hasCurrentIdx = false;
      _directionPredictor.reset(
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      _readDirection = _directionPredictor.direction;
      _jumpProtectionTimer?.cancel();
      _provisionalIdx = null;
    }
  }

  void onReaderPageChanged(Object owner, int currentIdx) {
    if (!identical(_readerOwner, owner)) return;
    _syncNetworkConcurrency();
    if (_images.isEmpty) return;
    if (_interaction != InteractionState.scroll) {
      _setCurrentIndex(currentIdx);
      return;
    }
    if (!_hasCurrentIdx) {
      _hasCurrentIdx = true;
      _stableIdx = currentIdx;
      _jumpProtectionTimer?.cancel();
      _provisionalIdx = null;
    }
    _currentIdx = currentIdx;
    _readDirection = _directionPredictor.record(
      0,
      DateTime.now().millisecondsSinceEpoch,
      directional: false,
    );
    _scheduleDragCommit();
  }

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
    _windowRuleIndex = -1;
  }

  InteractionState get interactionState => _interaction;

  void setInteractionState(InteractionState state) {
    if (_interaction == state) return;
    _interaction = state;
    if (state != InteractionState.scroll) {
      _dragCommitTimer?.cancel();
      _dragCommitTimer = null;
    }
    if (_images.isEmpty) {
      _applyPolicies(markDistant: false);
      _syncPolicyLeases();
    } else {
      _applyWindow(protectJump: _provisionalIdx != null);
    }
  }

  bool _isLocalStaticSession(ReaderPipelineSession session) =>
      session.images.isNotEmpty &&
      session.images.every((key) => key.startsWith('file://') || !key.contains('://')) &&
      !session.images.any((key) {
        final lower = key.toLowerCase();
        return lower.contains('.webp') || lower.contains('.gif');
      }) &&
      !StreamingSourceRegistry.isStreamingSource(session.sourceKey);

  void _syncNetworkConcurrency() {
    final value = appdata.settings['downloadThreads'];
    _scheduler.setNetworkConcurrency(value is int ? value : 5);
  }

  static const Duration _dragCommitDelay = Duration(milliseconds: 180);

  void _scheduleDragCommit() {
    _dragCommitTimer?.cancel();
    _dragCommitTimer = Timer(_dragCommitDelay, () {
      _dragCommitTimer = null;
      if (_images.isEmpty) return;
      _applyWindow(protectJump: true);
    });
  }

  void updateCurrentBufferedFrames(int frames) {
    final modeChanged = _currentUsesExternalCodec;
    _currentUsesExternalCodec = false;
    _updateCurrentBufferedFrames(frames, forcePolicySync: modeChanged);
  }

  void updateCurrentExternalCodec({required bool ready}) {
    final modeChanged = !_currentUsesExternalCodec;
    _currentUsesExternalCodec = true;
    _updateCurrentBufferedFrames(
      ready ? 7 : 0,
      forcePolicySync: modeChanged,
    );
  }

  void _updateCurrentBufferedFrames(
    int frames, {
    bool forcePolicySync = false,
  }) {
    if (_images.isEmpty) return;
    _currentBufferedFrames = frames;
    final nextRule = DynamicPreloadPolicy.ruleIndexFor(
      currentBufferedFrames: frames,
      preloadCount: _preloadCount,
    );
    if (nextRule == _windowRuleIndex) {
      if (forcePolicySync) _syncPolicyLeases();
      return;
    }
    // 档位向浅(nextRule 更大 = 缓冲下降)时加滞回，避免缓冲在阈值附近呼吸导致档位
    // 抖动。向深(缓冲回升)立即生效，尽快让近邻页恢复较深目标。
    if (_windowRuleIndex >= 0 && nextRule > _windowRuleIndex) {
      final min = waterLevelRules[_windowRuleIndex].minBufferedFrames;
      if (frames >= (min - 2).clamp(0, min)) {
        if (forcePolicySync) _syncPolicyLeases();
        return;
      }
    }
    _windowRuleIndex = nextRule;
    // 页集合固定不变（stableWindow），ruleIndex 只影响每页目标帧深。所以这里只需
    // 轻量重算 lease 需求(刷新 targetFrames)，不重建窗口页集合——消除 churn。
    _syncPolicyLeases();
  }

  void _setCurrentIndex(int currentIdx) {
    if (!_hasCurrentIdx) {
      _hasCurrentIdx = true;
      _currentIdx = currentIdx;
      _stableIdx = currentIdx;
      _readDirection = _directionPredictor.record(
        0,
        DateTime.now().millisecondsSinceEpoch,
        directional: false,
      );
      _provisionalIdx = null;
      _applyWindow();
      return;
    }

    final previousIdx = _currentIdx;
    _currentIdx = currentIdx;
    _currentUsesExternalCodec = false;
    final delta = currentIdx - previousIdx;
    final isJump = delta.abs() > _jumpProtectionDistance;
    _readDirection = _directionPredictor.record(
      delta,
      DateTime.now().millisecondsSinceEpoch,
      directional: !isJump && _interaction != InteractionState.jumping,
    );

    _jumpProtectionTimer?.cancel();
    if (isJump) {
      _provisionalIdx = currentIdx;
      _applyWindow(protectJump: true);
      _jumpProtectionTimer = Timer(_jumpProtectionWindow, () {
        if (_provisionalIdx != _currentIdx) return;
        _stableIdx = _currentIdx;
        _provisionalIdx = null;
        _applyWindow();
      });
      return;
    }

    _stableIdx = currentIdx;
    _provisionalIdx = null;
    _applyWindow();
  }

  void _applyWindow({bool protectJump = false}) =>
      ImagePipelinePerf.sync(
        'applyWindow',
        () => _applyWindowImpl(protectJump: protectJump),
      );

  void _applyWindowImpl({bool protectJump = false}) {
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
        'Streaming.Pipeline.Flow',
        'CURRENT ${_flowKey(previousCurrent)} -> ${_flowKey(_currentKey)}',
      );
    }

    // Ensure entries exist
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
        fullKey: _fullKey(key),
        sourceKey: _sourceKey,
        cid: _cid,
        eid: _eid,
      );
    }

    _applyPolicies();
    _syncPolicyLeases();
    _syncCurrentDownloadProgress();
    _cache?.setActivePages(
      [_currentKey, ..._nearKeys, ..._prevKeys]
          .where((key) => key.isNotEmpty)
          .map(_fullKey),
    );
  }

  void dispose() {
    _jumpProtectionTimer?.cancel();
    _jumpProtectionTimer = null;
    _dragCommitTimer?.cancel();
    _dragCommitTimer = null;
    _detachPolicyScope();
    _sessionId++;
    _progress.reset();
    _cacheDownloads.dispose();
    _sessions.dispose();
    _scheduler.clear();
    resources.dispose();
  }

  void detachReaderSession(Object owner) {
    if (!identical(_readerOwner, owner)) return;
    _readerOwner = null;
    _detachPolicyScope();
    _sessionId++;
    _jumpProtectionTimer?.cancel();
    _jumpProtectionTimer = null;
    _dragCommitTimer?.cancel();
    _dragCommitTimer = null;
    _provisionalIdx = null;
    _cache = null;
    _progress.reset();
    // Logical detach only. Native sources and decode sessions survive while
    // visible or other policy leases still reference them.
    resources.clear();
    _images = const [];
    _currentUsesExternalCodec = false;
    _sessionAliases = const {};
    _currentKey = '';
    _nearKeys.clear();
    _prevKeys.clear();
    _farKeys.clear();
    _keepKeys.clear();
    _offsetByKey.clear();
  }

  StreamingResourceLease acquireVisibleStreaming({
    required String imageKey,
    required String? sourceKey,
    required String cid,
    required String eid,
    required String fullKey,
    required int targetWidth,
    required int targetHeight,
    required String scopeId,
  }) {
    // 诊断：无条件打出显示 lease 挂载事件，isCur 位表示这页此刻是否被认为是当前页。
    ImagePipelinePerf.count(
      'visAttach.isCur${imageKey == _currentKey ? 1 : 0}'
      '.sz${targetWidth}x$targetHeight',
    );
    final downloadIdentity = _downloadIdentity(
      imageKey,
      sourceKey,
      cid,
      eid,
    );
    final lease = _sessions.acquire(
      downloadIdentity: downloadIdentity,
      decodeIdentity: WebPDecodeIdentity(
        fullKey: fullKey,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      ),
      scopeId: scopeId,
      // The ImageStream is a display subscriber, not the page-policy owner.
      // Current/near promotion comes from _syncPolicyLeases; this baseline
      // demand is a low-priority safety net for standalone/first-build races.
      // It still uses the same DownloadSession and never opens a second stream.
      //
      // decodeTargetFrames 必须 > 0：这是「正在屏幕上显示」的首帧安全网。水位表
      // (rank) 只覆盖 readDist 0/+1/+2/-1，落在其外但仍在显示的页（翻页边界、
      // 双页第二张、快切后停在窗口边缘）若只靠 policy lease，目标会是 0 →
      // needsDecode 永远 false → 无限转圈。这里只保底 1 帧，持续播放和预解深度
      // 仍完全由 policy lease 决定，避免可见 lease 绕过“当前页告急时近邻为 0”。
      demand: const StreamingResourceDemand(
        downloadPriority: 60,
        decodePriority: 60,
        allowDownload: true,
        allowDecode: true,
        allowUpload: true,
        current: false,
        decodeTargetFrames: 1,
      ),
    );
    final logicalKey = '$imageKey@$sourceKey@$cid@$eid';
    if (logicalKey != downloadIdentity.cacheKey) {
      Log.info(
        'Streaming.Reuse',
        'bind logical=$logicalKey download=${downloadIdentity.cacheKey} '
            'decode=$fullKey source=${identityHashCode(lease.download.source)} '
            'epoch=${lease.download.sourceEpoch} '
            'cursor=${identityHashCode(lease.decode.cursor)}',
      );
    }
    return lease;
  }

  DownloadIdentity _downloadIdentity(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final alias = resolveImageAliasForSession(
      imageKey,
      sourceKey,
      cid,
      eid,
    );
    return DownloadIdentity(
      imageKey: alias?.imageKey ?? imageKey,
      sourceKey: alias?.sourceKey ?? sourceKey,
      cid: alias?.cid ?? cid,
      eid: alias?.eid ?? eid,
    );
  }

  CacheAliasTarget? resolveImageAliasForSession(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    if (_images.isNotEmpty &&
        sourceKey == _sourceKey &&
        cid == _cid &&
        eid == _eid) {
      return _sessionAliases[imageKey];
    }
    return CacheManager().resolveImageAlias(imageKey, sourceKey, cid, eid);
  }

  String _fullKey(String imageKey) {
    final identity = '$imageKey@$_sourceKey@$_cid@$_eid';
    return _targetW > 0 || _targetH > 0
        ? '$identity@${_targetW}x$_targetH'
        : identity;
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
      downloadRank: (entry, priority) =>
          _downloadRank(entry, priority: priority),
      markDistant: markDistant,
    );
  }

  String get _policyScopeId => 'reader:$_sessionId';

  void _syncPolicyLeases() =>
      ImagePipelinePerf.sync('syncPolicyLeases', _syncPolicyLeasesImpl);

  void _syncPolicyLeasesImpl() {
    // 诊断：本次 sync 时 _currentKey 是否为空、resources 里是否存在等于它的 entry。
    var sawCurrentEntry = false;
    var currentUndemanded = false;
    final liveFullKeys = <String>{};
    resources.forEach((entry) {
      final policy = entry.policy;
      final demanded =
          policy.allowDownload || policy.allowDecode || policy.allowGpuUpload;
      if (entry.imageKey == _currentKey) {
        sawCurrentEntry = true;
        if (!demanded) currentUndemanded = true;
      }
      final downloadIdentity = _downloadIdentity(
        entry.imageKey,
        entry.sourceKey,
        entry.cid,
        entry.eid,
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

      // rank 水位：按阅读方向相对距离查帧深表，得本页目标缓冲帧数。offset 是相对
      // 当前页的原始带符号偏移；乘 readDirection 归一到「阅读方向上的距离」，前翻
      // 后翻对称。current=0 / next=+1 / next+1=+2 / prev=-1，其余距离目标 0。
      final offset = _offsetByKey[entry.imageKey] ?? _offsetFor(entry.imageKey);
      final readDist = offset * _readDirection;
      final targetFrames = policy.allowDecode &&
              (!_currentUsesExternalCodec ||
                  entry.priority == PagePriority.current)
          ? FrameDepthTable.targetFor(
              ruleIndex: _windowRuleIndex < 0 ? 4 : _windowRuleIndex,
              readDist: readDist,
            )
          : 0;
      // 解码 rank 按阅读方向距离衰减，让近页先拿 worker（n>m>反向p）。current 不衰减。
      // 注意 clamp(low, high) 要求 low<=high：当 policy.decodePriority==0（far/keep
      // 等允许解码但优先级为 0 的页）时，clamp(1,0) 会抛 Invalid argument。此处对
      // 优先级 <=1 的页直接透传原值，仅对 >1 的页做「衰减但不低于 1」。
      final int decodePriority;
      if (entry.priority == PagePriority.current || policy.decodePriority <= 1) {
        decodePriority = policy.decodePriority;
      } else {
        decodePriority = (policy.decodePriority - readDist.abs() * 4)
            .clamp(1, policy.decodePriority);
      }

      final demand = StreamingResourceDemand(
        downloadPriority: policy.allowDownload ? _downloadRank(entry) : 0,
        decodePriority: decodePriority,
        allowDownload: policy.allowDownload,
        allowDecode: policy.allowDecode,
        allowUpload: policy.allowGpuUpload,
        current: entry.priority == PagePriority.current,
        decodeTargetFrames: targetFrames,
      );
      // 诊断：无条件打出每个被建 lease 的 entry 的 priority/current/目标帧，
      // 以及它 imageKey 是否等于 _currentKey（isCur 位）。定位「播放页为何不是
      // current」——标记失败还是 identity 错位还是 _currentKey 本身不对。
      ImagePipelinePerf.count(
        'polLease.pri${entry.priority.index}'
        '.cur${demand.current ? 1 : 0}'
        '.tf$targetFrames'
        '.isCur${entry.imageKey == _currentKey ? 1 : 0}',
      );

      var lease = _policyLeases[entry.fullKey];
      final identityChanged =
          lease != null &&
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
    // 诊断：一次 sync 的结论。ck 空 / 未见当前 entry / 当前 entry 无需求，任一
    // 都会让当前页拿不到解码 lease → 无图 / 走 near。
    ImagePipelinePerf.count(
      'syncCur.ckEmpty${_currentKey.isEmpty ? 1 : 0}'
      '.saw${sawCurrentEntry ? 1 : 0}'
      '.undemanded${currentUndemanded ? 1 : 0}'
      '.ri$_windowRuleIndex',
    );
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
    StreamingTransportProgress progress,
  ) {
    resources.forEach((entry) {
      if (_downloadIdentity(
            entry.imageKey,
            entry.sourceKey,
            entry.cid,
            entry.eid,
          ) !=
          identity) {
        return;
      }
      entry.download.updateProgress(progress.currentBytes, progress.totalBytes);
      entry.download.inProgress = !progress.done;
      if (progress.done) entry.download.lastError = null;
      if (!progress.done && entry.policy.allowDownload) {
        _policyLeases[entry.fullKey]?.updateDownloadPriority(
          _downloadRank(entry),
        );
      }
    });

    // Old retained sessions may still finish after a chapter/source switch.
    // Publish only when the complete DownloadIdentity matches the page that is
    // current now; comparing imageKey alone can show another session's bytes.
    final currentLease = _currentPolicyLease;
    final isCurrentIdentity =
        currentLease != null && currentLease.download.identity == identity;
    _progress.update(
      identity.imageKey,
      progress.currentBytes,
      progress.totalBytes,
      currentKey: isCurrentIdentity ? identity.imageKey : '',
      progressKey: identity.cacheKey,
      done: progress.done,
    );
  }

  StreamingResourceLease? get _currentPolicyLease {
    if (_currentKey.isEmpty) return null;
    return _policyLeases[_fullKey(_currentKey)];
  }

  void _syncCurrentDownloadProgress() {
    if (_currentKey.isEmpty) {
      _progress.syncCurrentSession(
        imageKey: '',
        progressKey: '',
        snapshot: null,
      );
      return;
    }
    final lease = _currentPolicyLease;
    _progress.syncCurrentSession(
      imageKey: _currentKey,
      progressKey: lease?.download.identity.cacheKey ?? _currentKey,
      snapshot: lease?.download.snapshot,
    );
  }

  static bool _sameImages(List<String> left, List<String> right) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  int _downloadRank(ResourceEntry entry, {PagePriority? priority}) {
    return DownloadRanker(
      runningDownloads: _scheduler.runningDownloadCount,
      queuedDownloads: _scheduler.queuedDownloadCount,
      maxConcurrent: _scheduler.maxConcurrent,
      readDirection: _readDirection,
      offsetFor: (key) => _offsetByKey[key] ?? _offsetFor(key),
    ).rank(entry, priority: priority);
  }

  int _offsetFor(String imageKey) {
    final idx = _images.indexOf(imageKey);
    return idx < 0 ? 1 << 20 : idx - _currentIdx;
  }

  static String _flowKey(String key) => key.isEmpty ? '-' : key.split('/').last;
}
