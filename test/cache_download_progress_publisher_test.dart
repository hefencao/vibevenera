import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/cache_download_progress_publisher.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

void main() {
  test('rank changes reorder cache downloads immediately', () async {
    final publisher = CacheDownloadProgressPublisher();
    final first = _session('first');
    final second = _session('second');
    final firstDemand = first.attach(scopeId: 'reader', priority: 100);
    final secondDemand = second.attach(scopeId: 'reader', priority: 50);
    first.markReceiving();
    second.markReceiving();
    publisher.observe(first);
    publisher.observe(second);
    await _flush();

    expect(publisher.notifier.value.map((item) => item.rank), [100, 50]);

    secondDemand.updatePriority(200);
    await _flush();

    expect(publisher.notifier.value.map((item) => item.rank), [200, 100]);
    firstDemand.detach();
    secondDemand.detach();
    publisher.dispose();
  });

  test('failed download disappears after its demand is abandoned', () async {
    final publisher = CacheDownloadProgressPublisher();
    final session = _session('failed');
    final demand = session.attach(scopeId: 'reader', priority: 100);
    final writer = session.markReceiving();
    publisher.observe(session);
    session.fail(writer, StateError('failed'), retryable: false);
    await _flush();

    expect(publisher.notifier.value.single.transport,
        DownloadTransportState.failed);

    demand.detach();
    await _flush();

    expect(publisher.notifier.value, isEmpty);
    publisher.dispose();
    session.evict();
  });
}

DownloadSession _session(String key) => DownloadSession(
  identity: DownloadIdentity(
    imageKey: key,
    sourceKey: 'source',
    cid: 'comic',
    eid: 'episode',
  ),
  source: _FakeSource(),
  reconcile: (_) {},
);

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _FakeSource implements webp.WebPByteSource {
  bool disposed = false;

  @override
  int get epoch => 1;
  @override
  bool get isDisposed => disposed;
  @override
  webp.NativeWebPSourceState get state => const webp.NativeWebPSourceState(
    epoch: 1,
    expectedLength: 0,
    committedLength: 0,
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
  void append(Uint8List bytes, {required int offset}) {}
  @override
  void dispose() => disposed = true;
  @override
  webp.NativeWebPFrameDescriptor frameAt(int index) =>
      throw UnimplementedError();
  @override
  void reset({int expectedLength = 0, required int epoch}) {}
  @override
  void seal() {}
}
