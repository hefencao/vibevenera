import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/runtime/gif_stream_index.dart';

void main() {
  final single = base64Decode(
    'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==',
  );

  test('indexes a complete GIF one byte at a time', () {
    final index = GifStreamIndexer();
    for (final byte in single) {
      index.add(Uint8List.fromList([byte]));
    }
    final result = index.snapshot;
    expect(result.width, 1);
    expect(result.height, 1);
    expect(result.frameCount, 1);
    expect(result.completeOffset, single.length);
    expect(result.trailerSeen, isTrue);
  });

  test('publishes only complete image blocks', () {
    final animated = _twoFrameGif(single);
    final secondEnd = animated.length - 2;
    final index = GifStreamIndexer();
    index.add(Uint8List.sublistView(animated, 0, secondEnd));
    expect(index.snapshot.frameCount, 1);
    expect(index.snapshot.trailerSeen, isFalse);
    index.add(Uint8List.sublistView(animated, secondEnd));
    expect(index.snapshot.frameCount, 2);
    expect(index.snapshot.trailerSeen, isTrue);
    expect(index.snapshot.completeOffset, animated.length);
  });

  test('rejects a non-GIF stream', () {
    final index = GifStreamIndexer();
    expect(
      () => index.add(Uint8List.fromList('NOTGIF'.codeUnits)),
      throwsFormatException,
    );
  });

  testWidgets('Flutter codec accepts a synthesized partial trailer', (_) async {
    final animated = _twoFrameGif(single);
    final partial = Uint8List.fromList([
      ...animated.sublist(0, animated.length - 1),
      0x3b,
    ]);
    final codec = await ui.instantiateImageCodec(partial);
    addTearDown(codec.dispose);
    expect(codec.frameCount, 2);
    final first = await codec.getNextFrame();
    final second = await codec.getNextFrame();
    first.image.dispose();
    second.image.dispose();
  });
}

Uint8List _twoFrameGif(Uint8List single) {
  final separator = single.indexOf(0x2c);
  final image = single.sublist(separator, single.length - 1);
  const gce = <int>[0x21, 0xf9, 0x04, 0, 1, 0, 0, 0];
  return Uint8List.fromList([
    ...single.sublist(0, single.length - 1),
    ...gce,
    ...image,
    0x3b,
  ]);
}
