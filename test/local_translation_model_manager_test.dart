import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_translation/engine.dart';
import 'package:venera/foundation/comic_translation/local_model_manager.dart';
import 'package:venera/foundation/comic_translation/local_translation.dart';
import 'package:venera/foundation/comic_translation/models.dart';

Future<Directory> modelDirectory(
  Directory root,
  String id,
  String sourceLanguage,
  String targetLanguage, {
  String sourcePrefix = '',
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
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'license': 'Apache-2.0',
    'sourcePrefix': sourcePrefix,
    'sourceUrl': 'https://example.com/$id',
    'files': files,
  };
  if (schemaVersion >= 2) manifest['sourceEosToken'] = '</s>';
  await File('${source.path}${Platform.pathSeparator}manifest.json')
      .writeAsString(jsonEncode(manifest));
  return source;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('resolves direct and pivot local translation pipelines', () async {
    final temp = await Directory.systemTemp.createTemp('venera-local-model-');
    addTearDown(() => temp.delete(recursive: true));
    final manager = ComicLocalTranslationModelManager.instance;
    await manager.init('${temp.path}${Platform.pathSeparator}data');
    for (final pair in const [
      ('ja-en', 'ja', 'en', ''),
      ('ko-en', 'ko', 'en', ''),
      ('en-zh', 'en', 'zh-CN', '>>cmn_Hans<< '),
    ]) {
      await manager.installFromDirectory(
        (await modelDirectory(
          temp,
          pair.$1,
          pair.$2,
          pair.$3,
          sourcePrefix: pair.$4,
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
    expect(chinese.sourcePrefix, '>>cmn_Hans<< ');
    expect(chinese.sourceEosToken, '</s>');

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
          expect(arguments['texts'], ['>>cmn_Hans<< I will see you tomorrow.']);
          return ['明天见'];
        });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final engine = LocalMarianComicTranslationEngine(manager);
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
    await engine.unload();

    final direct = await manager.installFromDirectory(
      (await modelDirectory(temp, 'ja-zh', 'ja', 'zh-CN')).path,
    );
    expect(manager.pipelineFor('ja', 'zh-TW'), [direct]);
    expect(
      await File(direct.filePath('model.bin')).readAsString(),
      'ja-zh-model.bin-content',
    );

    final legacy = await manager.installFromDirectory(
      (await modelDirectory(
        temp,
        'legacy-en-ja',
        'en',
        'ja',
        schemaVersion: 1,
      )).path,
    );
    expect(legacy.sourceEosToken, '</s>');
    final installedManifest = jsonDecode(await File(
      '${legacy.path}${Platform.pathSeparator}installation.json',
    ).readAsString()) as Map;
    expect(installedManifest['schemaVersion'], 2);
  });
}
