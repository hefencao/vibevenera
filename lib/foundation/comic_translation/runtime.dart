import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/appdata.dart';

import 'engine.dart';
import 'remote_translation.dart';

final class ComicTranslationSecrets {
  ComicTranslationSecrets._();

  static final instance = ComicTranslationSecrets._();

  late String _path;
  String _apiKey = '';

  bool get hasApiKey => _apiKey.isNotEmpty;
  String get apiKey => _apiKey;

  Future<void> init(String dataPath) async {
    _path = '$dataPath/comic_translation_secrets.json';
    final file = File(_path);
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _apiKey = json['apiKey'] as String? ?? '';
  }

  Future<void> setApiKey(String value) async {
    _apiKey = value.trim();
    await File(_path).writeAsString(jsonEncode({'apiKey': _apiKey}), flush: true);
  }
}

final class ComicTranslationRuntime {
  ComicTranslationRuntime._();

  static final instance = ComicTranslationRuntime._();

  Future<void> init(String dataPath) async {
    await ComicTranslationSecrets.instance.init(dataPath);
    configure();
  }

  void configure() {
    final registry = ComicTranslationEngineRegistry.instance;
    registry.translationEngine = switch (appdata.settings['comicTranslationBackend']) {
      'openaiCompatible' => OpenAiCompatibleComicTranslationEngine(
          endpoint: appdata.settings['comicTranslationRemoteEndpoint'] as String,
          model: appdata.settings['comicTranslationRemoteModel'] as String,
          apiKey: ComicTranslationSecrets.instance.apiKey,
        ),
      _ => null,
    };
  }
}
