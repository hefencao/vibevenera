import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/appdata.dart';

import 'engine.dart';
import 'model_manager.dart';
import 'paddle_ocr.dart';
import 'remote_translation.dart';

final class ComicTranslationRemoteProfile {
  final String id;
  final String name;
  final String endpoint;
  final String model;
  final String additionalPrompt;

  const ComicTranslationRemoteProfile({
    required this.id,
    required this.name,
    required this.endpoint,
    required this.model,
    required this.additionalPrompt,
  });

  factory ComicTranslationRemoteProfile.fromJson(Map<String, dynamic> json) =>
      ComicTranslationRemoteProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        endpoint: json['endpoint'] as String,
        model: json['model'] as String,
        additionalPrompt: json['additionalPrompt'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'endpoint': endpoint,
    'model': model,
    'additionalPrompt': additionalPrompt,
  };
}

final class ComicTranslationSecrets {
  ComicTranslationSecrets._();

  static final instance = ComicTranslationSecrets._();

  late String _path;
  String _legacyApiKey = '';
  final Map<String, String> _apiKeys = {};

  bool hasApiKey(String profileId) => apiKeyFor(profileId).isNotEmpty;

  String apiKeyFor(String profileId) =>
      _apiKeys[profileId] ?? (profileId == 'default' ? _legacyApiKey : '');

  Future<void> init(String dataPath) async {
    _path = '$dataPath/comic_translation_secrets.json';
    final file = File(_path);
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _legacyApiKey = json['apiKey'] as String? ?? '';
    _apiKeys.addAll(
      (json['apiKeys'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key as String, value as String),
      ),
    );
  }

  Future<void> setApiKey(String profileId, String value) async {
    final key = value.trim();
    if (profileId == 'default') _legacyApiKey = '';
    if (key.isEmpty) {
      _apiKeys.remove(profileId);
    } else {
      _apiKeys[profileId] = key;
    }
    await _save();
  }

  Future<void> removeProfile(String profileId) async {
    if (profileId == 'default') _legacyApiKey = '';
    _apiKeys.remove(profileId);
    await _save();
  }

  Future<void> _save() => File(_path).writeAsString(jsonEncode({
    'apiKey': _legacyApiKey,
    'apiKeys': _apiKeys,
  }), flush: true);
}

final class ComicTranslationRuntime {
  ComicTranslationRuntime._();

  static final instance = ComicTranslationRuntime._();

  Future<void> init(String dataPath) async {
    await Future.wait([
      ComicTranslationSecrets.instance.init(dataPath),
      ComicTranslationModelManager.instance.init(dataPath),
    ]);
    configure();
  }

  void configure() {
    final registry = ComicTranslationEngineRegistry.instance;
    final models = ComicTranslationModelManager.instance;
    registry.ocrEngine = Platform.isAndroid && models.installed
        ? AndroidPaddleComicOcrEngine(models)
        : null;
    final profiles = (appdata.settings['comicTranslationRemoteProfiles'] as List)
        .map((value) => ComicTranslationRemoteProfile.fromJson(
              Map<String, dynamic>.from(value as Map),
            ))
        .toList();
    final activeId = appdata.settings['comicTranslationRemoteProfile'] as String;
    final profile = profiles.where((profile) => profile.id == activeId).firstOrNull ??
        ComicTranslationRemoteProfile(
          id: 'default',
          name: appdata.settings['comicTranslationRemoteModel'] as String,
          endpoint: appdata.settings['comicTranslationRemoteEndpoint'] as String,
          model: appdata.settings['comicTranslationRemoteModel'] as String,
          additionalPrompt:
              appdata.settings['comicTranslationAdditionalPrompt'] as String,
        );
    registry.translationEngine = switch (appdata.settings['comicTranslationBackend']) {
      'openaiCompatible' => OpenAiCompatibleComicTranslationEngine(
          endpoint: profile.endpoint,
          model: profile.model,
          apiKey: ComicTranslationSecrets.instance.apiKeyFor(profile.id),
          additionalPrompt: profile.additionalPrompt,
        ),
      _ => null,
    };
  }
}
