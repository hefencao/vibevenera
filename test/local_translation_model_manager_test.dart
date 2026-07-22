import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_translation/engine.dart';
import 'package:venera/foundation/comic_translation/local_model_manager.dart';
import 'package:venera/foundation/comic_translation/local_translation.dart';
import 'package:venera/foundation/comic_translation/models.dart';
import 'package:venera/utils/opencc.dart';

Future<Directory> modelDirectory(
  Directory root,
  String id,
  String sourceLanguage,
  String targetLanguage, {
  List<String> sourcePrefixTokens = const [],
  List<String>? sourceLanguages,
  List<String> targetPrefixTokens = const [],
  int beamSize = 4,
  int schemaVersion = ComicLocalTranslationModel.schemaVersion,
}) async {
  final source = Directory('${root.path}${Platform.pathSeparator}$id');
  await source.create();
  final files = <String, String>{};
  for (final name in const [
    'model.bin',
    'config.json',
    'source.spm',
    'target.spm',
    'shared_vocabulary.json',
  ]) {
    final bytes = utf8.encode('$id-$name-content');
    await File(
      '${source.path}${Platform.pathSeparator}$name',
    ).writeAsBytes(bytes);
    files[name] = sha256.convert(bytes).toString();
  }
  final manifest = {
    'schemaVersion': schemaVersion,
    'engine': ComicLocalTranslationModel.ctranslate2Engine,
    'id': id,
    'version': '1',
    'displayName': id,
    'targetLanguage': targetLanguage,
    'license': 'Apache-2.0',
    'sourceUrl': 'https://example.com/$id',
    'files': files,
  };
  if (schemaVersion >= 4) {
    manifest['sourceLanguages'] = sourceLanguages ?? [sourceLanguage];
    manifest['targetPrefixTokens'] = targetPrefixTokens;
    manifest['beamSize'] = beamSize;
  } else {
    manifest['sourceLanguage'] = sourceLanguage;
  }
  if (schemaVersion >= 3) {
    manifest['sourcePrefixTokens'] = sourcePrefixTokens;
  } else {
    manifest['sourcePrefix'] = '${sourcePrefixTokens.join(' ')} '.trimLeft();
  }
  if (schemaVersion >= 2) manifest['sourceEosToken'] = '</s>';
  await File(
    '${source.path}${Platform.pathSeparator}manifest.json',
  ).writeAsString(jsonEncode(manifest));
  return source;
}

Future<Directory> hyModelDirectory(Directory root) async {
  final source = Directory('${root.path}${Platform.pathSeparator}hy-mt');
  await source.create();
  final bytes = utf8.encode('fake-gguf');
  await File(
    '${source.path}${Platform.pathSeparator}model.gguf',
  ).writeAsBytes(bytes);
  await File(
    '${source.path}${Platform.pathSeparator}manifest.json',
  ).writeAsString(
    jsonEncode({
      'schemaVersion': ComicLocalTranslationModel.schemaVersion,
      'engine': ComicLocalTranslationModel.hyMtGgufEngine,
      'id': 'hy-mt',
      'version': '1',
      'displayName': 'Hy-MT',
      'sourceLanguages': ['ja', 'ko'],
      'targetLanguage': 'zh-CN',
      'license': 'test',
      'sourcePrefixTokens': <String>[],
      'sourceEosToken': '',
      'targetPrefixTokens': <String>[],
      'beamSize': 1,
      'promptTemplate': 'Translate to Chinese:\n{text}',
      'contextSize': 1024,
      'maxOutputTokens': 256,
      'sourceUrl': 'https://example.com/hy-mt',
      'files': {'model.gguf': sha256.convert(bytes).toString()},
    }),
  );
  return source;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('resolves direct and pivot local translation pipelines', () async {
    await OpenCC.init();
    expect(OpenCC.traditionalToSimplified('什麼麽'), '什么么');
    final temp = await Directory.systemTemp.createTemp('venera-local-model-');
    addTearDown(() => temp.delete(recursive: true));
    final manager = ComicLocalTranslationModelManager.instance;
    await manager.init('${temp.path}${Platform.pathSeparator}data');
    for (final pair in const [
      ('ja-en', 'ja', 'en', <String>[]),
      ('ko-en', 'ko', 'en', <String>[]),
      ('en-zh', 'en', 'zh-CN', ['>>cmn_Hans<<']),
    ]) {
      await manager.installFromDirectory(
        (await modelDirectory(
          temp,
          pair.$1,
          pair.$2,
          pair.$3,
          sourcePrefixTokens: pair.$4,
        )).path,
      );
    }
    expect(manager.pipelineFor('ja-JP', 'zh-TW')?.map((model) => model.id), [
      'ja-en',
      'en-zh',
    ]);
    expect(manager.pipelineFor('ko-KR', 'zh-CN')?.map((model) => model.id), [
      'ko-en',
      'en-zh',
    ]);
    expect(
      manager
          .pipelineFor('ja', 'zh-CN', modelId: 'ja-en')
          ?.map((model) => model.id),
      ['ja-en', 'en-zh'],
    );
    final chinese = manager.modelFor('en', 'zh-TW')!;
    expect(chinese.sourcePrefixTokens, ['>>cmn_Hans<<']);
    expect(chinese.sourceEosToken, '</s>');
    expect(chinese.beamSize, 4);

    const channel = MethodChannel('venera/comic_translation_local');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'load' || call.method == 'unload') return null;
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          final key = arguments['modelKey'] as String;
          if (key.startsWith('ja-en:')) {
            final texts = (arguments['texts'] as List).cast<String>();
            expect(texts, hasLength(1));
            expect(texts.single, contains('また明日'));
            expect(texts.single, contains('よろしくね'));
            return ['I will see you tomorrow.'];
          }
          if (key.startsWith('ja-ko-zh:')) return ['译文', ''];
          expect(key, startsWith('en-zh:'));
          expect(arguments['texts'], ['I will see you tomorrow.']);
          return ['明天见'];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final engine = LocalComicTranslationEngine(manager);
    final result = await engine.translate(
      ComicTranslationRequest(
        ocr: const ComicOcrArtifact(
          contentDigest: 'test',
          engineId: 'test',
          modelVersion: '1',
          sourceLanguage: 'ja',
          imageWidth: 1,
          imageHeight: 1,
          mediaKind: ComicTranslationMediaKind.staticImage,
          animatedMode: AnimatedTranslationMode.posterFrame,
          regions: [
            ComicOcrRegion(
              id: 'r0',
              polygon: [
                NormalizedPoint(0.1, 0.1),
                NormalizedPoint(0.2, 0.1),
                NormalizedPoint(0.2, 0.4),
                NormalizedPoint(0.1, 0.4),
              ],
              text: 'また明日',
              confidence: 1,
              orientation: ComicTextOrientation.vertical,
              kind: ComicTextKind.dialogue,
              readingOrder: 0,
              sourceMaskPolygons: [],
              bubbleGroupId: 0,
            ),
            ComicOcrRegion(
              id: 'r1',
              polygon: [
                NormalizedPoint(0.21, 0.1),
                NormalizedPoint(0.31, 0.1),
                NormalizedPoint(0.31, 0.4),
                NormalizedPoint(0.21, 0.4),
              ],
              text: 'よろしくね',
              confidence: 1,
              orientation: ComicTextOrientation.vertical,
              kind: ComicTextKind.dialogue,
              readingOrder: 1,
              sourceMaskPolygons: [],
              bubbleGroupId: 0,
            ),
          ],
        ),
        targetLanguage: 'zh-CN',
        previousPages: const [],
      ),
    );
    expect(result.translations.values.single, ['明天见']);
    expect(engine.lastRawResponses, hasLength(2));
    expect(engine.lastRawResponses.first, contains('また明日'));
    expect(engine.lastRawResponses.first, contains('よろしくね'));
    expect(calls.where((call) => call.method == 'load'), hasLength(2));
    expect(calls.where((call) => call.method == 'translate'), hasLength(2));
    final chineseLoad = calls
        .where((call) => call.method == 'load')
        .map((call) => Map<String, dynamic>.from(call.arguments as Map))
        .firstWhere(
          (arguments) => (arguments['modelKey'] as String).startsWith('en-zh:'),
        );
    expect(chineseLoad['sourcePrefixTokens'], ['>>cmn_Hans<<']);
    expect(chineseLoad['targetPrefixTokens'], isEmpty);
    expect(chineseLoad['beamSize'], 4);
    await engine.unload();

    final direct = await manager.installFromDirectory(
      (await modelDirectory(
        temp,
        'ja-ko-zh',
        'ja',
        'zh-CN',
        sourceLanguages: const ['ja', 'ko'],
        sourcePrefixTokens: const ['__zh__'],
        targetPrefixTokens: const ['__zh__'],
        beamSize: 5,
      )).path,
    );
    expect(manager.pipelineFor('ja', 'zh-TW'), [direct]);
    expect(manager.pipelineFor('ko', 'zh-CN'), [direct]);
    expect(
      await File(direct.filePath('model.bin')).readAsString(),
      'ja-ko-zh-model.bin-content',
    );

    final partial =
        await LocalComicTranslationEngine(
          manager,
          selectedModelId: direct.id,
        ).translate(
          ComicTranslationRequest(
            ocr: const ComicOcrArtifact(
              contentDigest: 'empty-unit',
              engineId: 'test',
              modelVersion: '1',
              sourceLanguage: 'ja',
              imageWidth: 1,
              imageHeight: 1,
              mediaKind: ComicTranslationMediaKind.staticImage,
              animatedMode: AnimatedTranslationMode.posterFrame,
              regions: [],
            ),
            units: const [
              ComicTranslationUnit(
                id: 'r0',
                regionIds: ['r0'],
                sourceLines: ['原文一'],
                orientation: ComicTextOrientation.vertical,
                bandRegionIds: [
                  ['r0'],
                ],
              ),
              ComicTranslationUnit(
                id: 'r1',
                regionIds: ['r1'],
                sourceLines: ['原文二'],
                orientation: ComicTextOrientation.vertical,
                bandRegionIds: [
                  ['r1'],
                ],
              ),
            ],
            targetLanguage: 'zh-CN',
            previousPages: const [],
          ),
        );
    expect(partial.translations['r0'], ['译文']);
    expect(partial.translations['r1'], ['原文二']);

    final legacy = await manager.installFromDirectory(
      (await modelDirectory(
        temp,
        'legacy-en-ja',
        'en',
        'ja',
        schemaVersion: 2,
        sourcePrefixTokens: const ['>>ja<<'],
      )).path,
    );
    expect(legacy.sourceEosToken, '</s>');
    expect(legacy.sourcePrefixTokens, ['>>ja<<']);
    final installedManifest =
        jsonDecode(
              await File(
                '${legacy.path}${Platform.pathSeparator}installation.json',
              ).readAsString(),
            )
            as Map;
    expect(
      installedManifest['schemaVersion'],
      ComicLocalTranslationModel.schemaVersion,
    );
    expect(
      installedManifest['engine'],
      ComicLocalTranslationModel.ctranslate2Engine,
    );

    final hy = await manager.installFromDirectory(
      (await hyModelDirectory(temp)).path,
    );
    expect(manager.pipelineFor('ko', 'zh-CN', modelId: hy.id), [hy]);
    const hyChannel = MethodChannel('venera/comic_translation_hymt');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hyChannel, (call) async {
          if (call.method == 'load' || call.method == 'unload') return null;
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          expect(arguments['texts'], hasLength(1));
          final prompt = (arguments['texts'] as List).single as String;
          expect(prompt, contains('上文（仅供参考）：'));
          expect(prompt, contains('原文：おはよう'));
          expect(prompt, contains('译文：早上好'));
          expect(prompt, contains('翻译为中文'));
          expect(prompt, contains('また明日'));
          return ['明天见'];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hyChannel, null),
    );
    final hyResult =
        await LocalComicTranslationEngine(
          manager,
          selectedModelId: hy.id,
        ).translate(
          ComicTranslationRequest(
            ocr: const ComicOcrArtifact(
              contentDigest: 'hy',
              engineId: 'test',
              modelVersion: '1',
              sourceLanguage: 'ja',
              imageWidth: 1,
              imageHeight: 1,
              mediaKind: ComicTranslationMediaKind.staticImage,
              animatedMode: AnimatedTranslationMode.posterFrame,
              regions: [],
            ),
            units: const [
              ComicTranslationUnit(
                id: 'r0',
                regionIds: ['r0'],
                sourceLines: ['また明日'],
                orientation: ComicTextOrientation.vertical,
                bandRegionIds: [
                  ['r0'],
                ],
              ),
            ],
            targetLanguage: 'zh-CN',
            previousPages: const [
              ComicTranslationContextEntry(
                pageIndex: 0,
                sourceTexts: ['おはよう'],
                translatedTexts: ['早上好'],
              ),
            ],
          ),
        );
    expect(hyResult.translations['r0'], ['明天见']);
    expect(
      LocalComicTranslationEngine(manager, selectedModelId: hy.id).contextMode,
      ComicTranslationContextMode.previousPages,
    );
    expect(
      LocalComicTranslationEngine(
        manager,
        selectedModelId: direct.id,
      ).contextMode,
      ComicTranslationContextMode.none,
    );
  });
}
