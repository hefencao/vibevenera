import 'dart:async';
import 'dart:io';
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

  String get cacheKey => '$imageKey@$sourceKey@$cid@$eid';

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
  final int dependentDecodeSessions;
  final int transportRevision;
  final int expectedLength;
  final File? artifactFile;
  final Object? error;

  const DownloadSessionSnapshot({
    required this.transport,
    required this.source,
    required this.desiredPriority,
    required this.demandCount,
    required this.dependentDecodeSessions,
    required this.transportRevision,
    required this.expectedLength,
    required this.artifactFile,
    required this.error,
  });
}

/// Capability for exactly one active network writer.
///
/// A stale task may still receive callbacks after cancellation, but every
/// append/reset/seal operation is rejected once this writer is no longer active.
final class DownloadWriterLease {
  DownloadSession? _session;
  final int revision;
  int _sourceEpoch;

  DownloadWriterLease._(this._session, this.revision, this._sourceEpoch);

  int get sourceEpoch => _sourceEpoch;
  bool get active => _session?._isWriterActive(this) == true;

  void _replaceEpoch(int epoch) => _sourceEpoch = epoch;
  void _detach() => _session = null;
}

final class DownloadDemandLease {
  DownloadSession? _session;
  final int _id;
  final String scopeId;

  DownloadDemandLease._(this._session, this._id, this.scopeId);

  bool get attached => _session?._hasDemand(_id) == true;

  void updatePriority(int priority) => _session?._updateDemand(_id, priority);

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
      StreamController.broadcast();

  DownloadTransportState _transport = DownloadTransportState.idle;
  Object? _error;
  File? _artifactFile;
  bool _disposed = false;
  bool _publishScheduled = false;
  bool _reconcileScheduled = false;
  int _nextDemandId = 0;
  int _transportRevision = 0;
  int? _activeWriterRevision;
  DownloadWriterLease? _activeWriter;
  int _expectedLength;
  int _dependentDecodeSessions = 0;

  DownloadSession({
    required this.identity,
    required this.source,
    required void Function(DownloadSession session) reconcile,
    int expectedLength = 0,
  })  : _reconcile = reconcile,
        _expectedLength = expectedLength;

  Stream<DownloadSessionSnapshot> get states => _states.stream;
  DownloadTransportState get transport => _transport;
  int get desiredPriority =>
      _demands.values.fold(0, (a, b) => a > b.priority ? a : b.priority);
  int get demandCount => _demands.length;
  int get dependentDecodeSessions => _dependentDecodeSessions;
  int get transportRevision => _transportRevision;
  int get expectedLength => _expectedLength;
  int get committedLength => source.state.committedLength;
  bool get hasDemand => _demands.isNotEmpty;
  bool get isDisposed => _disposed;
  bool get canEvict =>
      !_disposed &&
      _demands.isEmpty &&
      _dependentDecodeSessions == 0 &&
      _activeWriter == null;

  DownloadSessionSnapshot get snapshot => DownloadSessionSnapshot(
        transport: _transport,
        source: source.state,
        desiredPriority: desiredPriority,
        demandCount: demandCount,
        dependentDecodeSessions: _dependentDecodeSessions,
        transportRevision: _transportRevision,
        expectedLength: _expectedLength,
        artifactFile: _artifactFile,
        error: _error,
      );

  DownloadDemandLease attach({required String scopeId, required int priority}) {
    _checkActive();
    final id = ++_nextDemandId;
    _demands[id] = _DownloadDemand(scopeId, priority);
    _demandChanged();
    return DownloadDemandLease._(this, id, scopeId);
  }

  void markQueued() {
    _checkActive();
    if (_transport == DownloadTransportState.sealed) return;
    _setTransport(DownloadTransportState.queued);
  }

  DownloadWriterLease beginTransport() {
    _checkActive();
    if (_activeWriter != null) {
      throw StateError(
        'Download session already has active writer $_activeWriterRevision',
      );
    }
    if (_transport == DownloadTransportState.sealed) {
      throw StateError('Cannot start a sealed download session');
    }
    final revision = ++_transportRevision;
    final writer = DownloadWriterLease._(this, revision, source.epoch);
    _activeWriterRevision = revision;
    _activeWriter = writer;
    _error = null;
    _artifactFile = null;
    _setTransport(DownloadTransportState.receiving);
    return writer;
  }

  /// Returns the writer created by the scheduler-facing download task.
  ///
  /// `WebPTransport.execute` intentionally keeps its legacy one-positional-
  /// argument signature so existing test transports and custom transports do
  /// not all need to change at once. Production transports must obtain this
  /// capability before mutating the source.
  DownloadWriterLease requireActiveWriter() {
    _checkActive();
    final writer = _activeWriter;
    if (writer == null || !_isWriterActive(writer)) {
      throw StateError('Download session has no active writer');
    }
    return writer;
  }

  /// Compatibility entry point for code written against the pre-Phase-3 API.
  /// Calling this while a scheduler writer is active is idempotent.
  DownloadWriterLease markReceiving() {
    _checkActive();
    final writer = _activeWriter;
    if (writer != null) {
      _setTransport(DownloadTransportState.receiving);
      return writer;
    }
    return beginTransport();
  }

  void updateExpectedLength(
    int? expectedLength, {
    DownloadWriterLease? writer,
  }) {
    final activeWriter = _resolveWriter(writer);
    _requireWriter(activeWriter);
    final value = expectedLength ?? 0;
    if (value <= 0 || value == _expectedLength) return;
    if (value < committedLength) {
      throw StateError(
        'Expected length $value is smaller than committed $committedLength',
      );
    }
    _expectedLength = value;
    _schedulePublish();
  }

  /// Appends bytes at an explicit offset.
  ///
  /// New transport code passes [writer]. The optional form is retained for
  /// existing restore helpers and tests; it resolves to the single active
  /// writer (or creates a legacy writer when no scheduler task is involved).
  void append(
    Uint8List bytes, {
    required int offset,
    DownloadWriterLease? writer,
  }) {
    final activeWriter = _resolveWriter(writer);
    _requireWriter(activeWriter);
    if (bytes.isEmpty) return;
    final committed = committedLength;
    if (offset != committed) {
      throw StateError(
        'WebP source gap/overlap: expected offset=$committed, got=$offset, '
        'length=${bytes.length}, epoch=${activeWriter.sourceEpoch}, '
        'writer=${activeWriter.revision}',
      );
    }
    source.append(bytes, offset: offset);
    _schedulePublish();
  }

  DownloadWriterLease resetSource({
    DownloadWriterLease? writer,
    required int epoch,
    int expectedLength = 0,
  }) {
    final activeWriter = _resolveWriter(writer);
    _requireWriter(activeWriter);
    if (epoch <= source.epoch) {
      throw StateError('Source epoch must increase: $epoch <= ${source.epoch}');
    }
    source.reset(epoch: epoch, expectedLength: expectedLength);
    activeWriter._replaceEpoch(epoch);
    _expectedLength = expectedLength;
    _artifactFile = null;
    _error = null;
    _schedulePublish();
    return activeWriter;
  }

  /// Seals the current source. Both positional arguments are optional to keep
  /// the previous `session.seal()` call shape source-compatible.
  void seal([DownloadWriterLease? writer, File? artifactFile]) {
    final activeWriter = _resolveWriter(writer);
    _requireWriter(activeWriter);
    if (_expectedLength > 0 && committedLength != _expectedLength) {
      throw StateError(
        'Cannot seal incomplete source: $committedLength/$_expectedLength',
      );
    }
    source.seal();
    _artifactFile = artifactFile;
    _activeWriterRevision = null;
    _activeWriter = null;
    activeWriter._detach();
    _setTransport(DownloadTransportState.sealed);
    _scheduleReconcile();
  }

  void pause(DownloadWriterLease writer) {
    if (!_isWriterActive(writer)) return;
    _activeWriterRevision = null;
    _activeWriter = null;
    writer._detach();
    _setTransport(DownloadTransportState.paused);
    _scheduleReconcile();
  }

  /// Compatibility alias for the old lifecycle API.
  void markPaused() {
    final writer = _activeWriter;
    if (writer != null) {
      pause(writer);
      return;
    }
    _setTransport(DownloadTransportState.paused);
    _scheduleReconcile();
  }

  void fail(DownloadWriterLease writer, Object error) {
    if (!_isWriterActive(writer)) return;
    _activeWriterRevision = null;
    _activeWriter = null;
    writer._detach();
    _error = error;
    _setTransport(DownloadTransportState.failed);
    _scheduleReconcile();
  }

  /// Compatibility alias for the old lifecycle API.
  void markFailed(Object error) {
    final writer = _activeWriter;
    if (writer != null) {
      fail(writer, error);
      return;
    }
    _error = error;
    _setTransport(DownloadTransportState.failed);
    _scheduleReconcile();
  }

  void retainDecodeSession() {
    _checkActive();
    _dependentDecodeSessions++;
    _schedulePublish();
  }

  void releaseDecodeSession() {
    if (_disposed) return;
    if (_dependentDecodeSessions <= 0) {
      throw StateError('Unbalanced DownloadSession decode dependency');
    }
    _dependentDecodeSessions--;
    _schedulePublish();
    _scheduleReconcile();
  }

  void evict() {
    if (_disposed) return;
    if (!canEvict) {
      throw StateError(
        'Cannot evict download session: demands=${_demands.length}, '
        'decodes=$_dependentDecodeSessions, writer=$_activeWriterRevision',
      );
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
    // A failed transport is terminal for the current demand epoch. A later
    // attach/priority change is an explicit retry signal and reuses the same
    // source/artifact instead of constructing a second session.
    if (_transport == DownloadTransportState.failed && _demands.isNotEmpty) {
      _transport = DownloadTransportState.paused;
      _error = null;
    }
    _schedulePublish();
    _scheduleReconcile();
  }

  DownloadWriterLease _resolveWriter(DownloadWriterLease? writer) {
    _checkActive();
    if (writer != null) return writer;
    final activeWriter = _activeWriter;
    if (activeWriter != null) return activeWriter;
    // Transitional compatibility for direct session mutation in existing
    // tests/helpers. Scheduler-driven production code always supplies the
    // writer returned by beginTransport().
    return beginTransport();
  }

  bool _isWriterActive(DownloadWriterLease writer) =>
      !_disposed &&
      identical(writer._session, this) &&
      identical(writer, _activeWriter) &&
      writer.revision == _activeWriterRevision &&
      writer.sourceEpoch == source.epoch;

  void _requireWriter(DownloadWriterLease writer) {
    _checkActive();
    if (!_isWriterActive(writer)) {
      throw StateError(
        'Stale WebP writer: writer=${writer.revision}/${writer.sourceEpoch}, '
        'active=$_activeWriterRevision/${source.epoch}',
      );
    }
  }

  void _setTransport(DownloadTransportState state) {
    _checkActive();
    if (_transport == state) return;
    _transport = state;
    _schedulePublish();
  }

  void _schedulePublish() {
    if (_publishScheduled || _states.isClosed) return;
    _publishScheduled = true;
    scheduleMicrotask(() {
      _publishScheduled = false;
      if (!_states.isClosed) _states.add(snapshot);
    });
  }

  void _scheduleReconcile() {
    if (_reconcileScheduled || _disposed) return;
    _reconcileScheduled = true;
    scheduleMicrotask(() {
      _reconcileScheduled = false;
      if (!_disposed) _reconcile(this);
    });
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
          expectedLength: expectedLength,
        ),
      );

  DownloadSession? find(DownloadIdentity identity) => _sessions[identity];

  void detachScope(String scopeId) {
    for (final session in _sessions.values) {
      session._removeScope(scopeId);
    }
  }

  bool tryEvict(DownloadIdentity identity) {
    final session = _sessions[identity];
    if (session == null || !session.canEvict) return false;
    session.evict();
    _sessions.remove(identity);
    return true;
  }

  /// Explicit physical eviction. Logical detach must use [detachScope].
  ///
  /// Kept alongside [tryEvict] for compatibility with the pre-Phase-3
  /// registry API and existing coordinator/tests.
  void evict(DownloadIdentity identity) {
    final session = _sessions[identity];
    if (session == null) return;
    if (!session.canEvict) {
      throw StateError(
        'Cannot evict active download session ${identity.cacheKey}',
      );
    }
    session.evict();
    _sessions.remove(identity);
  }

  void evictUndemanded() {
    for (final identity in _sessions.keys.toList()) {
      tryEvict(identity);
    }
  }

  void dispose() {
    for (final identity in _sessions.keys.toList()) {
      final session = _sessions[identity]!;
      if (!session.canEvict) continue;
      session.evict();
      _sessions.remove(identity);
    }
  }
}
