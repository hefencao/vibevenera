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
    await File('${source.path}${Platform.pathSeparator}$name').writeAsBytes(bytes);
    files[name] = sha256.convert(bytes).toString();
  }
  final manifest = {
    'schemaVersion': schemaVersion,
    'engine': ComicLocalTranslationModel.engine,
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
    manifest['sourcePrefix'] = '${sourcePrefixTokens.join(' ')} '
        .trimLeft();
  }
  if (schemaVersion >= 2) manifest['sourceEosToken'] = '</s>';
  await File('${source.path}${Platform.pathSeparator}manifest.json')
      .writeAsString(jsonEncode(manifest));
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
    expect(
      manager.pipelineFor('ja-JP', 'zh-TW')?.map((model) => model.id),
      ['ja-en', 'en-zh'],
    );
    expect(
      manager.pipelineFor('ko-KR', 'zh-CN')?.map((model) => model.id),
      ['ko-en', 'en-zh'],
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
          expect(key, startsWith('en-zh:'));
          expect(arguments['texts'], ['I will see you tomorrow.']);
          return ['明天见'];
        });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final engine = LocalCTranslate2ComicTranslationEngine(manager);
    final result = await engine.translate(ComicTranslationRequest(
      ocr: const ComicOcrArtifact(
        contentDigest: 'test',
        engineId: 'test',
        modelVersion: '1',
        sourceLanguage: 'ja',
        imageWidth: 1,
        imageHeight: 1,
        mediaKind: ComicTranslationMediaKind.staticImage,
        animatedMode: AnimatedTranslationMode.posterFrame,
        regions: [ComicOcrRegion(
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
        ), ComicOcrRegion(
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
        )],
      ),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    ));
    expect(result.translations.values.single, ['明天见']);
    expect(engine.lastRawResponses, hasLength(2));
    expect(engine.lastRawResponses.first, contains('また明日'));
    expect(engine.lastRawResponses.first, contains('よろしくね'));
    expect(calls.where((call) => call.method == 'load'), hasLength(2));
    expect(calls.where((call) => call.method == 'translate'), hasLength(2));
    final chineseLoad = calls.where((call) => call.method == 'load')
        .map((call) => Map<String, dynamic>.from(call.arguments as Map))
        .firstWhere((arguments) =>
            (arguments['modelKey'] as String).startsWith('en-zh:'));
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
    final installedManifest = jsonDecode(await File(
      '${legacy.path}${Platform.pathSeparator}installation.json',
    ).readAsString()) as Map;
    expect(installedManifest['schemaVersion'], 4);
    expect(installedManifest['engine'], ComicLocalTranslationModel.engine);
  });
}
