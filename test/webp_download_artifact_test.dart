import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/io/webp_download_artifact.dart';
import 'package:venera/foundation/image_provider/session/download_session.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

void main() {
  test('artifact restores source and promotes the same file', () async {
    final directory = await Directory.systemTemp.createTemp('webp-artifact-');
    addTearDown(() => directory.delete(recursive: true));
    final partial = File('${directory.path}/partial');
    final finalFile = File('${directory.path}/final');
    WebPDownloadArtifact createArtifact() => WebPDownloadArtifact(
      partial,
      promote: (source) => source.rename(finalFile.path),
    );
    final firstSource = _FakeSource();
    final firstSession = _session(firstSource);
    final first = createArtifact();
    await first.restore(firstSession);
    final a = Uint8List.fromList([1, 2, 3]);
    firstSession.append(a, offset: 0);
    await first.append(a, offset: 0);
    await first.close();

    final restoredSource = _FakeSource();
    final restoredSession = _session(restoredSource);
    final restored = createArtifact();
    await restored.restore(restoredSession);
    expect(restoredSource.bytes, [1, 2, 3]);

    final b = Uint8List.fromList([4, 5]);
    restoredSession.append(b, offset: 3);
    await restored.append(b, offset: 3);
    final promoted = await restored.promote(sealedLength: 5);

    expect(promoted.path, finalFile.path);
    expect(await promoted.readAsBytes(), [1, 2, 3, 4, 5]);
    expect(restored.isPromoted, isTrue);
  });
}

DownloadSession _session(_FakeSource source) => DownloadSession(
  identity: const DownloadIdentity(
    imageKey: 'image',
    sourceKey: 'source',
    cid: 'cid',
    eid: 'eid',
  ),
  source: source,
  reconcile: (_) {},
);

final class _FakeSource implements webp.WebPByteSource {
  final List<int> bytes = [];
  bool disposed = false;

  @override
  int get epoch => 1;
  @override
  bool get isDisposed => disposed;
  @override
  webp.NativeWebPSourceState get state => webp.NativeWebPSourceState(
    epoch: epoch,
    expectedLength: 0,
    committedLength: bytes.length,
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
    if (offset != this.bytes.length) throw StateError('offset');
    this.bytes.addAll(bytes);
  }

  @override
  void dispose() => disposed = true;
  @override
  webp.NativeWebPFrameDescriptor frameAt(int index) =>
      throw UnimplementedError();
  @override
  void reset({int expectedLength = 0, required int epoch}) => bytes.clear();
  @override
  void seal() {}
}
