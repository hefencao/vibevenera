import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/utils/webp_decoder.dart';

void main() {
  test('detach only removes logical demand', () {
    final source = _FakeSource();
    var reconciles = 0;
    final registry = DownloadSessionRegistry(
      reconcile: (_) => reconciles++,
      sourceFactory: (_, _) => source,
    );
    const identity = DownloadIdentity(
      imageKey: '1.webp',
      sourceKey: 'source',
      cid: 'comic',
      eid: 'episode',
    );
    final session = registry.getOrCreate(identity);
    final display = session.attach(scopeId: 'reader:1', priority: 100);
    final preload = session.attach(scopeId: 'reader:1', priority: 50);

    expect(session.demandCount, 2);
    expect(session.desiredPriority, 100);
    registry.detachScope('reader:1');

    expect(session.demandCount, 0);
    expect(display.attached, isFalse);
    expect(preload.attached, isFalse);
    expect(session.isDisposed, isFalse);
    expect(source.isDisposed, isFalse);
    expect(reconciles, 3);

    registry.evict(identity);
    expect(source.isDisposed, isTrue);
  });

  test('leases aggregate independent priority', () {
    final registry = DownloadSessionRegistry(
      reconcile: (_) {},
      sourceFactory: (_, _) => _FakeSource(),
    );
    const identity = DownloadIdentity(
      imageKey: '2.webp',
      sourceKey: null,
      cid: 'comic',
      eid: 'episode',
    );
    final session = registry.getOrCreate(identity);
    final near = session.attach(scopeId: 'near', priority: 50);
    final current = session.attach(scopeId: 'current', priority: 100);

    expect(session.desiredPriority, 100);
    current.detach();
    expect(session.desiredPriority, 50);
    near.updatePriority(80);
    expect(session.desiredPriority, 80);
  });
}

final class _FakeSource implements WebPByteSource {
  int _epoch = 1;
  int _committed = 0;
  bool _sealed = false;
  bool _disposed = false;

  @override
  int get epoch => _epoch;
  @override
  bool get isDisposed => _disposed;

  @override
  NativeWebPSourceState get state => NativeWebPSourceState(
    epoch: _epoch,
    expectedLength: 0,
    committedLength: _committed,
    declaredLength: 0,
    parsedOffset: 0,
    sealed: _sealed,
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
    if (offset != _committed) throw StateError('offset');
    _committed += bytes.length;
  }

  @override
  void reset({int expectedLength = 0, required int epoch}) {
    _epoch = epoch;
    _committed = 0;
    _sealed = false;
  }

  @override
  void seal() => _sealed = true;

  @override
  NativeWebPFrameDescriptor frameAt(int index) =>
      throw StateError('no frames');

  @override
  void dispose() => _disposed = true;
}
