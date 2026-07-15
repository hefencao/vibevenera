import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/task_scheduler.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/foundation/image_provider/session/webp_decode_session.dart';
import 'package:venera/foundation/image_provider/session/streaming_session_coordinator.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/streaming_image_transport.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

void main() {
  test('display-only demand does not start a transport', () async {
    final scheduler = TaskScheduler.instance;
    scheduler.clear();
    addTearDown(scheduler.clear);
    var transportStarted = false;
    final coordinator = StreamingSessionCoordinator(
      scheduler: scheduler,
      transportFactory: (_) => _NeverStartedTransport(
        onExecute: () => transportStarted = true,
      ),
      sourceFactory: (_, _) => _FakeSource(),
      cursorFactory: (source, _, _) => _FakeCursor(source),
    );
    final lease = coordinator.acquire(
      downloadIdentity: const DownloadIdentity(
        imageKey: 'image',
        sourceKey: 'source',
        cid: 'cid',
        eid: 'eid',
      ),
      decodeIdentity: const WebPDecodeIdentity(
        fullKey: 'image@100x100',
        targetWidth: 100,
        targetHeight: 100,
      ),
      scopeId: 'display',
      demand: const StreamingResourceDemand(
        downloadPriority: 0,
        decodePriority: 60,
        allowDownload: false,
        allowDecode: true,
        allowUpload: true,
        current: false,
      ),
    );

    await Future<void>.delayed(Duration.zero);

    expect(transportStarted, isFalse);
    expect(lease.download.transport, DownloadTransportState.idle);
    lease.detach();
    coordinator.dispose();
  });

  test('logical detach does not cancel a receiving transport', () async {
    final scheduler = TaskScheduler.instance;
    scheduler.clear();
    final file = File('${Directory.systemTemp.path}/streaming-session-test');
    await file.writeAsBytes(const [1]);
    addTearDown(() async {
      scheduler.clear();
      if (await file.exists()) await file.delete();
    });
    final transport = _BlockingTransport(file);
    final coordinator = StreamingSessionCoordinator(
      scheduler: scheduler,
      transportFactory: (_) => transport,
      sourceFactory: (_, _) => _FakeSource(),
      cursorFactory: (source, _, _) => _FakeCursor(source),
    );
    const downloadIdentity = DownloadIdentity(
      imageKey: 'image',
      sourceKey: 'source',
      cid: 'cid',
      eid: 'eid',
    );
    const decodeIdentity = WebPDecodeIdentity(
      fullKey: 'image@100x100',
      targetWidth: 100,
      targetHeight: 100,
    );
    final lease = coordinator.acquire(
      downloadIdentity: downloadIdentity,
      decodeIdentity: decodeIdentity,
      scopeId: 'reader',
      demand: const StreamingResourceDemand(
        downloadPriority: 100,
        decodePriority: 0,
        allowDownload: true,
        allowDecode: false,
        allowUpload: false,
        current: true,
      ),
    );
    await transport.started.future;

    lease.detach();

    expect(transport.cancelToken!.isCancelled, isFalse);
    expect(lease.download.transport, DownloadTransportState.receiving);
    transport.release.complete();
    await transport.completed.future;
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.downloads.find(downloadIdentity), isNull);
    expect(lease.download.isDisposed, isTrue);
    coordinator.dispose();
  });

  test('failed transport is evicted after demand is abandoned', () async {
    final scheduler = TaskScheduler.instance;
    scheduler.clear();
    addTearDown(scheduler.clear);
    final transport = _FailingTransport();
    final coordinator = StreamingSessionCoordinator(
      scheduler: scheduler,
      transportFactory: (_) => transport,
      sourceFactory: (_, _) => _FakeSource(),
      cursorFactory: (source, _, _) => _FakeCursor(source),
    );
    const downloadIdentity = DownloadIdentity(
      imageKey: 'failed',
      sourceKey: 'source',
      cid: 'cid',
      eid: 'eid',
    );
    final lease = coordinator.acquire(
      downloadIdentity: downloadIdentity,
      decodeIdentity: const WebPDecodeIdentity(
        fullKey: 'failed@100x100',
        targetWidth: 100,
        targetHeight: 100,
      ),
      scopeId: 'reader',
      demand: const StreamingResourceDemand(
        downloadPriority: 100,
        decodePriority: 0,
        allowDownload: true,
        allowDecode: false,
        allowUpload: false,
        current: true,
      ),
    );
    await transport.failed.future;
    await Future<void>.delayed(Duration.zero);
    expect(lease.download.transport, DownloadTransportState.failed);

    lease.detach();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(coordinator.downloads.find(downloadIdentity), isNull);
    expect(lease.download.isDisposed, isTrue);
    coordinator.dispose();
  });
}

final class _NeverStartedTransport implements StreamingImageTransport {
  final void Function() onExecute;

  _NeverStartedTransport({required this.onExecute});

  @override
  Future<File> execute(
    DownloadSession session, {
    CancelToken? cancelToken,
    void Function(StreamingTransportProgress progress)? onProgress,
  }) {
    onExecute();
    throw StateError('Display demand must not execute transport');
  }
}

final class _BlockingTransport implements StreamingImageTransport {
  final File file;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  final Completer<void> completed = Completer<void>();
  CancelToken? cancelToken;

  _BlockingTransport(this.file);

  @override
  Future<File> execute(
    DownloadSession session, {
    CancelToken? cancelToken,
    void Function(StreamingTransportProgress progress)? onProgress,
  }) async {
    this.cancelToken = cancelToken;
    session.markReceiving();
    started.complete();
    await release.future;
    session.seal();
    completed.complete();
    return file;
  }
}

final class _FailingTransport implements StreamingImageTransport {
  final failed = Completer<void>();

  @override
  Future<File> execute(
    DownloadSession session, {
    CancelToken? cancelToken,
    void Function(StreamingTransportProgress progress)? onProgress,
  }) async {
    session.markReceiving();
    failed.complete();
    throw StateError('failed');
  }
}

final class _FakeSource implements webp.WebPByteSource {
  bool disposed = false;
  bool sealed = false;

  @override
  int get epoch => 1;
  @override
  bool get isDisposed => disposed;
  @override
  webp.NativeWebPSourceState get state => webp.NativeWebPSourceState(
    epoch: epoch,
    expectedLength: 0,
    committedLength: 0,
    declaredLength: 0,
    parsedOffset: 0,
    sealed: sealed,
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
  void reset({int expectedLength = 0, required int epoch}) => sealed = false;
  @override
  void seal() => sealed = true;
}

final class _FakeCursor implements webp.WebPFrameCursor {
  final webp.WebPByteSource source;
  bool disposed = false;

  _FakeCursor(this.source);

  @override
  int get address => 1;
  @override
  bool get isDisposed => disposed;
  @override
  webp.NativeWebPPlaybackCursorState get state =>
      webp.NativeWebPPlaybackCursorState(
        sourceEpoch: source.epoch,
        committedLength: source.state.committedLength,
        canvasWidth: 0,
        canvasHeight: 0,
        targetWidth: 0,
        targetHeight: 0,
        availableFrames: 0,
        nextFrame: 0,
        loopCount: 0,
        ready: false,
        sourceSealed: source.state.sealed,
        atAvailableEnd: true,
        complete: source.state.sealed,
        failed: false,
        lastError: 0,
      );

  @override
  List<webp.WebPAnimFrameAddress> decodeFrames(int count) => const [];
  @override
  void rebindSource() {}
  @override
  void dispose() => disposed = true;
  @override
  void restart() {}
  @override
  void setThreadLimit(int useThreads) {}
}
