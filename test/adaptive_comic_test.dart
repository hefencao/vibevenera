import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/adaptive_comic.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  AdaptiveComicClassifier classifier({
    String title = '',
    List<String> tags = const [],
    String? sourceType,
    String sourceName = '',
  }) =>
      AdaptiveComicClassifier(
        sourceKey: 'test',
        comicId: 'comic',
        title: title,
        author: '',
        tags: tags,
        sourceName: sourceName,
        sourceType: sourceType,
      );

  test('explicit animated tag is recognized before decoding', () {
    final profile = classifier(tags: const ['WebP动图']).classifyMetadata();
    expect(profile?.type, AdaptiveComicType.animated);
    expect(profile?.confidence, greaterThan(0.99));
    expect(profile?.samples, 0);
  });

  test('Korean comic tag overrides segmented page geometry', () {
    final model = classifier(tags: const ['韓漫']);
    final profile = model.classifyMetadata();
    expect(profile?.type, AdaptiveComicType.vertical);
    expect(profile?.confidence, greaterThan(0.95));
  });

  test('comic source can provide a high-confidence layout', () {
    final profile = classifier(
      tags: const ['category:manga'],
      sourceType: 'paged',
    ).classifyMetadata();
    expect(profile?.type, AdaptiveComicType.paged);
    expect(profile?.confidence, greaterThan(0.98));
  });

  test('metadata fingerprint is independent of tag order', () {
    final a = classifier(tags: const ['a:1', 'b:2']);
    final b = classifier(tags: const ['b:2', 'a:1']);
    expect(a.metadataFingerprint, b.metadataFingerprint);
  });

  test('known vertical-only source is recognized', () {
    final profile = classifier(sourceName: 'WEBTOON').classifyMetadata();
    expect(profile?.type, AdaptiveComicType.vertical);
  });

  test('category metadata remains provisional below stop threshold', () {
    final manga = classifier(tags: const ['category:manga']).classifyMetadata();
    final comic = classifier(tags: const ['type:comic']).classifyMetadata();
    final cg = classifier(tags: const ['category:artist cg']).classifyMetadata();
    expect(manga?.type, AdaptiveComicType.vertical);
    expect(comic?.type, AdaptiveComicType.paged);
    expect(cg?.type, AdaptiveComicType.paged);
    expect(manga!.confidence, greaterThanOrEqualTo(0.60));
    expect(manga.confidence, lessThan(0.80));
  });

  test('original work namespace favors paged layout provisionally', () {
    final profile = classifier(tags: const ['原作:作品']).classifyMetadata();
    expect(profile?.type, AdaptiveComicType.paged);
    expect(profile!.isTerminal, isFalse);
  });

  test('ignores cover and recognizes vertical content pages', () {
    final model = classifier();
    expect(model.observe(
      imageKey: 'cover',
      pageIndex: 0,
      totalPages: 8,
      width: 1000,
      height: 4000,
    ), isNull);
    expect(model.observe(
      imageKey: '1',
      pageIndex: 1,
      totalPages: 8,
      width: 800,
      height: 3200,
    ), isNull);
    final profile = model.observe(
      imageKey: '4',
      pageIndex: 4,
      totalPages: 8,
      width: 800,
      height: 2800,
    );
    expect(profile?.type, AdaptiveComicType.vertical);
    expect(profile!.confidence, greaterThan(0.82));
  });

  test('recognizes paged content without relying on title', () {
    final model = classifier(title: 'webtoon styled cover');
    model.observe(
      imageKey: '1',
      pageIndex: 1,
      totalPages: 10,
      width: 1200,
      height: 1700,
    );
    expect(model.observe(
      imageKey: '5',
      pageIndex: 5,
      totalPages: 10,
      width: 1200,
      height: 1700,
    ), isNull);
    final profile = model.observe(
      imageKey: '8',
      pageIndex: 8,
      totalPages: 10,
      width: 1200,
      height: 1700,
    );
    expect(profile?.type, AdaptiveComicType.paged);
  });

  test('manual comic setting overrides adaptive profile', () {
    const id = 'adaptive-test';
    const source = 'test';
    appdata.settings['adaptiveComicType'] = true;
    appdata.settings.setAdaptiveComicProfile(id, source, {
      'type': 'vertical',
      'confidence': 0.95,
      'samples': 2,
      'modelVersion': AdaptiveComicProfile.modelVersion,
    });
    expect(
      appdata.settings.getReaderSetting(id, source, 'readerMode'),
      'continuousTopToBottom',
    );
    appdata.settings.setEnabledComicSpecificSettings(id, source, true);
    appdata.settings.setReaderSetting(
      id,
      source,
      'readerMode',
      'galleryRightToLeft',
    );
    expect(
      appdata.settings.getReaderSetting(id, source, 'readerMode'),
      'galleryRightToLeft',
    );
    appdata.settings.resetComicReaderSettings('$id@$source');
  });

  test('current comic profile prevents repeated classification', () {
    const id = 'adaptive-once-test';
    const source = 'test';
    appdata.settings['adaptiveComicType'] = true;
    expect(
      appdata.settings.needsAdaptiveComicClassification(id, source),
      isTrue,
    );
    appdata.settings.setAdaptiveComicProfile(id, source, {
      'type': 'vertical',
      'confidence': 0.97,
      'modelVersion': AdaptiveComicProfile.modelVersion,
    });
    expect(
      appdata.settings.needsAdaptiveComicClassification(id, source),
      isFalse,
    );
  });

  test('60 percent applies while only 80 percent stops evaluation', () {
    const id = 'adaptive-confidence-test';
    const source = 'test';
    appdata.settings['adaptiveComicType'] = true;
    appdata.settings.setAdaptiveComicProfile(id, source, {
      'type': 'vertical',
      'confidence': 0.60,
      'modelVersion': AdaptiveComicProfile.modelVersion,
    });
    expect(
      appdata.settings.getReaderSetting(id, source, 'readerMode'),
      'continuousTopToBottom',
    );
    expect(
      appdata.settings.needsAdaptiveComicClassification(id, source),
      isTrue,
    );
    appdata.settings.setAdaptiveComicProfile(id, source, {
      'type': 'vertical',
      'confidence': 0.80,
      'modelVersion': AdaptiveComicProfile.modelVersion,
    });
    expect(
      appdata.settings.needsAdaptiveComicClassification(id, source),
      isFalse,
    );
  });

  test('requires two non-cover animations', () {
    final model = classifier();
    expect(model.observeAnimated(
      imageKey: 'cover',
      pageIndex: 0,
      totalPages: 6,
    ), isNull);
    expect(model.observeAnimated(
      imageKey: '1',
      pageIndex: 1,
      totalPages: 6,
    ), isNull);
    final profile = model.observeAnimated(
      imageKey: '3',
      pageIndex: 3,
      totalPages: 6,
    );
    expect(profile?.type, AdaptiveComicType.animated);
  });
}
