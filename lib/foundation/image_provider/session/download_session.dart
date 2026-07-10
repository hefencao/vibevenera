import 'dart:async';
import 'dart:typed_data';

import 'package:venera/utils/webp_decoder.dart' as webp;

final class DownloadIdentity {
  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;

  const DownloadIdentity({
    required this.imageKey,
    required this.sourceKey,
    required this.cid,
    required this.eid,
  });

  @override
  bool operator ==(Object other) =>
      other is DownloadIdentity &&
      imageKey == other.imageKey &&
      sourceKey == other.sourceKey &&
      cid == other.cid &&
      eid == other.eid;

  @override
  int get hashCode => Object.hash(imageKey, sourceKey, cid, eid);
}

enum DownloadTransportState { idle, queued, receiving, paused, sealed, failed }

final class DownloadSessionSnapshot {
  final DownloadTransportState transport;
  final webp.NativeWebPSourceState source;
  final int desiredPriority;
  final int demandCount;
  final Object? error;

  const DownloadSessionSnapshot({
    required this.transport,
    required this.source,
    required this.desiredPriority,
    required this.demandCount,
    required this.error,
  });
}

final class DownloadDemandLease {
  DownloadSession? _session;
  final int _id;
  final String scopeId;

  DownloadDemandLease._(this._session, this._id, this.scopeId);

  bool get attached => _session?._hasDemand(_id) == true;

  void updatePriority(int priority) =>
      _session?._updateDemand(_id, priority);

  void detach() {
    final session = _session;
    if (session == null) return;
    _session = null;
    session._removeDemand(_id);
  }
}

final class _DownloadDemand {
  final String scopeId;
  int priority;
  _DownloadDemand(this.scopeId, this.priority);
}

final class DownloadSession {
  final DownloadIdentity identity;
  final webp.WebPByteSource source;
  final void Function(DownloadSession session) _reconcile;
  final Map<int, _DownloadDemand> _demands = {};
  final StreamController<DownloadSessionSnapshot> _states =
      StreamController.broadcast(sync: true);
  DownloadTransportState _transport = DownloadTransportState.idle;
  Object? _error;
  bool _disposed = false;
  int _nextDemandId = 0;

  DownloadSession({
    required this.identity,
    required this.source,
    required void Function(DownloadSession session) reconcile,
  }) : _reconcile = reconcile;

  Stream<DownloadSessionSnapshot> get states => _states.stream;
  DownloadTransportState get transport => _transport;
  int get desiredPriority =>
      _demands.values.fold(0, (a, b) => a > b.priority ? a : b.priority);
  int get demandCount => _demands.length;
  bool get hasDemand => _demands.isNotEmpty;
  bool get isDisposed => _disposed;

  DownloadSessionSnapshot get snapshot => DownloadSessionSnapshot(
    transport: _transport,
    source: source.state,
    desiredPriority: desiredPriority,
    demandCount: demandCount,
    error: _error,
  );

  DownloadDemandLease attach({required String scopeId, required int priority}) {
    _checkActive();
    final id = ++_nextDemandId;
    _demands[id] = _DownloadDemand(scopeId, priority);
    _demandChanged();
    return DownloadDemandLease._(this, id, scopeId);
  }

  void append(Uint8List bytes, {required int offset}) {
    _checkActive();
    source.append(bytes, offset: offset);
    _publish();
  }

  void resetSource({required int epoch, int expectedLength = 0}) {
    _checkActive();
    source.reset(epoch: epoch, expectedLength: expectedLength);
    _transport = DownloadTransportState.idle;
    _error = null;
    _publish();
    _reconcile(this);
  }

  void markQueued() => _setTransport(DownloadTransportState.queued);
  void markReceiving() => _setTransport(DownloadTransportState.receiving);
  void markPaused() => _setTransport(DownloadTransportState.paused);

  void seal() {
    _checkActive();
    source.seal();
    _setTransport(DownloadTransportState.sealed);
  }

  void markFailed(Object error) {
    _checkActive();
    _error = error;
    _setTransport(DownloadTransportState.failed);
  }

  void evict() {
    if (_disposed) return;
    if (_demands.isNotEmpty) {
      throw StateError('Cannot evict a demanded download session');
    }
    _disposed = true;
    source.dispose();
    _states.close();
  }

  void _updateDemand(int id, int priority) {
    _checkActive();
    final demand = _demands[id];
    if (demand == null || demand.priority == priority) return;
    demand.priority = priority;
    _demandChanged();
  }

  bool _hasDemand(int id) => !_disposed && _demands.containsKey(id);

  void _removeDemand(int id) {
    if (_disposed || _demands.remove(id) == null) return;
    _demandChanged();
  }

  void _removeScope(String scopeId) {
    if (_disposed) return;
    final before = _demands.length;
    _demands.removeWhere((_, demand) => demand.scopeId == scopeId);
    if (_demands.length != before) _demandChanged();
  }

  void _demandChanged() {
    _publish();
    _reconcile(this);
  }

  void _setTransport(DownloadTransportState state) {
    _checkActive();
    if (_transport == state) return;
    _transport = state;
    _publish();
  }

  void _publish() {
    if (!_states.isClosed) _states.add(snapshot);
  }

  void _checkActive() {
    if (_disposed) throw StateError('Download session is evicted');
  }
}

final class DownloadSessionRegistry {
  final Map<DownloadIdentity, DownloadSession> _sessions = {};
  final void Function(DownloadSession session) reconcile;
  final webp.WebPByteSource Function(int expectedLength, int epoch) sourceFactory;

  DownloadSessionRegistry({
    required this.reconcile,
    webp.WebPByteSource Function(int expectedLength, int epoch)? sourceFactory,
  }) : sourceFactory = sourceFactory ??
            ((expectedLength, epoch) => webp.createNativeWebPSource(
              expectedLength: expectedLength,
              epoch: epoch,
            ));

  Iterable<DownloadSession> get sessions => _sessions.values;

  DownloadSession getOrCreate(
    DownloadIdentity identity, {
    int expectedLength = 0,
    int epoch = 1,
  }) =>
      _sessions.putIfAbsent(
        identity,
        () => DownloadSession(
          identity: identity,
          source: sourceFactory(expectedLength, epoch),
          reconcile: reconcile,
        ),
      );

  DownloadSession? find(DownloadIdentity identity) => _sessions[identity];

  void detachScope(String scopeId) {
    for (final session in _sessions.values) {
      session._removeScope(scopeId);
    }
  }

  void evict(DownloadIdentity identity) {
    final session = _sessions[identity];
    if (session == null) return;
    session.evict();
    _sessions.remove(identity);
  }

  void dispose() {
    for (final session in _sessions.values) {
      if (session.hasDemand) {
        throw StateError('Cannot dispose demanded download sessions');
      }
    }
    for (final session in _sessions.values) {
      session.evict();
    }
    _sessions.clear();
  }
}
