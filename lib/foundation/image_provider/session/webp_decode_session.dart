import 'dart:async';

import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/foundation/image_provider/renderer/frame_renderer.dart';
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
  }) => _session?._updateDemand(_id, priority, current, decode, upload);

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

final class WebPDecodeSession {
  final WebPDecodeIdentity identity;
  final DownloadSession download;
  final webp.WebPFrameCursor cursor;
  late final WebPFrameHolder holder;
  final void Function(WebPDecodeSession session) _reconcile;
  final Map<int, _WebPDecodeDemand> _demands = {};
  final StreamController<WebPDecodeSessionSnapshot> _states =
      StreamController.broadcast(sync: true);
  late final StreamSubscription<DownloadSessionSnapshot> _downloadSubscription;
  bool _disposed = false;
  int _nextDemandId = 0;
  int _decodeRevision = 1;
  int _uploadRevision = 1;

  WebPDecodeSession({
    required this.identity,
    required this.download,
    required this.cursor,
    required void Function(WebPDecodeSession session) reconcile,
  }) : _reconcile = reconcile {
    holder = WebPFrameHolder(onDemand: () => _reconcile(this));
    _downloadSubscription = download.states.listen((_) {
      _publish();
      _reconcile(this);
    });
  }

  Stream<WebPDecodeSessionSnapshot> get states => _states.stream;
  bool get isDisposed => _disposed;
  int get demandCount => _demands.length;
  int get decodeDemandCount =>
      _demands.values.where((demand) => demand.decode).length;
  int get uploadDemandCount =>
      _demands.values.where((demand) => demand.upload).length;
  bool get shouldDecode => decodeDemandCount > 0;
  bool get shouldUpload => uploadDemandCount > 0;
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
  );

  WebPDecodeDemandLease attach({
    required String scopeId,
    required int priority,
    required bool current,
    required bool decode,
    required bool upload,
  }) {
    _checkActive();
    final beforeDecode = _decodePolicy;
    final beforeUpload = _uploadPolicy;
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

  List<webp.WebPAnimFrameAddress> decodeFrames(int count) {
    _checkActive();
    if (!shouldDecode) throw StateError('Decode session has no decode demand');
    final frames = cursor.decodeFrames(count);
    _acceptFrames(frames);
    _publish();
    return frames;
  }

  void restartCursor() {
    _checkActive();
    cursor.restart();
    holder.clearRawFrames();
    holder.clearRenderedFrames();
    _publish();
    _reconcile(this);
  }

  void evict() {
    if (_disposed) return;
    if (_demands.isNotEmpty) throw StateError('Cannot evict a demanded decode session');
    _disposed = true;
    _downloadSubscription.cancel();
    holder.dispose();
    cursor.dispose();
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
    if (demand.priority == priority && demand.current == current &&
        demand.decode == decode &&
        demand.upload == upload) {
      return;
    }
    final beforeDecode = _decodePolicy;
    final beforeUpload = _uploadPolicy;
    demand.priority = priority;
    demand.current = current;
    demand.decode = decode;
    demand.upload = upload;
    _demandChanged(beforeDecode, beforeUpload);
  }

  bool _hasDemand(int id) => !_disposed && _demands.containsKey(id);

  void _removeDemand(int id) {
    if (_disposed) return;
    final beforeDecode = _decodePolicy;
    final beforeUpload = _uploadPolicy;
    if (_demands.remove(id) != null) _demandChanged(beforeDecode, beforeUpload);
  }

  void _removeScope(String scopeId) {
    if (_disposed) return;
    final beforeDecode = _decodePolicy;
    final beforeUpload = _uploadPolicy;
    final count = _demands.length;
    _demands.removeWhere((_, demand) => demand.scopeId == scopeId);
    if (_demands.length != count) _demandChanged(beforeDecode, beforeUpload);
  }

  ({bool enabled, int priority}) get _decodePolicy =>
      (enabled: shouldDecode, priority: decodePriority);
  ({bool enabled, int priority}) get _uploadPolicy =>
      (enabled: shouldUpload, priority: uploadPriority);

  void _demandChanged(
    ({bool enabled, int priority}) beforeDecode,
    ({bool enabled, int priority}) beforeUpload,
  ) {
    if (beforeDecode != _decodePolicy) _decodeRevision++;
    if (beforeUpload != _uploadPolicy) _uploadRevision++;
    holder.updateDemand(WebPFrameDemand(
      current: isCurrent,
      decode: shouldDecode,
      upload: shouldUpload,
    ));
    _publish();
    _reconcile(this);
  }

  void _publish() {
    if (!_states.isClosed) _states.add(snapshot);
  }

  void _checkActive() {
    if (_disposed) throw StateError('Decode session is evicted');
  }

  void _acceptFrames(List<webp.WebPAnimFrameAddress> frames) {
    if (frames.isEmpty) return;
    final state = cursor.state;
    if (!state.ready || state.targetWidth <= 0 || state.targetHeight <= 0) {
      for (final frame in frames) {
        webp.nativePoolRelease(frame.address);
      }
      throw StateError('Playback cursor produced frames before target size');
    }
    holder.addRawFrames(frames.map((frame) => NativeFrameHandle(
      address: frame.address,
      width: state.targetWidth,
      height: state.targetHeight,
      durationMs: frame.durationMs,
    )));
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

  void evict(WebPDecodeIdentity identity) {
    final session = _sessions[identity];
    if (session == null) return;
    session.evict();
    _sessions.remove(identity);
  }

  void dispose() {
    for (final session in _sessions.values) {
      if (session.demandCount > 0) {
        throw StateError('Cannot dispose demanded decode sessions');
      }
    }
    for (final session in _sessions.values) {
      session.evict();
    }
    _sessions.clear();
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
