import 'dart:async';

import 'package:venera/foundation/image_provider/pipeline/task_scheduler.dart';
import 'package:venera/foundation/image_provider/pipeline/tasks.dart';
import 'package:venera/foundation/image_provider/renderer/frame_renderer.dart';
import 'package:venera/network/webp_download_transport.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'download_session.dart';
import 'webp_decode_session.dart';

final class WebPResourceDemand {
  final int downloadPriority;
  final int decodePriority;
  final bool allowDownload;
  final bool allowDecode;
  final bool allowUpload;
  final bool current;

  /// 本页目标缓冲帧深（rank 水位表算出）。透传到 holder 决定解到几帧。
  final int decodeTargetFrames;

  const WebPResourceDemand({
    required this.downloadPriority,
    required this.decodePriority,
    required this.allowDownload,
    required this.allowDecode,
    required this.allowUpload,
    required this.current,
    this.decodeTargetFrames = 0,
  });
}

final class WebPResourceLease {
  final WebPSessionCoordinator _coordinator;
  final String scopeId;
  final DownloadSession download;
  final WebPDecodeSession decode;
  DownloadDemandLease? _downloadLease;
  WebPDecodeDemandLease? _decodeLease;
  bool _attached = true;

  WebPResourceLease._(
    this._coordinator,
    this.scopeId,
    this.download,
    this.decode,
    WebPResourceDemand demand,
  ) {
    update(demand);
  }

  bool get attached => _attached;

  void update(WebPResourceDemand demand) {
    if (!_attached) throw StateError('WebP resource lease is detached');
    if (demand.allowDownload) {
      final lease = _downloadLease;
      if (lease == null) {
        _downloadLease = download.attach(
          scopeId: scopeId,
          priority: demand.downloadPriority,
        );
      } else {
        lease.updatePriority(demand.downloadPriority);
      }
    } else {
      _downloadLease?.detach();
      _downloadLease = null;
    }

    if (demand.allowDecode || demand.allowUpload) {
      final lease = _decodeLease;
      if (lease == null) {
        _decodeLease = decode.attach(
          scopeId: scopeId,
          priority: demand.decodePriority,
          current: demand.current,
          decode: demand.allowDecode,
          upload: demand.allowUpload,
          targetFrames: demand.decodeTargetFrames,
        );
      } else {
        lease.update(
          priority: demand.decodePriority,
          current: demand.current,
          decode: demand.allowDecode,
          upload: demand.allowUpload,
          targetFrames: demand.decodeTargetFrames,
        );
      }
    } else {
      _decodeLease?.detach();
      _decodeLease = null;
    }
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    _downloadLease?.detach();
    _decodeLease?.detach();
    _downloadLease = null;
    _decodeLease = null;
    _coordinator._leases.remove(this);
  }
}

final class WebPSessionCoordinator {
  final TaskScheduler scheduler;
  final WebPTransport Function(DownloadIdentity identity) transportFactory;
  final FrameRenderer renderer;
  final void Function(
    DownloadIdentity identity,
    WebPTransportProgress progress,
  )?
  onProgress;
  final void Function(DownloadSession session)? onDownloadSession;

  late final DownloadSessionRegistry downloads;
  late final WebPDecodeSessionRegistry decodes;
  final Set<WebPResourceLease> _leases = {};
  final Set<WebPDecodeIdentity> _pendingDecodeEvictions = {};
  final Set<DownloadIdentity> _pendingDownloadEvictions = {};
  final Set<WebPDecodeSession> _retiredDecodes = {};
  final Map<DownloadIdentity, Timer> _retryTimers = {};

  WebPSessionCoordinator({
    required this.scheduler,
    required this.transportFactory,
    this.renderer = const FlutterImageRenderer(),
    this.onProgress,
    this.onDownloadSession,
    webp.WebPByteSource Function(int expectedLength, int epoch)? sourceFactory,
    webp.WebPFrameCursor Function(
      webp.WebPByteSource source,
      int targetWidth,
      int targetHeight,
    )?
    cursorFactory,
  }) {
    downloads = DownloadSessionRegistry(
      reconcile: _reconcileDownload,
      sourceFactory: sourceFactory,
    );
    decodes = WebPDecodeSessionRegistry(
      reconcile: _reconcileDecode,
      cursorFactory: cursorFactory,
    );
  }

  WebPResourceLease acquire({
    required DownloadIdentity downloadIdentity,
    required WebPDecodeIdentity decodeIdentity,
    required String scopeId,
    required WebPResourceDemand demand,
  }) {
    final download = downloads.getOrCreate(downloadIdentity);
    onDownloadSession?.call(download);
    _replaceDecodeBindingIfNeeded(decodeIdentity, download);
    final decode = decodes.getOrCreate(decodeIdentity, download);
    final lease = WebPResourceLease._(this, scopeId, download, decode, demand);
    _leases.add(lease);
    return lease;
  }

  void _replaceDecodeBindingIfNeeded(
    WebPDecodeIdentity identity,
    DownloadSession download,
  ) {
    final existing = decodes.find(identity);
    if (existing == null || identical(existing.download, download)) return;

    final oldDownload = existing.download;
    // A decode identity is unique among active bindings. When its source
    // identity changes, revoke old leases and retire the old binding. A running
    // upload may still own a native frame, so the old cursor is disposed only
    // after its in-flight claims have completed.
    for (final lease
        in _leases
            .where((lease) => identical(lease.decode, existing))
            .toList()) {
      lease.detach();
    }
    scheduler.cancelInLane(SchedulerLane.decode, _decodeTaskKey(existing));
    scheduler.cancelInLane(SchedulerLane.upload, _uploadTaskKey(existing));
    final retired = decodes.retire(identity);
    if (retired != null) {
      _retiredDecodes.add(retired);
      retired.requestReconcile();
    }
    // The identity is about to be rebound. A pending eviction for the old
    // binding must not accidentally target the replacement.
    _pendingDecodeEvictions.remove(identity);

    _pendingDownloadEvictions.add(oldDownload.identity);
    scheduler.cancelInLane(
      SchedulerLane.network,
      _downloadTaskKey(oldDownload.identity),
    );
    _drainRetiredDecode(existing);
  }

  void detachScope(String scopeId) {
    for (final lease
        in _leases.where((lease) => lease.scopeId == scopeId).toList()) {
      lease.detach();
    }
  }

  bool tryEvict(
    WebPDecodeIdentity decodeIdentity,
    DownloadIdentity downloadIdentity,
  ) {
    _pendingDecodeEvictions.add(decodeIdentity);
    _pendingDownloadEvictions.add(downloadIdentity);
    final decodeEvicted = _drainDecodeEviction(decodeIdentity);
    final downloadEvicted = _drainDownloadEviction(downloadIdentity);
    return decodeEvicted || downloadEvicted;
  }

  void evictUndemanded() {
    for (final session in decodes.sessions.toList()) {
      if (session.demandCount > 0) continue;
      _pendingDecodeEvictions.add(session.identity);
      scheduler.cancelInLane(SchedulerLane.decode, _decodeTaskKey(session));
      scheduler.cancelInLane(SchedulerLane.upload, _uploadTaskKey(session));
      _drainDecodeEviction(session.identity);
    }
    for (final session in _retiredDecodes.toList()) {
      _drainRetiredDecode(session);
    }
    for (final session in downloads.sessions.toList()) {
      if (session.hasDemand) continue;
      _pendingDownloadEvictions.add(session.identity);
      // clearAll/dispose is an explicit physical eviction request, unlike a
      // normal page-window detach where an active transport may finish.
      scheduler.cancelInLane(
        SchedulerLane.network,
        _downloadTaskKey(session.identity),
      );
      _drainDownloadEviction(session.identity);
    }
  }

  void dispose() {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    for (final lease in _leases.toList()) {
      lease.detach();
    }
    evictUndemanded();
  }

  void _reconcileDownload(DownloadSession session) {
    if (session.hasDemand) {
      _pendingDownloadEvictions.remove(session.identity);
    } else if (_pendingDownloadEvictions.contains(session.identity) &&
        _drainDownloadEviction(session.identity)) {
      return;
    }
    if (session.isDisposed) return;
    final key = _downloadTaskKey(session.identity);

    if (!session.hasDemand) {
      _cancelRetry(session.identity);
      // Retain an established transport: several sources do not support HTTP
      // range requests, so cancelling here would discard an unusable prefix
      // and force the next current page to download from zero.
      if (session.transport != DownloadTransportState.receiving &&
          session.transport != DownloadTransportState.sealed) {
        scheduler.cancelInLane(SchedulerLane.network, key);
      }
      return;
    }

    if (session.transport == DownloadTransportState.sealed) {
      _cancelRetry(session.identity);
      return;
    }
    if (session.transport == DownloadTransportState.failed) {
      if (session.failureRetryable) {
        _scheduleRetry(session);
      } else {
        _cancelRetry(session.identity);
      }
      return;
    }

    if (scheduler.hasTaskInLane(SchedulerLane.network, key)) {
      scheduler.updatePriority(
        SchedulerLane.network,
        key,
        session.desiredPriority,
      );
      return;
    }

    _cancelRetry(session.identity);
    scheduler.submit(
      WebPDownloadTask(
        key: key,
        generation: session.transportRevision + 1,
        priority: session.desiredPriority,
        cancelable: true,
        session: session,
        transport: transportFactory(session.identity),
        onProgress: (progress) => onProgress?.call(session.identity, progress),
      ),
    );
  }

  void _reconcileDecode(WebPDecodeSession session) {
    if (session.isDisposed) {
      _retiredDecodes.remove(session);
      return;
    }
    if (_retiredDecodes.contains(session) ||
        !identical(decodes.find(session.identity), session)) {
      _retiredDecodes.add(session);
      _drainRetiredDecode(session);
      return;
    }
    if (session.demandCount > 0) {
      _pendingDecodeEvictions.remove(session.identity);
    } else if (_pendingDecodeEvictions.contains(session.identity) &&
        _drainDecodeEviction(session.identity)) {
      _drainDownloadEviction(session.download.identity);
      return;
    }
    if (session.isDisposed) return;

    final decodeKey = _decodeTaskKey(session);
    final hasDecodeTask =
        scheduler.hasTaskInLane(SchedulerLane.decode, decodeKey);
    if (hasDecodeTask &&
        !scheduler.decodeTaskMatchesCurrent(decodeKey, session.isCurrent)) {
      scheduler.cancelInLane(SchedulerLane.decode, decodeKey);
    } else if (!session.shouldDecode || !session.sourceDecodable) {
      scheduler.cancelInLane(SchedulerLane.decode, decodeKey);
    } else if (!session.decodeFailed &&
        session.canScheduleDecode &&
        session.holder.needsDecode &&
        !hasDecodeTask) {
      scheduler.submit(
        WebPDecodeTask(
          key: decodeKey,
          generation: session.decodeRevision,
          priority: session.decodePriority,
          session: session,
        ),
      );
    } else if (hasDecodeTask) {
      scheduler.updatePriority(
        SchedulerLane.decode,
        decodeKey,
        session.decodePriority,
      );
    }

    final uploadKey = _uploadTaskKey(session);
    if (!session.shouldUpload) {
      scheduler.cancelInLane(SchedulerLane.upload, uploadKey);
    } else if (!session.uploadFailed &&
        session.holder.needsUpload &&
        !scheduler.hasTaskInLane(SchedulerLane.upload, uploadKey)) {
      scheduler.submit(
        WebPFrameUploadTask(
          key: uploadKey,
          generation: session.uploadRevision,
          priority: session.uploadPriority,
          session: session,
          renderer: renderer,
        ),
      );
    } else if (scheduler.hasTaskInLane(SchedulerLane.upload, uploadKey)) {
      scheduler.updatePriority(
        SchedulerLane.upload,
        uploadKey,
        session.uploadPriority,
      );
    }
  }

  bool _drainDecodeEviction(WebPDecodeIdentity identity) {
    final session = decodes.find(identity);
    if (session == null) {
      _pendingDecodeEvictions.remove(identity);
      return false;
    }
    if (session.demandCount > 0) return false;
    scheduler.cancelInLane(SchedulerLane.decode, _decodeTaskKey(session));
    scheduler.cancelInLane(SchedulerLane.upload, _uploadTaskKey(session));
    if (!session.canEvict) return false;
    decodes.evict(identity);
    _pendingDecodeEvictions.remove(identity);
    return true;
  }

  bool _drainRetiredDecode(WebPDecodeSession session) {
    if (session.isDisposed) {
      _retiredDecodes.remove(session);
      return true;
    }
    scheduler.cancelInLane(SchedulerLane.decode, _decodeTaskKey(session));
    scheduler.cancelInLane(SchedulerLane.upload, _uploadTaskKey(session));
    if (!session.canEvict) return false;
    final downloadIdentity = session.download.identity;
    session.evict();
    _retiredDecodes.remove(session);
    _drainDownloadEviction(downloadIdentity);
    return true;
  }

  bool _drainDownloadEviction(DownloadIdentity identity) {
    _cancelRetry(identity);
    final session = downloads.find(identity);
    if (session != null && session.hasDemand) return false;
    if (session != null &&
        session.transport != DownloadTransportState.receiving) {
      scheduler.cancelInLane(SchedulerLane.network, _downloadTaskKey(identity));
    }
    if (session != null && !session.canEvict) return false;
    final evicted = downloads.tryEvict(identity);
    if (evicted || session == null) _pendingDownloadEvictions.remove(identity);
    return evicted;
  }

  void _scheduleRetry(DownloadSession session) {
    if (_retryTimers.containsKey(session.identity) ||
        !session.hasDemand ||
        !session.failureRetryable ||
        session.isDisposed) {
      return;
    }
    final exponent = (session.failureCount - 1).clamp(0, 4).toInt();
    final delayMs = 400 * (1 << exponent);
    _retryTimers[session.identity] = Timer(Duration(milliseconds: delayMs), () {
      _retryTimers.remove(session.identity);
      if (session.isDisposed || !session.hasDemand) return;
      session.retryFailedTransport();
    });
  }

  void _cancelRetry(DownloadIdentity identity) {
    _retryTimers.remove(identity)?.cancel();
  }

  static String _downloadTaskKey(DownloadIdentity identity) =>
      'webp-network:${identity.imageKey}@${identity.sourceKey}@'
      '${identity.cid}@${identity.eid}';

  static String _decodeTaskKey(WebPDecodeSession session) {
    final identity = session.identity;
    return 'webp-decode:${identity.fullKey}:${identity.targetWidth}x'
        '${identity.targetHeight}:${session.download.identity.cacheKey}';
  }

  static String _uploadTaskKey(WebPDecodeSession session) {
    final identity = session.identity;
    return 'webp-upload:${identity.fullKey}:${identity.targetWidth}x'
        '${identity.targetHeight}:${session.download.identity.cacheKey}';
  }
}
