import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_translation/benchmark.dart';
import 'package:venera/foundation/comic_translation/engine.dart';
import 'package:venera/foundation/comic_translation/grouping.dart';
import 'package:venera/foundation/comic_translation/models.dart';
import 'package:venera/foundation/comic_translation/policy.dart';
import 'package:venera/foundation/comic_translation/remote_translation.dart';
import 'package:venera/foundation/comic_translation/session.dart';
import 'package:venera/foundation/comic_translation/store.dart';

void main() {
  late Directory temp;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('venera-translation-test');
    await ComicTranslationStore.instance.init(temp.path);
  });

  tearDownAll(() async {
    await ComicTranslationStore.instance.close();
    await temp.delete(recursive: true);
  });

  test('static page is recognized, translated and reused by content digest', () async {
    final image = File('${temp.path}/page.bin');
    await image.writeAsBytes(List<int>.generate(256, (i) => i));
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(),
      sourceKey: 'local',
      comicId: 'comic',
      chapterId: 'chapter',
      pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final first = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    first.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    final firstState = await _waitFor(first, identity);
    expect(firstState.artifact!.regions.single.translatedText, '你好');
    expect(firstState.artifact!.regions.single.backgroundArgb, 0xFFFFFFFF);
    expect(firstState.artifact!.regions.single.foregroundArgb, 0xFF202020);
    expect(firstState.artifact!.regions.single.bubbleGroupId, 3);
    expect(firstState.artifact!.regions.single.translationUnitId, isNotNull);
    expect(firstState.artifact!.regions.single.translationUnitOrder, 0);
    expect(firstState.artifact!.regions.single.translationBandIndex, 0);
    expect(firstState.artifact!.regions.single.translationOrientation, isNotNull);
    expect(firstState.cleanOverlayPng, [1, 2, 3]);
    expect(firstState.artifact!.regions.single.bubblePolygon, isNotEmpty);
    expect(firstState.artifact!.regions.single.sourceMaskPolygons.single, hasLength(4));
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    first.setEnabled(false);
    first.setEnabled(true);
    first.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(first, identity);
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    first.dispose();

    final second = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    second.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    final secondState = await _waitFor(second, identity);
    expect(
      secondState.artifact!.regions.single.sourceMaskPolygons.single.first.x,
      0.12,
    );
    expect(secondState.artifact!.regions.single.foregroundArgb, 0xFF202020);
    expect(secondState.artifact!.regions.single.bubbleGroupId, 3);
    expect(secondState.artifact!.regions.single.translationUnitId,
        firstState.artifact!.regions.single.translationUnitId);
    expect(secondState.artifact!.regions.single.translationBandIndex, 0);
    expect(secondState.cleanOverlayPng, [1, 2, 3]);
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    second.dispose();

    final fallback = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
      policy: const ComicTranslationPolicy(useCleanOverlay: false),
    );
    fallback.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    final fallbackState = await _waitFor(fallback, identity);
    expect(fallbackState.cleanOverlayPng, isNull);
    expect(fallbackState.artifact, isNotNull);
    fallback.dispose();
  });

  test('engine leases keep shared models loaded until the final user leaves', () async {
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final first = await registry.acquire();
    final second = await registry.acquire();
    await registry.loadOcr(first, 'ja');
    await registry.loadTranslator(second);
    expect(ocr.loads, 1);
    expect(translator.loads, 1);
    await registry.release(first);
    expect(ocr.unloads, 0);
    expect(translator.unloads, 0);
    await registry.release(second);
    expect(ocr.unloads, 1);
    expect(translator.unloads, 1);
  });

  test('translation survives a new session with different live context', () async {
    final firstImage = File('${temp.path}/context-page-0.bin');
    final secondImage = File('${temp.path}/context-page-1.bin');
    await firstImage.writeAsBytes(List<int>.filled(257, 1));
    await secondImage.writeAsBytes(List<int>.filled(259, 2));
    ComicTranslationPageIdentity identity(File file, int page) =>
        ComicTranslationPageIdentity(
          imageKey: file.uri.toString(),
          sourceKey: 'context-local',
          comicId: 'context-comic',
          chapterId: 'context-chapter',
          pageIndex: page,
          mediaKind: ComicTranslationMediaKind.staticImage,
        );
    final firstPage = identity(firstImage, 0);
    final secondPage = identity(secondImage, 1);
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final first = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    first.reportPages(
      current: [firstPage],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(first, firstPage);
    first.reportPages(
      current: [secondPage],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(first, secondPage);
    expect(translator.calls, 2);
    first.dispose();

    final reopened = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    reopened.reportPages(
      current: [secondPage],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(reopened, secondPage);
    expect(translator.calls, 2);
    reopened.dispose();
  });

  test('additional remote prompt participates in translation cache identity', () {
    OpenAiCompatibleComicTranslationEngine engine(String prompt) =>
        OpenAiCompatibleComicTranslationEngine(
          endpoint: 'https://example.com/v1/chat/completions',
          model: 'test',
          apiKey: '',
          additionalPrompt: prompt,
        );
    expect(engine(' names ').modelVersion, engine('names').modelVersion);
    expect(engine('formal').modelVersion, isNot(engine('casual').modelVersion));
  });

  test('remote translation JSON tolerates wrapper text and braces in strings', () {
    final value = decodeComicTranslationJson(
      'result follows:\n```json\n'
      '{"translations":{"bubble:1":["保留 {括号}"]}}\n```\ndone',
    );
    expect(value['translations'], {'bubble:1': ['保留 {括号}']});
  });

  test('open Japanese OCR regions cluster and sort by positional columns', () {
    final artifact = _ocrArtifact([
      _positionedRegion('left', '左', 0.42, 0.12, 0.08, 0.42, 0),
      _positionedRegion('right-bottom', '下', 0.55, 0.34, 0.08, 0.2, 1),
      _positionedRegion('right-top', '上', 0.55, 0.1, 0.08, 0.2, 2),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(1));
    expect(units.single.regionIds, ['right-top', 'right-bottom', 'left']);
    expect(units.single.sourceLines, ['上', '下', '左']);
  });

  test('different bubble groups remain separate despite close positions', () {
    final artifact = _ocrArtifact([
      _positionedRegion('a', '甲', 0.55, 0.1, 0.08, 0.3, 0,
          bubbleGroupId: 1),
      _positionedRegion('b', '乙', 0.45, 0.1, 0.08, 0.3, 1,
          bubbleGroupId: 2),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('staggered columns without rectangular contact stay separate', () {
    final artifact = _ocrArtifact([
      _positionedRegion('right', '右列', 0.58, 0.08, 0.08, 0.22, 0,
          bubbleGroupId: 7),
      _positionedRegion('left', '左列', 0.34, 0.64, 0.08, 0.22, 1,
          bubbleGroupId: 7),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(2));
  });

  test('connected bubble lobes separated on the reading axis stay separate', () {
    const bubble = [
      NormalizedPoint(0.44, 0.04),
      NormalizedPoint(0.72, 0.04),
      NormalizedPoint(0.72, 0.28),
      NormalizedPoint(0.58, 0.28),
      NormalizedPoint(0.58, 0.49),
      NormalizedPoint(0.3, 0.49),
      NormalizedPoint(0.3, 0.25),
      NormalizedPoint(0.44, 0.25),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion('upper-right', '上右', 0.58, 0.08, 0.08, 0.18, 0,
          bubbleGroupId: 7, bubblePolygon: bubble),
      _positionedRegion('upper-left', '上左', 0.48, 0.1, 0.08, 0.18, 1,
          bubbleGroupId: 7, bubblePolygon: bubble),
      _positionedRegion('lower-right', '下右', 0.5, 0.27, 0.08, 0.18, 2,
          bubbleGroupId: 7, bubblePolygon: bubble),
      _positionedRegion('lower-left', '下左', 0.4, 0.29, 0.08, 0.18, 3,
          bubbleGroupId: 7, bubblePolygon: bubble),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(2));
    expect(units.map((unit) => unit.regionIds.toSet().join(',')).toSet(), {
      'upper-right,upper-left',
      'lower-right,lower-left',
    });
  });

  test('concave bubble keeps close high-overlap text together', () {
    const bubble = [
      NormalizedPoint(0.44, 0.04),
      NormalizedPoint(0.72, 0.04),
      NormalizedPoint(0.72, 0.28),
      NormalizedPoint(0.58, 0.28),
      NormalizedPoint(0.58, 0.49),
      NormalizedPoint(0.3, 0.49),
      NormalizedPoint(0.3, 0.25),
      NormalizedPoint(0.44, 0.25),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'long', '好きなの', 0.54, 0.08, 0.07, 0.28, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'overlap', 'いいわよ', 0.555, 0.17, 0.07, 0.28, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(1));
  });

  test('centered short column remains with a longer column', () {
    const bubble = [
      NormalizedPoint(0.3, 0.04),
      NormalizedPoint(0.72, 0.04),
      NormalizedPoint(0.72, 0.76),
      NormalizedPoint(0.3, 0.76),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'long', '这是一个比较长的句子', 0.56, 0.08, 0.08, 0.5, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'short', '短句', 0.46, 0.28, 0.08, 0.1, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(1));
    expect(units.single.regionIds, ['long', 'short']);
  });

  test('overlapping columns have no gap between same and adjacent bands', () {
    const bubble = [
      NormalizedPoint(0.78, 0.36),
      NormalizedPoint(0.9, 0.36),
      NormalizedPoint(0.9, 0.54),
      NormalizedPoint(0.78, 0.54),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'r9', 'さーてと', 0.839, 0.415, 0.026, 0.068, 0,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'r11', 'お風呂', 0.8245, 0.424, 0.026, 0.0504, 1,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.bandRegionIds, hasLength(2));
  });

  test('main-axis mask bias does not split three staggered body regions', () {
    const bubble = [
      NormalizedPoint(0.3, 0.05),
      NormalizedPoint(0.72, 0.05),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.3, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'r9', 'さーてと', 0.6, 0.12, 0.06, 0.22, 0,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.6, 0.12), NormalizedPoint(0.66, 0.12),
          NormalizedPoint(0.66, 0.34), NormalizedPoint(0.6, 0.34),
        ]],
      ),
      _positionedRegion(
        'r10', 'お風呂', 0.5, 0.24, 0.06, 0.22, 1,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.5, 0.24), NormalizedPoint(0.56, 0.24),
          NormalizedPoint(0.56, 0.46), NormalizedPoint(0.5, 0.46),
        ]],
      ),
      _positionedRegion(
        'r11', '入りましょうか', 0.4, 0.34, 0.06, 0.34, 2,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.4, 0.55), NormalizedPoint(0.46, 0.55),
          NormalizedPoint(0.46, 0.68), NormalizedPoint(0.4, 0.68),
        ]],
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.orientation, ComicTextOrientation.vertical);
    expect(unit.bandRegionIds, hasLength(3));
  });

  test('main-axis mask bias does not split two overlapping body columns', () {
    const bubble = [
      NormalizedPoint(0.32, 0.08),
      NormalizedPoint(0.72, 0.08),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.32, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'r16', '日焼け止め', 0.58, 0.22, 0.06, 0.35, 0,
        bubbleGroupId: 2,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.58, 0.22), NormalizedPoint(0.64, 0.22),
          NormalizedPoint(0.64, 0.57), NormalizedPoint(0.58, 0.57),
        ]],
      ),
      _positionedRegion(
        'r17', '見ていい？', 0.46, 0.4, 0.06, 0.32, 1,
        bubbleGroupId: 2,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.46, 0.58), NormalizedPoint(0.52, 0.58),
          NormalizedPoint(0.52, 0.72), NormalizedPoint(0.46, 0.72),
        ]],
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.orientation, ComicTextOrientation.vertical);
    expect(unit.bandRegionIds, hasLength(2));
  });

  test('resolved native bubble is not split into an extra text group', () {
    const upperLobe = [
      NormalizedPoint(0.42, 0.04),
      NormalizedPoint(0.7, 0.04),
      NormalizedPoint(0.7, 0.42),
      NormalizedPoint(0.42, 0.42),
    ];
    const lowerLobe = [
      NormalizedPoint(0.3, 0.48),
      NormalizedPoint(0.58, 0.48),
      NormalizedPoint(0.58, 0.86),
      NormalizedPoint(0.3, 0.86),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'upper-long', '较长的句子', 0.55, 0.07, 0.07, 0.2, 0,
        bubbleGroupId: 7,
        bubblePolygon: upperLobe,
      ),
      _positionedRegion(
        'upper-short', '短句', 0.55, 0.31, 0.07, 0.07, 1,
        bubbleGroupId: 7,
        bubblePolygon: upperLobe,
      ),
      _positionedRegion(
        'lower', '另一个气泡', 0.43, 0.56, 0.07, 0.2, 2,
        bubbleGroupId: 8,
        bubblePolygon: lowerLobe,
      ),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(2));
    expect(units.first.regionIds, ['upper-long', 'upper-short']);
  });

  test('distant text on one bubble outline is not forced into its group', () {
    const bubble = [
      NormalizedPoint(0.3, 0.04),
      NormalizedPoint(0.72, 0.04),
      NormalizedPoint(0.72, 0.9),
      NormalizedPoint(0.3, 0.9),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'dialogue', '气泡正文', 0.54, 0.08, 0.07, 0.18, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'outline-noise', '边缘文字', 0.54, 0.72, 0.07, 0.1, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('single-character endpoint contact joins the neighboring column', () {
    const bubble = [
      NormalizedPoint(0.34, 0.16),
      NormalizedPoint(0.64, 0.16),
      NormalizedPoint(0.64, 0.82),
      NormalizedPoint(0.34, 0.82),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'prefix', '前', 0.5, 0.28, 0.16, 0.07, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
        orientation: ComicTextOrientation.horizontal,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.5, 0.28),
          NormalizedPoint(0.57, 0.28),
          NormalizedPoint(0.57, 0.35),
          NormalizedPoint(0.5, 0.35),
        ]],
      ),
      _positionedRegion(
        'body', '映画の広告', 0.43, 0.35, 0.07, 0.35, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.orientation, ComicTextOrientation.vertical);
  });

  test('ambiguous single character follows neighboring vertical text', () {
    final artifact = _ocrArtifact([
      _positionedRegion(
        'prefix', '前', 0.52, 0.28, 0.07, 0.07, 0,
        orientation: ComicTextOrientation.horizontal,
      ),
      _positionedRegion(
        'body', '映画の広告', 0.43, 0.35, 0.07, 0.35, 1,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(1));
  });

  test('parallel columns survive OCR box overlap when centers stay distinct', () {
    const bubble = [
      NormalizedPoint(0.38, 0.12),
      NormalizedPoint(0.72, 0.12),
      NormalizedPoint(0.72, 0.86),
      NormalizedPoint(0.38, 0.86),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'right', '……なんで', 0.55, 0.25, 0.1, 0.4, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'left', '一緒なの', 0.475, 0.42, 0.1, 0.28, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.bandRegionIds, hasLength(2));
  });

  test('partly outside bubble text does not join by short-span overlap', () {
    const bubble = [
      NormalizedPoint(0.32, 0.08),
      NormalizedPoint(0.72, 0.08),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.32, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'body', '明日昼置き確定', 0.45, 0.25, 0.12, 0.45, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'edge', 'はぁ…', 0.68, 0.12, 0.12, 0.25, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('large annotation stays separate from body in one OCR bubble', () {
    const bubble = [
      NormalizedPoint(0.3, 0.08),
      NormalizedPoint(0.72, 0.08),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.3, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'body', '明日昼置き確定', 0.48, 0.3, 0.06, 0.42, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'annotation', 'はぁ…', 0.59, 0.12, 0.1, 0.24, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('distant oversized single mark stays outside the dialogue group', () {
    const bubble = [
      NormalizedPoint(0.3, 0.08),
      NormalizedPoint(0.72, 0.08),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.3, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'body', 'やめなかったの', 0.48, 0.18, 0.06, 0.52, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'mark', '北', 0.12, 0.4, 0.25, 0.18, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.2, 0.43),
          NormalizedPoint(0.32, 0.43),
          NormalizedPoint(0.32, 0.55),
          NormalizedPoint(0.2, 0.55),
        ]],
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('cross distance is smooth at 1.9 chars and penalizes farther text', () {
    const bubble = [
      NormalizedPoint(0.2, 0.08),
      NormalizedPoint(0.75, 0.08),
      NormalizedPoint(0.75, 0.82),
      NormalizedPoint(0.2, 0.82),
    ];
    ComicOcrArtifact artifact(double distance) => _ocrArtifact([
      _positionedRegion(
        'right', '右側の本文だ', 0.55, 0.2, 0.05, 0.3, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'left', '左側の本文だ', 0.55 - distance * 0.05,
        0.2, 0.05, 0.3, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact(1.89)), hasLength(1));
    expect(ComicTranslationUnit.fromOcr(artifact(1.91)), hasLength(1));
    expect(ComicTranslationUnit.fromOcr(artifact(2.4)), hasLength(2));
  });

  test('punctuation-only groups are not submitted for translation', () {
    final artifact = _ocrArtifact([
      _positionedRegion('noise', '……?!', 0.5, 0.2, 0.08, 0.2, 0),
      _positionedRegion('fragment', '……ら', 0.2, 0.7, 0.08, 0.2, 1),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), isEmpty);
  });

  test('sound effects are submitted only when explicitly enabled', () {
    final artifact = _ocrArtifact([
      _ocrRegion(
        'sfx',
        'ドン',
        0,
        1,
        kind: ComicTextKind.soundEffect,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), isEmpty);
    expect(
      ComicTranslationUnit.fromOcr(
        artifact,
        translateSoundEffects: true,
      ).single.sourceLines,
      ['ドン'],
    );
  });

  test('layout and translation resolver share group key and band order', () {
    final artifact = _ocrArtifact([
      _positionedRegion('left', '左', 0.42, 0.12, 0.08, 0.42, 0),
      _positionedRegion('right-bottom', '下', 0.55, 0.34, 0.08, 0.2, 1),
      _positionedRegion('right-top', '上', 0.55, 0.1, 0.08, 0.2, 2),
    ]);
    final grouping = ComicTextGrouping(
      imageWidth: artifact.imageWidth,
      imageHeight: artifact.imageHeight,
      sourceLanguage: artifact.sourceLanguage,
    );
    final groups = grouping.resolve(artifact.regions.map((region) =>
        ComicTextRegion(
          value: region,
          id: region.id,
          text: region.text,
          polygon: region.polygon,
          sourceMaskPolygons: region.sourceMaskPolygons,
          orientation: region.orientation,
          backgroundArgb: region.backgroundArgb,
          bubbleGroupId: region.bubbleGroupId,
          bubblePolygon: region.bubblePolygon,
        )).toList());
    expect(groups.single.key, ComicTranslationUnit.fromOcr(artifact).single.id);
    expect(groups.single.bands.map((band) =>
        band.regions.map((region) => region.id).toList()).toList(), [
      ['right-top', 'right-bottom'],
      ['left'],
    ]);
  });

  test('one bubble is translated jointly and split back into OCR columns', () async {
    final image = File('${temp.path}/grouped-page.bin');
    await image.writeAsBytes(List<int>.generate(257, (i) => i & 0xff));
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(),
      sourceKey: 'local',
      comicId: 'grouped-comic',
      chapterId: 'chapter',
      pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final ocr = _OcrEngine(
      version: 'grouped',
      regions: [
        _ocrRegion('r2', '三', 0, 9, left: 0.1),
        _ocrRegion('r0', '一', 2, 9, left: 0.7),
        _ocrRegion('r1', '二', 1, 9, left: 0.4),
        _ocrRegion(
          'sfx',
          'BOOM',
          3,
          10,
          kind: ComicTextKind.soundEffect,
        ),
      ],
    );
    final translator = _TranslationEngine.lines(const ['译一', '译二', '译三']);
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final session = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ko',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    session.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    final state = await _waitFor(session, identity);
    final artifact = state.artifact!;
    final unit = translator.lastRequest!.units.single;
    expect(unit.id, 'regions:r0,r1,r2');
    expect(unit.regionIds, ['r0', 'r1', 'r2']);
    expect(unit.sourceLines, ['一', '二', '三']);
    final translated = {
      for (final region in artifact.regions)
        region.ocrRegionId: region.translatedText,
    };
    expect(translated, {
      'r2': '译三',
      'r0': '译一',
      'r1': '译二',
      'sfx': '',
    });
    expect(state.cleanOverlayPng, isNull);
    session.dispose();
  });

  test('one session uses the mean font scale for every text block', () async {
    final image = File('${temp.path}/typography-page.bin');
    await image.writeAsBytes(List<int>.generate(258, (i) => i & 0xff));
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(),
      sourceKey: 'local',
      comicId: 'typography-comic',
      chapterId: 'chapter',
      pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = _OcrEngine(
        version: 'typography',
        regions: [
          _ocrRegion('r0', '四个文字', 0, 4, left: 0.6),
          _ocrRegion('r1', '一', 1, 4, left: 0.3),
        ],
      )
      ..translationEngine = _TranslationEngine.lines(const ['中', '四个文字']);
    final session = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    session.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(session, identity);
    expect(session.fontScaleListenable.value, closeTo(1.01, 0.0001));
    session.dispose();
  });

  test('multi-column translation requires one result per OCR column', () {
    final ocr = ComicOcrArtifact(
      contentDigest: 'digest',
      engineId: 'ocr',
      modelVersion: '1',
      sourceLanguage: 'ja',
      imageWidth: 100,
      imageHeight: 100,
      mediaKind: ComicTranslationMediaKind.staticImage,
      animatedMode: AnimatedTranslationMode.posterFrame,
      regions: [
        _ocrRegion('right', '右', 0, 1, left: 0.7),
        _ocrRegion('left', '左', 1, 1, left: 0.3),
      ],
    );
    final request = ComicTranslationRequest(
      ocr: ocr,
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    expect(
      () => request.expandUnitTranslations(
        const ComicTranslationResult({'bubble:1': ['只有一列']}),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('repeated full balloon translation is distributed only once', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('right', '好きなの', 0, 7, left: 0.55),
        _ocrRegion('left', 'とっていいわよ', 1, 7, left: 0.3),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final unit = request.units.single;
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      unit.id: const ['喜欢哪个就拿哪个', '喜欢哪个就拿哪个'],
    }));
    final values = unit.regionIds.map((id) => expanded[id]!).toList();
    expect(values.join(), '喜欢哪个就拿哪个');
    expect(values.every((value) => value.isNotEmpty), true);
  });

  test('translation keeps source punctuation without adding new marks', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('punctuation', 'そう、そう？', 0, 7),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final unit = request.units.single;
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      unit.id: const ['对，对吧！！'],
    }));
    expect(expanded['punctuation'], '对、对吧？');
  });

  test('source three-dot ellipsis replaces translated punctuation', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('ellipsis', '待って・・・', 0, 7),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final unit = request.units.single;
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      unit.id: const ['等等……。'],
    }));
    expect(expanded['ellipsis'], '等等・・・');
  });

  test('translation break marker survives while added punctuation is removed', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('break', '長い文', 0, 7),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final unit = request.units.single;
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      unit.id: const ['第一句$comicTranslationBreakMarker第二句。'],
    }));
    expect(
      expanded['break'],
      '第一句$comicTranslationBreakMarker第二句',
    );
  });

  test('OCR benchmark runs without a remote translation backend', () async {
    final image = File('${temp.path}/benchmark.bin');
    await image.writeAsBytes(List<int>.generate(128, (i) => i));
    final ocr = _OcrEngine();
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr;
    final result = await ComicTranslationBenchmark(engines: registry).run(
      pages: [
        ComicTranslationPageIdentity(
          imageKey: image.uri.toString(),
          sourceKey: 'benchmark',
          comicId: 'benchmark',
          chapterId: '0',
          pageIndex: 0,
          mediaKind: ComicTranslationMediaKind.staticImage,
        ),
      ],
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
    );
    expect(result.translationMeasured, false);
    expect(result.samples.single.regionCount, 1);
    expect(ocr.loads, 1);
    expect(ocr.unloads, 1);
  });

  test('animated page uses the reserved unsupported state', () async {
    final identity = ComicTranslationPageIdentity(
      imageKey: 'animated.webp',
      sourceKey: 'source',
      comicId: 'comic',
      chapterId: '0',
      pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.animatedImage,
    );
    final session = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
    );
    session.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    expect(
      session.listenable(identity).value.phase,
      ComicTranslationPhase.unsupportedMedia,
    );
    session.dispose();
  });

  test('WebP container inspection rejects animation without source heuristics', () async {
    final image = File('${temp.path}/animated.webp');
    await image.writeAsBytes([
      ...'RIFF'.codeUnits,
      12, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...'ANIM'.codeUnits,
      0, 0, 0, 0,
    ]);
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(),
      sourceKey: 'local',
      comicId: 'comic',
      chapterId: 'chapter',
      pageIndex: 1,
      mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final ocr = _OcrEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = _TranslationEngine();
    final session = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    session.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitForPhase(
      session,
      identity,
      ComicTranslationPhase.unsupportedMedia,
    );
    expect(ocr.calls, 0);
    session.dispose();
  });
}

Future<ComicTranslationPageState> _waitFor(
  ComicTranslationSession session,
  ComicTranslationPageIdentity identity,
) {
  final listenable = session.listenable(identity);
  if (listenable.value.phase == ComicTranslationPhase.ready) {
    return Future.value(listenable.value);
  }
  final completer = Completer<ComicTranslationPageState>();
  void listener() {
    final state = listenable.value;
    if (state.phase == ComicTranslationPhase.ready) {
      listenable.removeListener(listener);
      completer.complete(state);
    } else if (state.phase == ComicTranslationPhase.failed) {
      listenable.removeListener(listener);
      completer.completeError(state.error!);
    }
  }
  listenable.addListener(listener);
  return completer.future;
}

Future<void> _waitForPhase(
  ComicTranslationSession session,
  ComicTranslationPageIdentity identity,
  ComicTranslationPhase phase,
) {
  final listenable = session.listenable(identity);
  if (listenable.value.phase == phase) return Future.value();
  final completer = Completer<void>();
  void listener() {
    if (listenable.value.phase != phase) return;
    listenable.removeListener(listener);
    completer.complete();
  }
  listenable.addListener(listener);
  return completer.future;
}

final class _OcrEngine implements ComicOcrEngine {
  final String version;
  final List<ComicOcrRegion>? regions;
  int calls = 0;
  int loads = 0;
  int unloads = 0;

  _OcrEngine({this.version = '1', this.regions});

  @override
  String get id => 'test-ocr';

  @override
  String get modelVersion => version;

  @override
  bool get supportsAnimatedPosterFrame => false;

  @override
  Future<void> load(String sourceLanguage) async => loads++;

  @override
  Future<ComicOcrArtifact> recognize(ComicOcrInput input) async {
    calls++;
    return ComicOcrArtifact(
      contentDigest: input.contentDigest,
      engineId: id,
      modelVersion: modelVersion,
      sourceLanguage: input.sourceLanguage,
      imageWidth: 100,
      imageHeight: 100,
      mediaKind: ComicTranslationMediaKind.staticImage,
      animatedMode: AnimatedTranslationMode.posterFrame,
      regions: regions ?? const [
        ComicOcrRegion(
          id: 'r0',
          polygon: [
            NormalizedPoint(0.1, 0.1),
            NormalizedPoint(0.9, 0.1),
            NormalizedPoint(0.9, 0.5),
            NormalizedPoint(0.1, 0.5),
          ],
          text: 'こんにちは',
          confidence: 0.9,
          orientation: ComicTextOrientation.vertical,
          kind: ComicTextKind.dialogue,
          readingOrder: 0,
          sourceMaskPolygons: [
            [
              NormalizedPoint(0.12, 0.12),
              NormalizedPoint(0.2, 0.12),
              NormalizedPoint(0.2, 0.3),
              NormalizedPoint(0.12, 0.3),
            ],
          ],
          backgroundArgb: 0xFFFFFFFF,
          foregroundArgb: 0xFF202020,
          bubbleGroupId: 3,
          bubblePolygon: [
            NormalizedPoint(0.05, 0.05),
            NormalizedPoint(0.95, 0.05),
            NormalizedPoint(0.95, 0.55),
            NormalizedPoint(0.05, 0.55),
          ],
        ),
      ],
      cleanOverlayPng: regions == null
          ? Uint8List.fromList(const [1, 2, 3])
          : null,
    );
  }

  @override
  Future<void> unload() async => unloads++;
}

final class _TranslationEngine implements ComicTextTranslationEngine {
  final String translatedText;
  final List<String>? translatedLines;
  int calls = 0;
  int loads = 0;
  int unloads = 0;
  ComicTranslationRequest? lastRequest;

  _TranslationEngine() : translatedText = '你好', translatedLines = null;

  _TranslationEngine.lines(this.translatedLines) : translatedText = '';

  @override
  String get id => 'test-translation';

  @override
  String get modelVersion => '1';

  @override
  Future<void> load() async => loads++;

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    calls++;
    lastRequest = request;
    return ComicTranslationResult({
      for (final unit in request.units)
        unit.id: translatedLines ??
            List.filled(unit.regionIds.length, translatedText),
    });
  }

  @override
  Future<void> unload() async => unloads++;
}

ComicOcrRegion _ocrRegion(
  String id,
  String text,
  int readingOrder,
  int bubbleGroupId, {
  ComicTextKind kind = ComicTextKind.dialogue,
  double left = 0.1,
}) => ComicOcrRegion(
  id: id,
  polygon: [
    NormalizedPoint(left, 0.1),
    NormalizedPoint(left + 0.2, 0.1),
    NormalizedPoint(left + 0.2, 0.5),
    NormalizedPoint(left, 0.5),
  ],
  text: text,
  confidence: 0.9,
  orientation: ComicTextOrientation.vertical,
  kind: kind,
  readingOrder: readingOrder,
  sourceMaskPolygons: const [],
  bubbleGroupId: bubbleGroupId,
);

ComicOcrArtifact _ocrArtifact(List<ComicOcrRegion> regions) => ComicOcrArtifact(
  contentDigest: 'content',
  engineId: 'test',
  modelVersion: '1',
  sourceLanguage: 'ja',
  imageWidth: 1000,
  imageHeight: 1000,
  mediaKind: ComicTranslationMediaKind.staticImage,
  animatedMode: AnimatedTranslationMode.posterFrame,
  regions: regions,
);

ComicOcrRegion _positionedRegion(
  String id,
  String text,
  double left,
  double top,
  double width,
  double height,
  int readingOrder, {
  int? bubbleGroupId,
  List<NormalizedPoint>? bubblePolygon,
  ComicTextOrientation orientation = ComicTextOrientation.vertical,
  List<List<NormalizedPoint>> sourceMaskPolygons = const [],
}) => ComicOcrRegion(
  id: id,
  polygon: [
    NormalizedPoint(left, top),
    NormalizedPoint(left + width, top),
    NormalizedPoint(left + width, top + height),
    NormalizedPoint(left, top + height),
  ],
  text: text,
  confidence: 0.9,
  orientation: orientation,
  kind: ComicTextKind.dialogue,
  readingOrder: readingOrder,
  sourceMaskPolygons: sourceMaskPolygons,
  backgroundArgb: 0xffffffff,
  bubbleGroupId: bubbleGroupId,
  bubblePolygon: bubblePolygon,
);
