import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/pipeline_controller.dart';

ReaderPipelineSession session(List<String> images, String? sourceKey) =>
    ReaderPipelineSession(
      owner: Object(),
      images: images,
      cid: 'comic',
      eid: 'episode',
      sourceKey: sourceKey,
      cache: null,
      targetWidth: 720,
      targetHeight: 1280,
      preloadCount: 4,
    );

void main() {
  test('scheme-less remote page keys keep the streaming pipeline attached', () {
    expect(session(['0', '1'], 'ehentai').isLocalStatic, isFalse);
  });

  test('only local static files bypass the streaming pipeline', () {
    expect(session(['file://comic/0.jpg'], null).isLocalStatic, isTrue);
    expect(session(['file://comic/0.webp'], null).isLocalStatic, isFalse);
  });
}
