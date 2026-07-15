import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/streaming_image.dart';

void main() {
  test('GIF URLs use the streaming animation provider', () {
    expect(
      StreamingImageProvider.isLikelyStreamingAnimation('https://a/1.GIF?x=1'),
      isTrue,
    );
    expect(
      StreamingImageProvider.isLikelyStreamingAnimation('https://a/1.jpg'),
      isFalse,
    );
  });

  test('texture identity includes comic and episode', () {
    final first = StreamingImageProvider(
      imageKey: '0',
      sourceKey: 'ehentai',
      cid: 'old',
      eid: '0',
      targetWidth: 720,
      targetHeight: 1280,
    );
    final second = StreamingImageProvider(
      imageKey: '0',
      sourceKey: 'ehentai',
      cid: 'new',
      eid: '0',
      targetWidth: 720,
      targetHeight: 1280,
    );

    expect(first.textureFullKey, isNot(second.textureFullKey));
  });

  test('logical version pages keep independent playback identity', () {
    final oldPage = StreamingImageProvider(
      imageKey: 'old-index',
      sourceKey: 'ehentai',
      cid: 'old-version',
      eid: '0',
      targetWidth: 720,
      targetHeight: 1280,
    );
    final newPage = StreamingImageProvider(
      imageKey: 'new-index',
      sourceKey: 'ehentai',
      cid: 'new-version',
      eid: '0',
      targetWidth: 720,
      targetHeight: 1280,
    );

    expect(newPage.textureFullKey, isNot(oldPage.textureFullKey));
  });
}
