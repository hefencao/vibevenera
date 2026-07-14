import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/foundation/image_provider/session/webp_decode_session.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

void main() {
  DownloadSession createDownload(_FakeSource source) => DownloadSession(
    identity: const DownloadIdentity(
      imageKey: 'image',
      sourceKey: 'source',
      cid: 'cid',
      eid: 'eid',
    ),
    source: source,
    reconcile: (_) {},
  );

  test('decode detach removes demand without disposing cursor', () {
    final source = _FakeSource();
    final cursor = _FakeCursor(source);
    final registry = WebPDecodeSessionRegistry(
      reconcile: (_) {},
      cursorFactory: (_, _, _) => cursor,
    );
    const identity = WebPDecodeIdentity(
      fullKey: 'image@100x100',
      targetWidth: 100,
      targetHeight: 100,
    );
    final session = registry.getOrCreate(identity, createDownload(source));
    session.attach(
      scopeId: 'reader',
      priority: 10,
      current: true,
      decode: true,
      upload: true,
    );

    registry.detachScope('reader');

    expect(session.demandCount, 0);
    expect(cursor.disposed, isFalse);
    registry.evict(identity);
    expect(cursor.disposed, isTrue);
  });

  test('decode and upload revisions change independently', () {
    final source = _FakeSource();
    final registry = WebPDecodeSessionRegistry(
      reconcile: (_) {},
      cursorFactory: (_, _, _) => _FakeCursor(source),
    );
    const identity = WebPDecodeIdentity(
      fullKey: 'image@100x100',
      targetWidth: 100,
      targetHeight: 100,
    );
    final session = registry.getOrCreate(identity, createDownload(source));
    final decode = session.attach(
      scopeId: 'decode',
      priority: 5,
      current: false,
      decode: true,
      upload: false,
    );
    expect((session.decodeRevision, session.uploadRevision), (2, 1));

    final upload = session.attach(
      scopeId: 'upload',
      priority: 4,
      current: false,
      decode: false,
      upload: true,
    );
    expect((session.decodeRevision, session.uploadRevision), (2, 2));

    upload.update(priority: 7, current: false, decode: false, upload: true);
    expect((session.decodeRevision, session.uploadRevision), (2, 2));
    upload.update(priority: 7, current: false, decode: true, upload: true);
    expect((session.decodeRevision, session.uploadRevision), (2, 2));

    decode.detach();
    expect((session.decodeRevision, session.uploadRevision), (2, 2));
    upload.detach();
    expect((session.decodeRevision, session.uploadRevision), (3, 3));
    registry.evict(identity);
  });

  test('source commits notify the stable decode session', () async {
    final source = _FakeSource();
    var reconciles = 0;
    final registry = WebPDecodeSessionRegistry(
      reconcile: (_) => reconciles++,
      cursorFactory: (_, _, _) => _FakeCursor(source),
    );
    const identity = WebPDecodeIdentity(
      fullKey: 'image@100x100',
      targetWidth: 100,
      targetHeight: 100,
    );
    final download = createDownload(source);
    final session = registry.getOrCreate(identity, download);
    final demand = session.attach(
      scopeId: 'reader',
      priority: 10,
      current: true,
      decode: true,
      upload: true,
    );
    var states = 0;
    final subscription = session.states.listen((_) => states++);

    download.append(Uint8List(16), offset: 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await Future<void>.delayed(Duration.zero);

    expect(session.snapshot.cursor.committedLength, 16);
    expect(states, greaterThanOrEqualTo(1));
    expect(reconciles, greaterThanOrEqualTo(1));
    subscription.cancel();
    demand.detach();
    registry.evict(identity);
  });

  test('download-only commits do not reconcile decode work', () async {
    final source = _FakeSource();
    var reconciles = 0;
    final registry = WebPDecodeSessionRegistry(
      reconcile: (_) => reconciles++,
      cursorFactory: (_, _, _) => _FakeCursor(source),
    );
    const identity = WebPDecodeIdentity(
      fullKey: 'download-only@100x100',
      targetWidth: 100,
      targetHeight: 100,
    );
    final download = createDownload(source);
    final session = registry.getOrCreate(identity, download);
    var states = 0;
    final subscription = session.states.listen((_) => states++);

    download.append(Uint8List(16), offset: 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await Future<void>.delayed(Duration.zero);

    expect(states, 0);
    expect(reconciles, 0);
    subscription.cancel();
    registry.evict(identity);
  });

  test('source epoch change rebinds the existing playback cursor', () async {
    final source = _FakeSource();
    final cursor = _FakeCursor(source);
    final registry = WebPDecodeSessionRegistry(
      reconcile: (_) {},
      cursorFactory: (_, _, _) => cursor,
    );
    const identity = WebPDecodeIdentity(
      fullKey: 'image@100x100',
      targetWidth: 100,
      targetHeight: 100,
    );
    final download = createDownload(source);
    final session = registry.getOrCreate(identity, download);
    final demand = session.attach(
      scopeId: 'reader',
      priority: 10,
      current: true,
      decode: true,
      upload: true,
    );
    final writer = download.beginTransport();

    download.resetSource(writer: writer, epoch: 2);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(cursor.rebindCount, 1);
    expect(session.snapshot.cursor.sourceEpoch, 2);
    demand.detach();
    registry.evict(identity);
  });
}

final class _FakeSource implements webp.WebPByteSource {
  int committed = 0;
  int _epoch = 1;
  bool disposed = false;

  @override
  int get epoch => _epoch;
  @override
  bool get isDisposed => disposed;
  @override
  webp.NativeWebPSourceState get state => webp.NativeWebPSourceState(
    epoch: _epoch,
    expectedLength: 0,
    committedLength: committed,
    declaredLength: 0,
    parsedOffset: 0,
    sealed: false,
    failed: false,
    lastError: 0,
    canvasWidth: 0,
    canvasHeight: 0,
    loopCount: 0,
    frameCount: 0,
    animated: false,
  );

  @override
  void append(Uint8List bytes, {required int offset}) {
    expect(offset, committed);
    committed += bytes.length;
  }

  @override
  void dispose() => disposed = true;

  @override
  webp.NativeWebPFrameDescriptor frameAt(int index) =>
      throw UnimplementedError();

  @override
  void reset({int expectedLength = 0, required int epoch}) {
    _epoch = epoch;
    committed = 0;
  }

  @override
  void seal() {}
}

final class _FakeCursor implements webp.WebPFrameCursor {
  final _FakeSource source;
  bool disposed = false;
  int rebindCount = 0;

  _FakeCursor(this.source);

  @override
  int get address => 1;
  @override
  bool get isDisposed => disposed;
  @override
  webp.NativeWebPPlaybackCursorState get state =>
      webp.NativeWebPPlaybackCursorState(
        sourceEpoch: source.epoch,
        committedLength: source.committed,
        canvasWidth: 0,
        canvasHeight: 0,
        targetWidth: 0,
        targetHeight: 0,
        availableFrames: 0,
        nextFrame: 0,
        loopCount: 0,
        ready: false,
        sourceSealed: false,
        atAvailableEnd: true,
        complete: false,
        failed: false,
        lastError: 0,
      );

  @override
  List<webp.WebPAnimFrameAddress> decodeFrames(int count) => const [];
  @override
  void rebindSource() => rebindCount++;
  @override
  void dispose() => disposed = true;
  @override
  void restart() {}
  @override
  void setThreadLimit(int useThreads) {}
}
