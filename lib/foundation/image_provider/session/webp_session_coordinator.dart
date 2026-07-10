import 'package:venera/foundation/image_provider/pipeline/task_scheduler.dart';
import 'package:venera/foundation/image_provider/pipeline/tasks.dart';
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

  const WebPResourceDemand({
    required this.downloadPriority,
    required this.decodePriority,
    required this.allowDownload,
    required this.allowDecode,
    required this.allowUpload,
    required this.current,
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
        );
      } else {
        lease.update(
          priority: demand.decodePriority,
          current: demand.current,
          decode: demand.allowDecode,
          upload: demand.allowUpload,
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
  final void Function(
    DownloadIdentity identity,
    WebPTransportProgress progress,
  )? onProgress;
  late final DownloadSessionRegistry downloads;
  late final WebPDecodeSessionRegistry decodes;
  final Set<WebPResourceLease> _leases = {};

  WebPSessionCoordinator({
    required this.scheduler,
    required this.transportFactory,
    this.onProgress,
    webp.WebPByteSource Function(int expectedLength, int epoch)? sourceFactory,
    webp.WebPFrameCursor Function(
      webp.WebPByteSource source,
      int targetWidth,
      int targetHeight,
    )? cursorFactory,
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
    final decode = decodes.getOrCreate(decodeIdentity, download);
    final lease = WebPResourceLease._(
      this,
      scopeId,
      download,
      decode,
      demand,
    );
    _leases.add(lease);
    return lease;
  }

  Set<String> get activeNetworkTaskKeys => {
    for (final session in downloads.sessions)
      if (session.hasDemand) _taskKey(session.identity),
  };

  Map<String, int> get networkPriorities => {
    for (final session in downloads.sessions)
      if (session.hasDemand)
        _taskKey(session.identity): session.desiredPriority,
  };

  void detachScope(String scopeId) {
    for (final lease in _leases.where((lease) => lease.scopeId == scopeId).toList()) {
      lease.detach();
    }
  }

  void evict(
    WebPDecodeIdentity decodeIdentity,
    DownloadIdentity downloadIdentity,
  ) {
    decodes.evict(decodeIdentity);
    downloads.evict(downloadIdentity);
  }

  void dispose() {
    for (final lease in _leases.toList()) {
      lease.detach();
    }
    decodes.dispose();
    downloads.dispose();
  }

  void _reconcileDownload(DownloadSession session) {
    final key = _taskKey(session.identity);
    if (!session.hasDemand) {
      if (session.transport != DownloadTransportState.receiving &&
          session.transport != DownloadTransportState.sealed) {
        scheduler.cancel(key);
      }
      return;
    }
    if (session.transport == DownloadTransportState.sealed ||
        session.transport == DownloadTransportState.failed) {
      return;
    }
    if (scheduler.hasTask(key)) return;
    scheduler.submit(WebPDownloadTask(
      key: key,
      generation: session.source.epoch,
      priority: session.desiredPriority,
      cancelable: true,
      session: session,
      transport: transportFactory(session.identity),
      onProgress: (progress) => onProgress?.call(session.identity, progress),
    ));
  }

  void _reconcileDecode(WebPDecodeSession session) {}

  static String _taskKey(DownloadIdentity identity) =>
      'webp:${identity.imageKey}@${identity.sourceKey}@'
      '${identity.cid}@${identity.eid}';
}
