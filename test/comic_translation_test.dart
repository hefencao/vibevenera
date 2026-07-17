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
    expect(secondState.cleanOverlayPng, [1, 2, 3]);
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    second.dispose();
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

  test('staggered columns in one bubble use normalized cross-axis distance', () {
    final artifact = _ocrArtifact([
      _positionedRegion('right', '右列', 0.58, 0.08, 0.08, 0.22, 0,
          bubbleGroupId: 7),
      _positionedRegion('left', '左列', 0.34, 0.64, 0.08, 0.22, 1,
          bubbleGroupId: 7),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(1));
    expect(units.single.regionIds, ['right', 'left']);
  });

  test('connected bubble lobes separated on the reading axis stay separate', () {
    const bubble = [
      NormalizedPoint(0.3, 0.04),
      NormalizedPoint(0.72, 0.04),
      NormalizedPoint(0.72, 0.76),
      NormalizedPoint(0.3, 0.76),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion('upper-right', '上右', 0.58, 0.08, 0.08, 0.18, 0,
          bubbleGroupId: 7, bubblePolygon: bubble),
      _positionedRegion('upper-left', '上左', 0.48, 0.1, 0.08, 0.18, 1,
          bubbleGroupId: 7, bubblePolygon: bubble),
      _positionedRegion('lower-right', '下右', 0.54, 0.25, 0.08, 0.18, 2,
          bubbleGroupId: 7, bubblePolygon: bubble),
      _positionedRegion('lower-left', '下左', 0.44, 0.27, 0.08, 0.18, 3,
          bubbleGroupId: 7, bubblePolygon: bubble),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(2));
    expect(units.map((unit) => unit.regionIds.toSet().join(',')).toSet(), {
      'upper-right,upper-left',
      'lower-right,lower-left',
    });
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
    expect(session.fontScaleListenable.value, closeTo(1.085, 0.0001));
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
      cleanOverlayPng: Uint8List.fromList(const [1, 2, 3]),
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
  orientation: ComicTextOrientation.vertical,
  kind: ComicTextKind.dialogue,
  readingOrder: readingOrder,
  sourceMaskPolygons: const [],
  backgroundArgb: 0xffffffff,
  bubbleGroupId: bubbleGroupId,
  bubblePolygon: bubblePolygon,
);
