import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/webp_image.dart';

void main() {
  test('GIF URLs use the streaming animation provider', () {
    expect(
      WebPImageProvider.isLikelyStreamingAnimation('https://a/1.GIF?x=1'),
      isTrue,
    );
    expect(
      WebPImageProvider.isLikelyStreamingAnimation('https://a/1.jpg'),
      isFalse,
    );
  });

  test('texture identity includes comic and episode', () {
    final first = WebPImageProvider(
      imageKey: '0',
      sourceKey: 'ehentai',
      cid: 'old',
      eid: '0',
      targetWidth: 720,
      targetHeight: 1280,
    );
    final second = WebPImageProvider(
      imageKey: '0',
      sourceKey: 'ehentai',
      cid: 'new',
      eid: '0',
      targetWidth: 720,
      targetHeight: 1280,
    );

    expect(first.textureFullKey, isNot(second.textureFullKey));
  });

  test('cache alias keeps an independent playback identity', () {
    CacheManager().aliasImage(
      imageKey: 'new-index',
      sourceKey: 'ehentai',
      cid: 'new-version',
      eid: '0',
      target: const CacheAliasTarget(
        'old-index',
        'ehentai',
        'old-version',
        '0',
      ),
    );
    final oldPage = WebPImageProvider(
      imageKey: 'old-index',
      sourceKey: 'ehentai',
      cid: 'old-version',
      eid: '0',
      targetWidth: 720,
      targetHeight: 1280,
    );
    final newPage = WebPImageProvider(
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
