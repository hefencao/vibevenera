import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:venera/utils/webp_decoder.dart' as webp;
import 'package:venera/utils/webp_perf.dart';

import '../webp_source_registry.dart';

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

enum DownloadContentKind { unknown, webp, gif, fallback }

final class WebPSourceInvariantError implements Exception {
  final String message;
  final Object? cause;

  const WebPSourceInvariantError(this.message, [this.cause]);

  @override
  String toString() => cause == null
      ? 'WebP source invariant failed: $message'
      : 'WebP source invariant failed: $message ($cause)';
}

final class DownloadSessionSnapshot {
  final DownloadTransportState transport;
  final webp.NativeWebPSourceState source;
  final int desiredPriority;
  final int demandCount;
  final int dependentDecodeSessions;
  final int transportRevision;
  final int expectedLength;
  final int committedLength;
  final bool fallbackContent;
  final DownloadContentKind contentKind;
  final bool failureRetryable;
  final bool networkActive;
  final int failureCount;
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
    this.committedLength = 0,
    this.fallbackContent = false,
    this.contentKind = DownloadContentKind.unknown,
    this.failureRetryable = false,
    required this.networkActive,
    this.failureCount = 0,
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
  bool _failureRetryable = false;
  int _failureCount = 0;
  bool _expectedLengthAuthoritative = false;
  File? _artifactFile;
  bool _disposed = false;
  bool _publishScheduled = false;
  Timer? _bytePublishTimer;
  bool _reconcileScheduled = false;
  int _nextDemandId = 0;
  int _transportRevision = 0;
  int? _activeWriterRevision;
  DownloadWriterLease? _activeWriter;
  int _expectedLength;
  bool _fallbackContent = false;
  DownloadContentKind _contentKind = DownloadContentKind.unknown;
  bool _networkActive = false;
  int _fallbackCommittedLength = 0;
  int _dependentDecodeSessions = 0;

  DownloadSession({
    required this.identity,
    required this.source,
    required void Function(DownloadSession session) reconcile,
    int expectedLength = 0,
  }) : _reconcile = reconcile,
       _expectedLength = expectedLength;

  Stream<DownloadSessionSnapshot> get states => _states.stream;

  /// Atomically subscribes to live changes and emits the current snapshot
  /// first. Consumers never need a separate `listen` + `snapshot` sequence.
  Stream<DownloadSessionSnapshot> watch() {
    _checkActive();
    return Stream<DownloadSessionSnapshot>.multi((controller) {
      final subscription = _states.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.add(snapshot);
      controller.onCancel = subscription.cancel;
    });
  }

  DownloadTransportState get transport => _transport;
  int get desiredPriority =>
      _demands.values.fold(0, (a, b) => a > b.priority ? a : b.priority);
  int get demandCount => _demands.length;
  int get dependentDecodeSessions => _dependentDecodeSessions;
  int get transportRevision => _transportRevision;
  int get expectedLength => _expectedLength;
  bool get expectedLengthAuthoritative => _expectedLengthAuthoritative;
  bool get failureRetryable => _failureRetryable;
  int get failureCount => _failureCount;
  int get sourceCommittedLength => source.state.committedLength;
  int get committedLength =>
      _fallbackContent ? _fallbackCommittedLength : sourceCommittedLength;
  bool get fallbackContent => _fallbackContent;
  DownloadContentKind get contentKind => _contentKind;
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
    committedLength: committedLength,
    fallbackContent: _fallbackContent,
    contentKind: _contentKind,
    failureRetryable: _failureRetryable,
    networkActive: _networkActive,
    failureCount: _failureCount,
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
    _failureRetryable = false;
    _artifactFile = null;
    _networkActive = false;
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
      beginNetworkTransfer(writer);
      _setTransport(DownloadTransportState.receiving);
      return writer;
    }
    final next = beginTransport();
    beginNetworkTransfer(next);
    return next;
  }

  void beginNetworkTransfer(DownloadWriterLease writer) {
    _requireWriter(writer);
    if (_networkActive) return;
    _networkActive = true;
    _schedulePublish();
  }

  void updateExpectedLength(
    int? expectedLength, {
    DownloadWriterLease? writer,
    bool authoritative = false,
  }) {
    final activeWriter = _resolveWriter(writer);
    _requireWriter(activeWriter);
    final value = expectedLength ?? 0;
    if (value <= 0) return;

    // HTTP Content-Length on a resumed request may describe only the remaining
    // range. It is progress metadata, not a source invariant. Once the RIFF
    // header publishes its declared size, only another authoritative value may
    // replace it.
    if (_expectedLengthAuthoritative) {
      if (!authoritative) return;
      if (value != _expectedLength) {
        throw WebPSourceInvariantError(
          'conflicting authoritative lengths: $_expectedLength/$value',
        );
      }
      return;
    }
    if (value < committedLength) {
      if (authoritative) {
        throw WebPSourceInvariantError(
          'authoritative length $value is smaller than committed '
          '$committedLength',
        );
      }
      return;
    }
    if (value == _expectedLength &&
        (!authoritative || _expectedLengthAuthoritative)) {
      return;
    }
    _expectedLength = value;
    if (authoritative) _expectedLengthAuthoritative = true;
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
    if (_fallbackContent) {
      throw const WebPSourceInvariantError(
        'cannot append WebP bytes after entering fallback content mode',
      );
    }
    if (bytes.isEmpty) return;
    final committed = sourceCommittedLength;
    if (offset != committed) {
      throw WebPSourceInvariantError(
        'gap/overlap: expected offset=$committed, got=$offset, '
        'length=${bytes.length}, epoch=${activeWriter.sourceEpoch}, '
        'writer=${activeWriter.revision}',
      );
    }
    try {
      source.append(bytes, offset: offset);
    } catch (error) {
      throw WebPSourceInvariantError(
        'native append rejected epoch=${activeWriter.sourceEpoch}, '
        'offset=$offset, length=${bytes.length}',
        error,
      );
    }
    _scheduleBytePublish();
  }

  DownloadWriterLease resetSource({
    DownloadWriterLease? writer,
    required int epoch,
    int expectedLength = 0,
  }) {
    final activeWriter = _resolveWriter(writer);
    _requireWriter(activeWriter);
    if (epoch <= source.epoch) {
      throw WebPSourceInvariantError(
        'source epoch must increase: $epoch <= ${source.epoch}',
      );
    }
    try {
      source.reset(epoch: epoch, expectedLength: expectedLength);
    } catch (error) {
      throw WebPSourceInvariantError(
        'native reset rejected epoch=$epoch expected=$expectedLength',
        error,
      );
    }
    activeWriter._replaceEpoch(epoch);
    _fallbackContent = false;
    _contentKind = DownloadContentKind.unknown;
    _fallbackCommittedLength = 0;
    _expectedLength = expectedLength;
    _expectedLengthAuthoritative = false;
    _artifactFile = null;
    _error = null;
    _failureRetryable = false;
    _schedulePublish();
    return activeWriter;
  }

  /// Seals the current source. Both positional arguments are optional to keep
  /// the previous `session.seal()` call shape source-compatible.
  void seal([DownloadWriterLease? writer, File? artifactFile]) {
    final activeWriter = _resolveWriter(writer);
    _requireWriter(activeWriter);
    if (_fallbackContent) {
      throw const WebPSourceInvariantError(
        'fallback content must be finalized with sealFallback',
      );
    }
    if (_expectedLength > 0 && sourceCommittedLength != _expectedLength) {
      throw WebPSourceInvariantError(
        'cannot seal incomplete source: $sourceCommittedLength/$_expectedLength',
      );
    }
    try {
      source.seal();
    } catch (error) {
      throw WebPSourceInvariantError(
        'native seal rejected epoch=${activeWriter.sourceEpoch}, '
        'length=$sourceCommittedLength',
        error,
      );
    }
    _artifactFile = artifactFile;
    _failureRetryable = false;
    _failureCount = 0;
    _networkActive = false;
    _activeWriterRevision = null;
    _activeWriter = null;
    activeWriter._detach();
    _setTransport(DownloadTransportState.sealed);
    _scheduleReconcile();
  }

  /// Switches this download to the generic non-WebP artifact path.
  ///
  /// At most a small content-sniff prefix exists outside the artifact. No
  /// compressed WebP history is replayed through this path.
  void enterFallbackContent(
    DownloadWriterLease writer, {
    int restoredLength = 0,
    DownloadContentKind contentKind = DownloadContentKind.fallback,
  }) {
    _requireWriter(writer);
    if (contentKind != DownloadContentKind.gif &&
        contentKind != DownloadContentKind.fallback) {
      throw ArgumentError.value(contentKind, 'contentKind');
    }
    if (!_fallbackContent && sourceCommittedLength > 0) {
      final nextEpoch = source.epoch + 1;
      try {
        source.reset(epoch: nextEpoch, expectedLength: 0);
      } catch (error) {
        throw WebPSourceInvariantError(
          'failed to reset native source before fallback content',
          error,
        );
      }
      writer._replaceEpoch(nextEpoch);
    }
    _fallbackContent = true;
    _contentKind = contentKind;
    if (contentKind == DownloadContentKind.gif) {
      WebPSourceRegistry.markStreaming(identity.sourceKey);
    }
    _fallbackCommittedLength = restoredLength;
    _expectedLengthAuthoritative = false;
    _decodeSafePublish();
  }

  void identifyWebPContent(DownloadWriterLease writer) {
    _requireWriter(writer);
    if (_fallbackContent) {
      throw const WebPSourceInvariantError(
        'cannot identify WebP after entering fallback content mode',
      );
    }
    if (_contentKind == DownloadContentKind.webp) return;
    _contentKind = DownloadContentKind.webp;
    _schedulePublish();
  }

  void bindArtifact(DownloadWriterLease writer, File file) {
    _requireWriter(writer);
    if (_artifactFile?.path == file.path) return;
    _artifactFile = file;
    _schedulePublish();
  }

  /// Advances the persisted generic-content range. The artifact itself owns
  /// the bytes; the session owns only its contiguous length and lifecycle.
  void appendFallbackRange(
    DownloadWriterLease writer, {
    required int offset,
    required int length,
  }) {
    _requireWriter(writer);
    if (!_fallbackContent) enterFallbackContent(writer);
    if (length < 0 || offset != _fallbackCommittedLength) {
      throw WebPSourceInvariantError(
        'fallback range discontinuity: committed=$_fallbackCommittedLength, '
        'offset=$offset, length=$length',
      );
    }
    _fallbackCommittedLength += length;
    _scheduleBytePublish();
  }

  void sealFallback(
    DownloadWriterLease writer,
    File artifactFile, {
    required int finalLength,
  }) {
    _requireWriter(writer);
    if (!_fallbackContent || _fallbackCommittedLength != finalLength) {
      throw WebPSourceInvariantError(
        'invalid fallback seal: mode=$_fallbackContent, '
        'committed=$_fallbackCommittedLength, final=$finalLength',
      );
    }
    if (_expectedLength > 0 && finalLength != _expectedLength) {
      throw WebPSourceInvariantError(
        'fallback final length $finalLength does not match expected '
        '$_expectedLength',
      );
    }
    _artifactFile = artifactFile;
    _failureRetryable = false;
    _failureCount = 0;
    _networkActive = false;
    _activeWriterRevision = null;
    _activeWriter = null;
    writer._detach();
    _setTransport(DownloadTransportState.sealed);
    _scheduleReconcile();
  }

  void _decodeSafePublish() {
    _error = null;
    _failureRetryable = false;
    _schedulePublish();
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

  void fail(DownloadWriterLease writer, Object error, {bool retryable = true}) {
    if (!_isWriterActive(writer)) return;
    _activeWriterRevision = null;
    _activeWriter = null;
    writer._detach();
    _error = error;
    _failureRetryable = retryable;
    _failureCount++;
    _setTransport(DownloadTransportState.failed);
    _scheduleReconcile();
  }

  /// Compatibility alias for the old lifecycle API.
  void markFailed(Object error, {bool retryable = true}) {
    final writer = _activeWriter;
    if (writer != null) {
      fail(writer, error, retryable: retryable);
      return;
    }
    _error = error;
    _failureRetryable = retryable;
    _failureCount++;
    _setTransport(DownloadTransportState.failed);
    _scheduleReconcile();
  }

  /// Re-enters the paused state after coordinator backoff. The source and
  /// artifact remain unchanged and the next task resumes at committedLength.
  bool retryFailedTransport() {
    _checkActive();
    if (_transport != DownloadTransportState.failed ||
        !_failureRetryable ||
        _demands.isEmpty ||
        _activeWriter != null) {
      return false;
    }
    _failureRetryable = false;
    _error = null;
    _setTransport(DownloadTransportState.paused);
    _scheduleReconcile();
    return true;
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
    _bytePublishTimer?.cancel();
    _bytePublishTimer = null;
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
    _bytePublishTimer?.cancel();
    _bytePublishTimer = null;
    _publishScheduled = true;
    scheduleMicrotask(() {
      _publishScheduled = false;
      if (!_states.isClosed) _states.add(snapshot);
    });
  }

  void _scheduleBytePublish() {
    if (_publishScheduled || _bytePublishTimer != null || _states.isClosed) {
      return;
    }
    // Raw response chunks may arrive much faster than Flutter frames. Native
    // input remains lossless; only derived state notifications are coalesced.
    _bytePublishTimer = Timer(const Duration(milliseconds: 16), () {
      _bytePublishTimer = null;
      _schedulePublish();
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
  final webp.WebPByteSource Function(int expectedLength, int epoch)
  sourceFactory;

  DownloadSessionRegistry({
    required this.reconcile,
    webp.WebPByteSource Function(int expectedLength, int epoch)? sourceFactory,
  }) : sourceFactory =
           sourceFactory ??
           ((expectedLength, epoch) => webp.createNativeWebPSource(
             expectedLength: expectedLength,
             epoch: epoch,
           ));

  Iterable<DownloadSession> get sessions => _sessions.values;

  DownloadSession getOrCreate(
    DownloadIdentity identity, {
    int expectedLength = 0,
    int epoch = 1,
  }) => _sessions.putIfAbsent(
    identity,
    () => WebPPerf.sync(
      'downloadSession.create',
      () => DownloadSession(
        identity: identity,
        source: sourceFactory(expectedLength, epoch),
        reconcile: reconcile,
        expectedLength: expectedLength,
      ),
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
    for (final session in _sessions.values) {
      if (!session.canEvict) {
        throw StateError(
          'Cannot dispose active download session ${session.identity.cacheKey}',
        );
      }
    }
    for (final identity in _sessions.keys.toList()) {
      evict(identity);
    }
  }
}
