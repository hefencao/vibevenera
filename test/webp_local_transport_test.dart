import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/network/webp_download_artifact.dart';
import 'package:venera/network/webp_download_transport.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

void main() {
  test('stream completion seals without a final Uint8List', () async {
    final directory = await Directory.systemTemp.createTemp('webp-stream-');
    addTearDown(() => directory.delete(recursive: true));
    final partial = File('${directory.path}/partial');
    final cached = File('${directory.path}/cached');
    final bytes = Uint8List.fromList([
      0x52, 0x49, 0x46, 0x46,
      0x04, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
    ]);
    final source = _FakeSource();
    const identity = DownloadIdentity(
      imageKey: 'https://example.invalid/image.webp',
      sourceKey: null,
      cid: 'cid',
      eid: 'eid',
    );
    final session = DownloadSession(
      identity: identity,
      source: source,
      reconcile: (_) {},
    );
    session.beginTransport();
    final transport = ImageDownloaderWebPTransport(
      identity,
      artifactFactory: (_) => WebPDownloadArtifact(
        partial,
        promote: (source) => source.rename(cached.path),
      ),
      eventSource: ({
        required int resumeOffset,
        required int? expectedLength,
        cancelToken,
      }) async* {
        expect(resumeOffset, 0);
        yield ImageDownloadProgress(
          currentBytes: 8,
          totalBytes: bytes.length,
          chunkBytes: Uint8List.sublistView(bytes, 0, 8),
        );
        yield ImageDownloadProgress(
          currentBytes: bytes.length,
          totalBytes: bytes.length,
          chunkBytes: Uint8List.sublistView(bytes, 8),
        );
        yield ImageDownloadProgress(
          currentBytes: bytes.length,
          totalBytes: bytes.length,
          done: true,
        );
      },
    );

    final result = await transport.execute(session);

    expect(await result.readAsBytes(), bytes);
    expect(source.bytes, bytes);
    expect(session.transport, DownloadTransportState.sealed);
  });

  test('file URI is resolved through IOOverrides and streamed once', () async {
    final directory = await Directory.systemTemp.createTemp('webp-local-');
    addTearDown(() => directory.delete(recursive: true));
    final input = File('${directory.path}/input.webp');
    final partial = File('${directory.path}/partial');
    final cached = File('${directory.path}/cached');
    final bytes = Uint8List.fromList([
      0x52, 0x49, 0x46, 0x46,
      0x04, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
    ]);
    await input.writeAsBytes(bytes);
    final source = _FakeSource();
    final identity = DownloadIdentity(
      imageKey: 'file://${input.path}',
      sourceKey: null,
      cid: 'cid',
      eid: 'eid',
    );
    final session = DownloadSession(
      identity: identity,
      source: source,
      reconcile: (_) {},
    );
    session.beginTransport();
    final transport = ImageDownloaderWebPTransport(
      identity,
      artifactFactory: (_) => WebPDownloadArtifact(
        partial,
        promote: (source) => source.rename(cached.path),
      ),
    );

    final result = await IOOverrides.runWithIOOverrides(
      () => transport.execute(session),
      _FileUriOverrides(),
    );

    expect(await result.readAsBytes(), bytes);
    expect(source.bytes, bytes);
    expect(session.transport, DownloadTransportState.sealed);
  });
}

final class _FileUriOverrides extends IOOverrides {
  @override
  File createFile(String path) {
    if (!path.startsWith('file://')) return super.createFile(path);
    return _NoOpenReadFile(super.createFile(path.substring(7)));
  }
}

final class _NoOpenReadFile implements File {
  final File delegate;

  _NoOpenReadFile(this.delegate);

  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<int> length() => delegate.length();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      delegate.open(mode: mode);
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      throw UnimplementedError('SAF AndroidFile.openRead');
  @override
  String get path => delegate.path;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Function.apply(delegate.noSuchMethod, [invocation]);
}

final class _FakeSource implements webp.WebPByteSource {
  final List<int> bytes = [];
  int currentEpoch = 1;
  bool disposed = false;
  bool sealed = false;

  @override
  int get epoch => currentEpoch;
  @override
  bool get isDisposed => disposed;
  @override
  webp.NativeWebPSourceState get state => webp.NativeWebPSourceState(
    epoch: currentEpoch,
    expectedLength: bytes.length,
    committedLength: bytes.length,
    declaredLength: bytes.length >= 12 ? bytes.length : 0,
    parsedOffset: bytes.length,
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
  void append(Uint8List bytes, {required int offset}) {
    if (offset != this.bytes.length) throw StateError('offset');
    this.bytes.addAll(bytes);
  }

  @override
  void dispose() => disposed = true;
  @override
  webp.NativeWebPFrameDescriptor frameAt(int index) =>
      throw UnimplementedError();
  @override
  void reset({int expectedLength = 0, required int epoch}) {
    currentEpoch = epoch;
    bytes.clear();
    sealed = false;
  }

  @override
  void seal() => sealed = true;
}
