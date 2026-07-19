import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_translation/local_model_manager.dart';

void main() {
  test('imports and resolves a verified local language-pair model', () async {
    final temp = await Directory.systemTemp.createTemp('venera-local-model-');
    addTearDown(() => temp.delete(recursive: true));
    final source = Directory('${temp.path}${Platform.pathSeparator}source');
    await source.create();
    final files = <String, String>{};
    for (final name in const [
      'model.bin',
      'config.json',
      'source.spm',
      'target.spm',
      'shared_vocabulary.json',
    ]) {
      final bytes = utf8.encode('$name-content');
      await File('${source.path}${Platform.pathSeparator}$name')
          .writeAsBytes(bytes);
      files[name] = sha256.convert(bytes).toString();
    }
    await File('${source.path}${Platform.pathSeparator}manifest.json')
        .writeAsString(jsonEncode({
          'schemaVersion': 1,
          'engine': 'ctranslate2-marian',
          'id': 'test-ja-zh',
          'version': '1',
          'displayName': 'Test Japanese Chinese',
          'sourceLanguage': 'ja',
          'targetLanguage': 'zh-CN',
          'license': 'Apache-2.0',
          'files': files,
        }));
    final manager = ComicLocalTranslationModelManager.instance;
    await manager.init('${temp.path}${Platform.pathSeparator}data');
    final installed = await manager.installFromDirectory(source.path);
    expect(installed.id, 'test-ja-zh');
    expect(manager.modelFor('ja-JP', 'zh-TW')?.id, 'test-ja-zh');
    expect(
      await File(installed.filePath('model.bin')).readAsString(),
      'model.bin-content',
    );
  });
}
