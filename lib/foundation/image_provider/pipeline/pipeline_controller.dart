import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/image_provider/cache/decoded_image_cache.dart';
import 'package:venera/foundation/image_provider/webp_image_provider.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'preload_policy.dart';
import 'resource_entry.dart';
import 'resource_manager.dart';
import 'tasks.dart';
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

class _ProgressSample {
  int bytes;
  int ms;
  double speed;
  _ProgressSample(this.bytes, this.ms, this.speed);
}

// ═══════════════════════════════════════════════════════════════
// PipelineController
// ═══════════════════════════════════════════════════════════════

class PipelineController {
  static final PipelineController instance = PipelineController._();
  PipelineController._();

  final ResourceManager resources = ResourceManager();
  final TaskScheduler _scheduler = TaskScheduler.instance;
  final currentDownloadProgress = ValueNotifier<ReaderDownloadProgress>(
    const ReaderDownloadProgress.idle(),
  );

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
  final Set<String> _streamDecodeAttached = {};
  final Map<String, StreamSubscription<ImageDownloadProgress>>
  _streamDecodeSubs = {};
  final Map<String, void Function()> _streamDecodeDisposers = {};
  final Map<String, _ProgressSample> _progressSamples = {};
  int _lastProgressNotifyMs = 0;

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
    _detachInactiveStreamDecoders(activeImageKeys);

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
    currentDownloadProgress.value = const ReaderDownloadProgress.idle();
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
      _streamDecodeAttached.contains(fullKey);

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
    final offset = _offsetByKey[entry.imageKey] ?? _offsetFor(entry.imageKey);
    final distance = offset.abs();
    final progress = entry.download.progress;
    final p2 = progress * progress;
    final progressBoost = (progress * 32 + p2 * 160 + p2 * p2 * 260).round();
    final runningDownloads = _scheduler.runningDownloadCount;
    final queuedDownloads = _scheduler.queuedDownloadCount;
    final freeDownloadSlots =
        math.max(0, _scheduler.maxConcurrent - runningDownloads);
    final inProgressBoost = entry.download.inProgress
        ? 80 + freeDownloadSlots * 16
        : 0;
    final hasPressure = runningDownloads + queuedDownloads >= _scheduler.maxConcurrent;
    final pressurePenalty = p == PagePriority.distant && hasPressure
        ? (runningDownloads + queuedDownloads - _scheduler.maxConcurrent + 1) * 24
        : 0;

    final base = switch (p) {
      PagePriority.current => 1000,
      PagePriority.near when offset > 0 => 760,
      PagePriority.near => 720,
      PagePriority.far when offset > 0 => 520,
      PagePriority.far => 500,
      PagePriority.keep => 260,
      PagePriority.distant when entry.download.inProgress => 180,
      PagePriority.distant => 0,
    };

    if (base == 0) return 0;
    final directionBias = offset < 0 ? -8 : 0;
    final raw = base -
        distance * 12 +
        directionBias +
        inProgressBoost +
        progressBoost -
        pressurePenalty;
    final cap = switch (p) {
      PagePriority.current => 2000,
      PagePriority.near when offset > 0 => 940,
      PagePriority.near => 900,
      PagePriority.far when offset > 0 => 700,
      PagePriority.far => 680,
      PagePriority.keep => 660,
      PagePriority.distant => 660,
    };
    return raw.clamp(1, cap).toInt();
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
      final attached = _attachStreamDecodeToRunningDownload(
        entry,
        sourceKey,
        cid,
        eid,
      );
      if (attached ||
          _scheduler.hasTask(entry.imageKey) ||
          ImageDownloader.isLoadingComicImage(
            entry.imageKey,
            sourceKey,
            cid,
            eid,
          )) {
        return;
      }
      debugPrint('[WebP-Stream][pipeline] STALE-DOWNLOAD ${entry.imageKey}');
      entry.download.inProgress = false;
      DecoderManager.instance
          .getHolder(entry.fullKey)
          ?.markStreamDownloadClosed(StateError('stale pipeline download'));
      _detachStreamDecode(entry.fullKey);
    }
    if (_prefetchBudgetExceededFor(entry)) return;

    entry.download.inProgress = true;
    final streamDecode = _streamDecodeOnDownload(entry);
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
          _detachStreamDecode(entry.fullKey);
        });
    task.setContext(ExecutionContext(entry));
    _scheduler.submit(task);
  }

  ({void Function(ImageDownloadProgress event) onEvent, void Function() dispose})?
  _streamDecodeOnDownload(
    ResourceEntry entry,
  ) {
    if (!entry.policy.allowDecode || !entry.policy.allowGpuUpload) return null;
    if (!_streamDecodeAttached.add(entry.fullKey)) return null;
    final existingHolder = DecoderManager.instance.getHolder(entry.fullKey);
    DecoderHolder? holder = existingHolder != null &&
            !existingHolder.disposed &&
            existingHolder.decoder.isStreaming &&
            !existingHolder.decoder.streamIsComplete
        ? existingHolder
        : null;
    webp.WebPAnimDecoder? decoder = holder?.decoder;
    var appendedUntil = holder?.streamLoadedBytes ?? 0;
    var chunkCount = 0;
    var lastDebugBytes = 0;
    var lastFrameCount = -1;
    var stopped = false;
    var completed = false;
    debugPrint(
      '[WebP-Stream][pipeline] START key=${entry.imageKey} '
      'priority=${entry.priority} full=${entry.fullKey}',
    );
    if (holder != null) {
      for (final peer in resources.getAllForImage(entry.imageKey)) {
        if (peer.fullKey == entry.fullKey) {
          peer.holder = holder;
          peer.decode.markSuccess();
        }
      }
    }
    void dispose() {
      _streamDecodeAttached.remove(entry.fullKey);
      final d = decoder;
      if (holder != null &&
          !completed &&
          d != null &&
          !d.isDisposed &&
          d.isStreaming &&
          !d.streamIsComplete) {
        holder!.markStreamDownloadClosed(StateError('pipeline stream detached'));
      }
      if (holder == null && d != null && !d.isDisposed) d.dispose();
    }
    void onEvent(ImageDownloadProgress event) {
      if (stopped) return;
      final canDecode = entry.policy.allowDecode && entry.policy.allowGpuUpload;
      if (!canDecode || (entry.hasHolder && holder == null)) {
        stopped = true;
        debugPrint(
          '[WebP-Stream][pipeline] STOP allowDecode=${entry.policy.allowDecode} '
          'allowGpu=${entry.policy.allowGpuUpload} hasHolder=${entry.hasHolder} '
          'priority=${entry.priority} ${entry.imageKey}',
        );
        dispose();
        return;
      }
      if (event.reset && decoder != null && !decoder!.isDisposed) {
        debugPrint('[WebP-Stream][pipeline] RESET ${entry.imageKey}');
        decoder!.resetStreamInput();
        holder?.clearBufferedFrames();
        holder?.updateStreamTransfer(0, null, reset: true);
        holder?.resetStreamPlaybackState();
        appendedUntil = 0;
      }
      final chunk = event.chunkBytes;
      if (chunk != null) {
        decoder ??= webp.createStreamingAnimDecoder(
          targetWidth: _targetW,
          targetHeight: _targetH,
        );
        final d = decoder;
        if (d == null || d.isDisposed) return;
        final chunkEnd = event.currentBytes;
        final chunkStart = chunkEnd - chunk.length;
        if (chunkEnd <= appendedUntil) {
          holder?.updateStreamTransfer(event.currentBytes, event.totalBytes);
          holder?.markStreamActive();
          if (canDecode) holder?.requestRefill();
          return;
        }
        final data = chunkStart < appendedUntil
            ? Uint8List.sublistView(chunk, appendedUntil - chunkStart)
            : chunk;
        appendedUntil = chunkEnd;
        chunkCount++;
        if (chunkCount <= 3 ||
            event.currentBytes - lastDebugBytes >= 1024 * 1024) {
          lastDebugBytes = event.currentBytes;
          debugPrint(
            '[WebP-Stream][pipeline] chunk#$chunkCount '
            '+${data.length} loaded=${event.currentBytes}/${event.totalBytes ?? -1} '
            '${entry.imageKey}',
          );
        }
        final ready = d.appendStreamChunk(data);
        if (ready && d.frameCount != lastFrameCount) {
          lastFrameCount = d.frameCount;
          debugPrint(
            '[WebP-Stream][pipeline] info animated=${d.streamIsAnimated} '
            'frames=${d.frameCount} ${d.targetWidth}x${d.targetHeight} '
            '${entry.imageKey}',
          );
        }
        if (ready && !d.streamIsAnimated) {
          debugPrint('[WebP-Stream][pipeline] ready but static ${entry.imageKey}');
        }
        if (ready &&
            d.streamIsAnimated &&
            holder == null &&
            d.frameCount > 0 &&
            d.targetWidth > 0) {
          debugPrint(
            '[WebP-Stream][pipeline] READY animated ${d.frameCount}f '
            '${d.targetWidth}x${d.targetHeight} ${entry.imageKey}',
          );
          holder = DecoderManager.instance.getOrCreateHolder(
            entry.fullKey,
            d,
            d.targetWidth,
            d.targetHeight,
            1.0,
          );
          holder!.updateStreamTransfer(event.currentBytes, event.totalBytes);
          holder!.markStreamActive();
          for (final peer in resources.getAllForImage(entry.imageKey)) {
            if (peer.fullKey == entry.fullKey) {
              peer.holder = holder;
              peer.decode.markSuccess();
            }
          }
          if (canDecode) holder?.requestRefill();
          debugPrint('[WebP-Stream][pipeline] HOLDER ${entry.imageKey}');
        } else {
          holder?.updateStreamTransfer(event.currentBytes, event.totalBytes);
          holder?.markStreamActive();
          if (canDecode) holder?.requestRefill();
        }
      }
      if (event.imageBytes != null) {
        completed = true;
        holder?.updateStreamTransfer(
          event.imageBytes!.length,
          event.imageBytes!.length,
        );
        debugPrint(
          '[WebP-Stream][pipeline] FINAL ${event.imageBytes!.length}B '
          'holder=${holder != null} ${entry.imageKey}',
        );
        final d = decoder;
        if (d != null && !d.isDisposed) {
          d.appendStreamChunk(
            appendedUntil == 0 ? event.imageBytes! : Uint8List(0),
            isFinal: true,
          );
          if (canDecode) holder?.requestRefill();
          if (holder == null) d.dispose();
        }
      }
    }
    return (onEvent: onEvent, dispose: dispose);
  }

  bool _attachStreamDecodeToRunningDownload(
    ResourceEntry entry,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    if (!entry.policy.allowDecode || !entry.policy.allowGpuUpload) return false;
    if (_streamDecodeAttached.contains(entry.fullKey)) {
      return true;
    }
    if (entry.hasHolder) return false;
    final stream = ImageDownloader.joinLoadingComicImage(
      entry.imageKey,
      sourceKey,
      cid,
      eid,
      debugLabel: 'pipeline-stream-attach',
    );
    if (stream == null) {
      debugPrint('[WebP-Stream][pipeline] ATTACH skip no-shared ${entry.imageKey}');
      return false;
    }
    final streamDecode = _streamDecodeOnDownload(entry);
    if (streamDecode == null) return true;
    late StreamSubscription<ImageDownloadProgress> sub;
    sub = stream.listen(
      (event) {
        final active = entry.download.inProgress &&
            entry.policy.allowDecode &&
            entry.policy.allowGpuUpload &&
            !entry.hasBytes;
        if (!active) {
          _detachStreamDecode(entry.fullKey);
          return;
        }
        streamDecode.onEvent(event);
      },
      onError: (e) {
        debugPrint('[WebP-Stream][pipeline] ATTACH-ERROR ${entry.imageKey} $e');
        _detachStreamDecode(entry.fullKey);
      },
      onDone: () => _detachStreamDecode(entry.fullKey),
      cancelOnError: false,
    );
    _streamDecodeSubs[entry.fullKey] = sub;
    _streamDecodeDisposers[entry.fullKey] = streamDecode.dispose;
    debugPrint('[WebP-Stream][pipeline] ATTACH running ${entry.imageKey}');
    return true;
  }

  void _detachStreamDecode(String fullKey) {
    _streamDecodeSubs.remove(fullKey)?.cancel();
    _streamDecodeDisposers.remove(fullKey)?.call();
    _streamDecodeAttached.remove(fullKey);
  }

  void _detachInactiveStreamDecoders(Set<String> activeImageKeys) {
    for (final fullKey in _streamDecodeSubs.keys.toList()) {
      final imageKey = _baseKey(fullKey);
      final entry = resources.get(fullKey);
      final active = activeImageKeys.contains(imageKey) &&
          entry != null &&
          entry.policy.allowDecode &&
          entry.policy.allowGpuUpload;
      if (!active) _detachStreamDecode(fullKey);
    }
  }

  static String _baseKey(String fullKey) {
    final at = fullKey.lastIndexOf('@');
    if (at < 0) return fullKey;
    final suffix = fullKey.substring(at + 1);
    return RegExp(r'^\d+x\d+$').hasMatch(suffix)
        ? fullKey.substring(0, at)
        : fullKey;
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
    _progressSamples.remove(imageKey);
    if (imageKey == _currentKey) {
      currentDownloadProgress.value = const ReaderDownloadProgress.idle();
    }
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
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _progressSamples[imageKey];
    var speed = old?.speed ?? 0.0;
    if (old != null && now > old.ms && current >= old.bytes) {
      final instant = (current - old.bytes) * 1000.0 / (now - old.ms);
      speed = speed <= 0 ? instant : speed * 0.7 + instant * 0.3;
    } else if (old != null && current < old.bytes) {
      speed = 0;
    }
    _progressSamples[imageKey] = _ProgressSample(current, now, speed);
    if (imageKey != _currentKey) return;
    final complete = done || (total != null && total > 0 && current >= total);
    if (complete) {
      currentDownloadProgress.value = const ReaderDownloadProgress.idle();
      return;
    }
    if (now - _lastProgressNotifyMs < 100 && current > 0) return;
    _lastProgressNotifyMs = now;
    currentDownloadProgress.value = ReaderDownloadProgress(
      imageKey: imageKey,
      active: true,
      currentBytes: current,
      totalBytes: total,
      speedBytesPerSecond: speed,
    );
  }

  void _syncCurrentDownloadProgress() {
    final entry = resources.get(_currentKey);
    if (entry == null || entry.hasBytes || !entry.download.inProgress) {
      currentDownloadProgress.value = const ReaderDownloadProgress.idle();
      return;
    }
    final sample = _progressSamples[_currentKey];
    currentDownloadProgress.value = ReaderDownloadProgress(
      imageKey: _currentKey,
      active: true,
      currentBytes: entry.download.currentBytes,
      totalBytes: entry.download.totalBytes,
      speedBytesPerSecond: sample?.speed ?? 0,
    );
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
