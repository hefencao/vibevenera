import 'dart:async';

import 'package:venera/foundation/image_provider/renderer/frame_renderer.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'webp_frame_holder.dart';

final class WebPDecodeIdentity {
  final String fullKey;
  final int targetWidth;
  final int targetHeight;

  const WebPDecodeIdentity({
    required this.fullKey,
    required this.targetWidth,
    required this.targetHeight,
  });

  @override
  bool operator ==(Object other) =>
      other is WebPDecodeIdentity &&
      fullKey == other.fullKey &&
      targetWidth == other.targetWidth &&
      targetHeight == other.targetHeight;

  @override
  int get hashCode => Object.hash(fullKey, targetWidth, targetHeight);
}

final class WebPDecodeSessionSnapshot {
  final DownloadSessionSnapshot download;
  final webp.NativeWebPPlaybackCursorState cursor;
  final int desiredPriority;
  final int demandCount;
  final int decodeDemandCount;
  final int uploadDemandCount;
  final int decodeRevision;
  final int uploadRevision;
  final WebPFrameHolderSnapshot frames;
  final Object? decodeError;
  final Object? uploadError;
  final bool nativeExhaustedWithoutFrames;

  const WebPDecodeSessionSnapshot({
    required this.download,
    required this.cursor,
    required this.desiredPriority,
    required this.demandCount,
    required this.decodeDemandCount,
    required this.uploadDemandCount,
    required this.decodeRevision,
    required this.uploadRevision,
    required this.frames,
    required this.decodeError,
    required this.uploadError,
    this.nativeExhaustedWithoutFrames = false,
  });
}

final class WebPDecodeDemandLease {
  WebPDecodeSession? _session;
  final int _id;
  final String scopeId;

  WebPDecodeDemandLease._(this._session, this._id, this.scopeId);

  bool get attached => _session?._hasDemand(_id) == true;

  void update({
    required int priority,
    required bool current,
    required bool decode,
    required bool upload,
  }) =>
      _session?._updateDemand(_id, priority, current, decode, upload);

  void detach() {
    final session = _session;
    if (session == null) return;
    _session = null;
    session._removeDemand(_id);
  }
}

final class _WebPDecodeDemand {
  final String scopeId;
  int priority;
  bool current;
  bool decode;
  bool upload;

  _WebPDecodeDemand(
    this.scopeId,
    this.priority,
    this.current,
    this.decode,
    this.upload,
  );
}

final class WebPDecodeClaim {
  final int decodeRevision;
  final int sourceEpoch;
  final int sourceCommittedLength;
  final int reservedFrames;
  bool _completed = false;

  WebPDecodeClaim._({
    required this.decodeRevision,
    required this.sourceEpoch,
    required this.sourceCommittedLength,
    required this.reservedFrames,
  });
}

final class WebPUploadClaim {
  final int uploadRevision;
  final NativeFrameHandle frame;
  bool _completed = false;

  WebPUploadClaim._({
    required this.uploadRevision,
    required this.frame,
  });
}

final class WebPDecodeSession {
  final WebPDecodeIdentity identity;
  final DownloadSession download;
  final webp.WebPFrameCursor cursor;
  late final WebPFrameHolder holder;
  final void Function(WebPDecodeSession session) _reconcile;
  final Map<int, _WebPDecodeDemand> _demands = {};
  final StreamController<WebPDecodeSessionSnapshot> _states =
      StreamController.broadcast();
  late final StreamSubscription<DownloadSessionSnapshot> _downloadSubscription;

  bool _disposed = false;
  bool _publishScheduled = false;
  bool _reconcileScheduled = false;
  int _nextDemandId = 0;
  int _decodeRevision = 1;
  int _uploadRevision = 1;
  int _observedSourceEpoch;
  int _observedCommittedLength;
  DownloadTransportState _observedTransport;
  int? _decodeBlockedAtCommittedLength;
  int _decodedFramesSinceRestart = 0;
  bool _hasProducedFrame = false;
  Object? _decodeError;
  Object? _uploadError;

  WebPDecodeSession({
    required this.identity,
    required this.download,
    required this.cursor,
    required void Function(WebPDecodeSession session) reconcile,
  })  : _reconcile = reconcile,
        _observedSourceEpoch = download.source.epoch,
        _observedCommittedLength = download.sourceCommittedLength,
        _observedTransport = download.transport {
    download.retainDecodeSession();
    holder = WebPFrameHolder(onDemand: _scheduleReconcile);
    _downloadSubscription = download.states.listen(_onDownloadState);
  }

  Stream<WebPDecodeSessionSnapshot> get states => _states.stream;

  /// Atomically emits the current state followed by ordered live updates.
  Stream<WebPDecodeSessionSnapshot> watch() {
    _checkActive();
    return Stream<WebPDecodeSessionSnapshot>.multi((controller) {
      final subscription = _states.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.add(snapshot);
      controller.onCancel = subscription.cancel;
    });
  }

  bool get isDisposed => _disposed;
  bool get canEvict =>
      !_disposed &&
      _demands.isEmpty &&
      holder.decodeInFlight == 0 &&
      holder.uploadInFlight == 0;
  int get demandCount => _demands.length;
  int get decodeDemandCount =>
      _demands.values.where((demand) => demand.decode).length;
  int get uploadDemandCount =>
      _demands.values.where((demand) => demand.upload).length;
  bool get shouldDecode => decodeDemandCount > 0;
  bool get shouldUpload => uploadDemandCount > 0;
  bool get sourceDecodable => !download.fallbackContent;
  bool get hasProducedFrame => _hasProducedFrame;
  bool get canScheduleDecode {
    if (!shouldDecode || !sourceDecodable) return false;
    final committed = download.sourceCommittedLength;
    if (_decodeBlockedAtCommittedLength != committed) return true;
    if (holder.queuedFrameCount > 0 || holder.uploadInFlight > 0) {
      return false;
    }
    return _decodedFramesSinceRestart > 0;
  }

  bool get nativeExhaustedWithoutFrames =>
      download.transport == DownloadTransportState.sealed &&
      !_hasProducedFrame &&
      _decodeBlockedAtCommittedLength == download.sourceCommittedLength &&
      holder.decodeInFlight == 0;
  bool get isCurrent => _demands.values.any((demand) => demand.current);
  int get desiredPriority =>
      _demands.values.fold(0, (a, b) => a > b.priority ? a : b.priority);
  int get decodePriority => _demands.values
      .where((demand) => demand.decode)
      .fold(0, (a, b) => a > b.priority ? a : b.priority);
  int get uploadPriority => _demands.values
      .where((demand) => demand.upload)
      .fold(0, (a, b) => a > b.priority ? a : b.priority);
  int get decodeRevision => _decodeRevision;
  int get uploadRevision => _uploadRevision;
  bool get decodeFailed => _decodeError != null;
  bool get uploadFailed => _uploadError != null;

  void requestReconcile() => _scheduleReconcile();

  WebPDecodeSessionSnapshot get snapshot => WebPDecodeSessionSnapshot(
        download: download.snapshot,
        cursor: cursor.state,
        desiredPriority: desiredPriority,
        demandCount: demandCount,
        decodeDemandCount: decodeDemandCount,
        uploadDemandCount: uploadDemandCount,
        decodeRevision: _decodeRevision,
        uploadRevision: _uploadRevision,
        frames: holder.snapshot,
        decodeError: _decodeError,
        uploadError: _uploadError,
        nativeExhaustedWithoutFrames: nativeExhaustedWithoutFrames,
      );

  WebPDecodeDemandLease attach({
    required String scopeId,
    required int priority,
    required bool current,
    required bool decode,
    required bool upload,
  }) {
    _checkActive();
    final beforeDecode = shouldDecode;
    final beforeUpload = shouldUpload;
    final id = ++_nextDemandId;
    _demands[id] = _WebPDecodeDemand(
      scopeId,
      priority,
      current,
      decode,
      upload,
    );
    _demandChanged(beforeDecode, beforeUpload);
    return WebPDecodeDemandLease._(this, id, scopeId);
  }

  WebPDecodeClaim? tryClaimDecode({
    required int expectedRevision,
    int maxBatch = 2,
  }) {
    _checkActive();
    _syncSourceEpoch();
    if (expectedRevision != _decodeRevision ||
        !shouldDecode ||
        !sourceDecodable) {
      return null;
    }

    final committed = download.sourceCommittedLength;
    final cursorState = cursor.state;
    if (!cursorState.ready ||
        cursorState.targetWidth <= 0 ||
        cursorState.targetHeight <= 0) {
      _decodeBlockedAtCommittedLength = committed;
      _schedulePublish();
      return null;
    }

    if (_decodeBlockedAtCommittedLength == committed) {
      // A playback pass may restart only after every frame produced by that
      // pass has left the holder. This works for both partial and sealed
      // sources: partial input loops the currently complete ANMF frames while
      // new bytes continue to append to the shared source.
      if (holder.queuedFrameCount > 0 || holder.uploadInFlight > 0) {
        return null;
      }
      // An empty pass means the source has not published a complete frame yet.
      // Keep the session blocked until committedLength changes instead of
      // spinning restart/decode on an incomplete RIFF chunk.
      if (_decodedFramesSinceRestart <= 0) return null;
      cursor.restart();
      _decodedFramesSinceRestart = 0;
      _decodeBlockedAtCommittedLength = null;
    }

    final reserved = holder.claimDecodeBudget(maxBatch: maxBatch);
    if (reserved <= 0) return null;
    return WebPDecodeClaim._(
      decodeRevision: _decodeRevision,
      sourceEpoch: download.source.epoch,
      sourceCommittedLength: committed,
      reservedFrames: reserved,
    );
  }

  List<NativeFrameHandle> decode(WebPDecodeClaim claim) {
    _checkActive();
    if (claim._completed) throw StateError('Decode claim is already completed');
    if (!_isDecodeClaimCurrent(claim)) return const [];

    final decoded = cursor.decodeFrames(claim.reservedFrames);
    if (decoded.isEmpty) return const [];

    final state = cursor.state;
    if (!state.ready || state.targetWidth <= 0 || state.targetHeight <= 0) {
      for (final frame in decoded) {
        webp.nativePoolRelease(frame.address);
      }
      throw StateError('Playback cursor produced frames before target size');
    }

    return decoded
        .map(
          (frame) => NativeFrameHandle(
            address: frame.address,
            width: state.targetWidth,
            height: state.targetHeight,
            durationMs: frame.durationMs,
          ),
        )
        .toList(growable: false);
  }

  List<NativeFrameHandle> importDecodedFrames(
    WebPDecodeClaim claim,
    List<webp.WebPAnimFrameAddress> decoded,
  ) {
    _checkActive();
    if (claim._completed || !_isDecodeClaimCurrent(claim)) {
      for (final frame in decoded) {
        webp.nativePoolRelease(frame.address);
      }
      return const [];
    }
    final state = cursor.state;
    if (!state.ready || state.targetWidth <= 0 || state.targetHeight <= 0) {
      for (final frame in decoded) {
        webp.nativePoolRelease(frame.address);
      }
      throw StateError('Playback cursor produced frames before target size');
    }
    return decoded
        .map(
          (frame) => NativeFrameHandle(
            address: frame.address,
            width: state.targetWidth,
            height: state.targetHeight,
            durationMs: frame.durationMs,
          ),
        )
        .toList(growable: false);
  }

  void completeDecode(
    WebPDecodeClaim claim,
    List<NativeFrameHandle> frames, {
    Object? error,
    bool discard = false,
  }) {
    if (claim._completed) {
      for (final frame in frames) {
        frame.release();
      }
      return;
    }
    claim._completed = true;

    final stale = discard || _disposed || !_isDecodeClaimCurrent(claim);
    if (stale) {
      for (final frame in frames) {
        frame.release();
      }
      if (!holder.isDisposed) {
        holder.finishDecodeClaim(claim.reservedFrames, const []);
      }
      _scheduleReconcile();
      return;
    }

    if (error != null) {
      _decodeError = error;
      holder.finishDecodeClaim(claim.reservedFrames, const []);
    } else {
      _decodeError = null;
      if (frames.isEmpty) {
        _decodeBlockedAtCommittedLength = claim.sourceCommittedLength;
      } else {
        _decodedFramesSinceRestart += frames.length;
        _hasProducedFrame = true;
        _decodeBlockedAtCommittedLength = null;
      }
      holder.finishDecodeClaim(claim.reservedFrames, frames);
    }
    _schedulePublish();
    _scheduleReconcile();
  }

  WebPUploadClaim? tryClaimUpload({required int expectedRevision}) {
    _checkActive();
    if (expectedRevision != _uploadRevision || !shouldUpload) return null;
    final frame = holder.claimRawFrame();
    if (frame == null) return null;
    return WebPUploadClaim._(
      uploadRevision: _uploadRevision,
      frame: frame,
    );
  }

  void completeUpload(
    WebPUploadClaim claim,
    RenderedFrameHandle? rendered, {
    Object? error,
    bool discard = false,
  }) {
    if (claim._completed) {
      rendered?.dispose();
      return;
    }
    claim._completed = true;

    final stale = discard ||
        _disposed ||
        claim.uploadRevision != _uploadRevision ||
        !shouldUpload;
    if (stale) {
      rendered?.dispose();
      if (!holder.isDisposed) holder.finishUploadClaim(null);
      _scheduleReconcile();
      return;
    }

    _uploadError = error;
    holder.finishUploadClaim(error == null ? rendered : null);
    if (error != null) rendered?.dispose();
    _schedulePublish();
    _scheduleReconcile();
  }

  void restartCursor() {
    _checkActive();
    _decodeRevision++;
    _uploadRevision++;
    cursor.restart();
    _decodeBlockedAtCommittedLength = null;
    _decodedFramesSinceRestart = 0;
    holder.clearBufferedFrames();
    _decodeError = null;
    _uploadError = null;
    _schedulePublish();
    _scheduleReconcile();
  }

  void evict() {
    if (_disposed) return;
    if (!canEvict) {
      throw StateError(
        'Cannot evict decode session: demands=${_demands.length}, '
        'decodeInFlight=${holder.decodeInFlight}, '
        'uploadInFlight=${holder.uploadInFlight}',
      );
    }
    _disposed = true;
    _decodeRevision++;
    _uploadRevision++;
    unawaited(_downloadSubscription.cancel());
    holder.dispose();
    cursor.dispose();
    download.releaseDecodeSession();
    _states.close();
  }

  void _updateDemand(
    int id,
    int priority,
    bool current,
    bool decode,
    bool upload,
  ) {
    _checkActive();
    final demand = _demands[id];
    if (demand == null) return;
    if (demand.priority == priority &&
        demand.current == current &&
        demand.decode == decode &&
        demand.upload == upload) {
      return;
    }
    final beforeDecode = shouldDecode;
    final beforeUpload = shouldUpload;
    demand.priority = priority;
    demand.current = current;
    demand.decode = decode;
    demand.upload = upload;
    _demandChanged(beforeDecode, beforeUpload);
  }

  bool _hasDemand(int id) => !_disposed && _demands.containsKey(id);

  void _removeDemand(int id) {
    if (_disposed) return;
    final beforeDecode = shouldDecode;
    final beforeUpload = shouldUpload;
    if (_demands.remove(id) != null) {
      _demandChanged(beforeDecode, beforeUpload);
    }
  }

  void _removeScope(String scopeId) {
    if (_disposed) return;
    final beforeDecode = shouldDecode;
    final beforeUpload = shouldUpload;
    final count = _demands.length;
    _demands.removeWhere((_, demand) => demand.scopeId == scopeId);
    if (_demands.length != count) {
      _demandChanged(beforeDecode, beforeUpload);
    }
  }

  void _demandChanged(bool beforeDecode, bool beforeUpload) {
    // Priority/current changes update queued/running task priority in place.
    // Revisions invalidate work only when stage permission changes.
    if (beforeDecode != shouldDecode) {
      _decodeRevision++;
      _decodeError = null;
    }
    if (beforeUpload != shouldUpload) {
      _uploadRevision++;
      _uploadError = null;
    }
    holder.updateDemand(
      WebPFrameDemand(
        current: isCurrent,
        decode: shouldDecode,
        upload: shouldUpload,
        // Settling may disable upload while still decoding. Keep already decoded
        // native frames so policy changes do not force a decode loop.
        retainRaw: shouldDecode || shouldUpload,
      ),
    );
    _schedulePublish();
    _scheduleReconcile();
  }

  void _onDownloadState(DownloadSessionSnapshot snapshot) {
    if (_disposed) return;
    _syncSourceEpoch();
    final committed = snapshot.source.committedLength;
    final becameSealed = snapshot.transport == DownloadTransportState.sealed &&
        _observedTransport != DownloadTransportState.sealed;
    _observedTransport = snapshot.transport;
    if (committed != _observedCommittedLength || becameSealed) {
      _observedCommittedLength = committed;
      _decodeBlockedAtCommittedLength = null;
      // New bytes or final index publication may make a previously incomplete
      // frame decodable. Sealed-source errors produced after this final pass are
      // terminal because neither length nor index can advance again.
      _decodeError = null;
    }
    _schedulePublish();
    _scheduleReconcile();
  }

  void _syncSourceEpoch() {
    final epoch = download.source.epoch;
    if (epoch == _observedSourceEpoch) return;
    _observedSourceEpoch = epoch;
    _observedCommittedLength = download.sourceCommittedLength;
    _observedTransport = download.transport;
    _decodeRevision++;
    _uploadRevision++;
    _decodeBlockedAtCommittedLength = null;
    _decodedFramesSinceRestart = 0;
    _hasProducedFrame = false;
    _decodeError = null;
    _uploadError = null;
    cursor.rebindSource();
    holder.clearBufferedFrames();
  }

  bool _isDecodeClaimCurrent(WebPDecodeClaim claim) =>
      !_disposed &&
      claim.decodeRevision == _decodeRevision &&
      claim.sourceEpoch == download.source.epoch &&
      shouldDecode;

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
    if (_disposed) throw StateError('Decode session is evicted');
  }
}

final class WebPDecodeSessionRegistry {
  final Map<WebPDecodeIdentity, WebPDecodeSession> _sessions = {};
  final void Function(WebPDecodeSession session) reconcile;
  final webp.WebPFrameCursor Function(
    webp.WebPByteSource source,
    int targetWidth,
    int targetHeight,
  ) cursorFactory;

  WebPDecodeSessionRegistry({
    required this.reconcile,
    webp.WebPFrameCursor Function(
      webp.WebPByteSource source,
      int targetWidth,
      int targetHeight,
    )? cursorFactory,
  }) : cursorFactory = cursorFactory ?? _createNativeCursor;

  Iterable<WebPDecodeSession> get sessions => _sessions.values;

  WebPDecodeSession getOrCreate(
    WebPDecodeIdentity identity,
    DownloadSession download,
  ) {
    final existing = _sessions[identity];
    if (existing != null) {
      if (!identical(existing.download, download)) {
        throw StateError('Decode identity is bound to another download session');
      }
      return existing;
    }
    final session = WebPDecodeSession(
      identity: identity,
      download: download,
      cursor: cursorFactory(
        download.source,
        identity.targetWidth,
        identity.targetHeight,
      ),
      reconcile: reconcile,
    );
    _sessions[identity] = session;
    return session;
  }

  WebPDecodeSession? find(WebPDecodeIdentity identity) => _sessions[identity];

  void detachScope(String scopeId) {
    for (final session in _sessions.values) {
      session._removeScope(scopeId);
    }
  }

  bool tryEvict(WebPDecodeIdentity identity) {
    final session = _sessions[identity];
    if (session == null || !session.canEvict) return false;
    session.evict();
    _sessions.remove(identity);
    return true;
  }

  /// Removes the active binding without disposing it.
  ///
  /// Source switches may need to create the replacement cursor immediately
  /// while a cancelled upload from the old cursor is still unwinding. The
  /// caller retains the returned session until [WebPDecodeSession.canEvict]
  /// becomes true.
  WebPDecodeSession? retire(WebPDecodeIdentity identity) {
    final session = _sessions[identity];
    if (session == null) return null;
    if (session.demandCount > 0) {
      throw StateError(
        'Cannot retire demanded decode session: ${identity.fullKey}',
      );
    }
    _sessions.remove(identity);
    return session;
  }

  /// Explicit physical eviction. Logical detach must use [detachScope].
  ///
  /// This strict form is retained for coordinator code and unit tests that
  /// expect an invalid active eviction to fail instead of being ignored.
  void evict(WebPDecodeIdentity identity) {
    final session = _sessions[identity];
    if (session == null) return;
    if (!session.canEvict) {
      throw StateError(
        'Cannot evict active decode session: ${identity.fullKey}; '
        'demands=${session.demandCount}, '
        'decodeInFlight=${session.holder.decodeInFlight}, '
        'uploadInFlight=${session.holder.uploadInFlight}',
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
          'Cannot dispose active decode session ${session.identity.fullKey}',
        );
      }
    }
    for (final identity in _sessions.keys.toList()) {
      evict(identity);
    }
  }

  static webp.WebPFrameCursor _createNativeCursor(
    webp.WebPByteSource source,
    int targetWidth,
    int targetHeight,
  ) {
    if (source is! webp.NativeWebPSource) {
      throw StateError('Native decode session requires NativeWebPSource');
    }
    return webp.createNativeWebPPlaybackCursor(
      source,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
  }
}
