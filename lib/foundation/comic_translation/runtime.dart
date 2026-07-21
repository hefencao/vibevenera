import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/appdata.dart';

import 'deepl_translation.dart';
import 'engine.dart';
import 'local_model_manager.dart';
import 'local_translation.dart';
import 'ocr_model_manager.dart';
import 'paddle_ocr.dart';
import 'remote_translation.dart';

final class ComicTranslationRemoteProfile {
  final String id;
  final String backend;
  final String name;
  final String endpoint;
  final String model;
  final String additionalPrompt;

  const ComicTranslationRemoteProfile({
    required this.id,
    this.backend = 'openaiCompatible',
    required this.name,
    required this.endpoint,
    required this.model,
    required this.additionalPrompt,
  });

  factory ComicTranslationRemoteProfile.fromJson(Map<String, dynamic> json) =>
      ComicTranslationRemoteProfile(
        id: json['id'] as String,
        backend: json['backend'] as String? ?? 'openaiCompatible',
        name: json['name'] as String,
        endpoint: json['endpoint'] as String,
        model: json['model'] as String,
        additionalPrompt: json['additionalPrompt'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'backend': backend,
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
  Future<void> _writeTail = Future.value();
  bool _initialized = false;

  bool hasApiKey(String profileId) => apiKeyFor(profileId).isNotEmpty;

  String apiKeyFor(String profileId) =>
      _apiKeys[profileId] ?? (profileId == 'default' ? _legacyApiKey : '');

  Future<void> init(String dataPath) async {
    _path = '$dataPath/comic_translation_secrets.json';
    _legacyApiKey = '';
    _apiKeys.clear();
    final file = File(_path);
    final temporary = File('$_path.tmp');
    final backup = File('$_path.bak');
    if (!await file.exists()) {
      if (await temporary.exists()) {
        await temporary.rename(file.path);
      } else if (await backup.exists()) {
        await backup.rename(file.path);
      }
    }
    if (await temporary.exists()) await temporary.delete();
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('Comic translation secrets must be JSON');
      }
      final json = Map<String, dynamic>.from(decoded);
      _legacyApiKey = json['apiKey'] as String? ?? '';
      final keys = json['apiKeys'];
      if (keys is Map) {
        for (final entry in keys.entries) {
          if (entry.key is String && entry.value is String) {
            _apiKeys[entry.key as String] = entry.value as String;
          }
        }
      }
    }
    _initialized = true;
  }

  Future<void> setApiKey(String profileId, String value) async {
    _checkInitialized();
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
    _checkInitialized();
    if (profileId == 'default') _legacyApiKey = '';
    _apiKeys.remove(profileId);
    await _save();
  }

  Future<void> _save() {
    final payload = jsonEncode({
      'apiKey': _legacyApiKey,
      'apiKeys': Map<String, String>.from(_apiKeys),
    });
    final task = _writeTail.then(
      (_) => _write(payload),
      onError: (_, __) => _write(payload),
    );
    _writeTail = task.then<void>((_) {}, onError: (_, __) {});
    return task;
  }

  Future<void> _write(String payload) async {
    final target = File(_path);
    final temporary = File('$_path.tmp');
    final backup = File('$_path.bak');
    await temporary.writeAsString(payload, flush: true);
    if (await backup.exists()) await backup.delete();
    final hadTarget = await target.exists();
    if (hadTarget) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
    } catch (_) {
      if (hadTarget && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    if (await backup.exists()) await backup.delete();
  }

  void _checkInitialized() {
    if (!_initialized) {
      throw StateError('Comic translation secrets are not initialized');
    }
  }
}

List<ComicTranslationRemoteProfile> _remoteProfiles(Object? value) {
  return (value as List).map((entry) =>
      ComicTranslationRemoteProfile.fromJson(
        Map<String, dynamic>.from(entry as Map),
      )).toList();
}

final class ComicTranslationRuntime {
  ComicTranslationRuntime._();

  static final instance = ComicTranslationRuntime._();

  AndroidPaddleComicOcrEngine? _ocrEngine;
  String? _translationConfiguration;
  ComicTextTranslationEngine? _translationEngine;

  Future<void> init(String dataPath) async {
    await Future.wait([
      ComicTranslationSecrets.instance.init(dataPath),
      ComicOcrModelManager.instance.init(dataPath),
      ComicLocalTranslationModelManager.instance.init(dataPath),
    ]);
    configure();
  }

  void configure() {
    final registry = ComicTranslationEngineRegistry.instance;
    final models = ComicOcrModelManager.instance;
    final AndroidPaddleComicOcrEngine? ocrEngine;
    if (Platform.isAndroid && models.installed) {
      ocrEngine = _ocrEngine ??= AndroidPaddleComicOcrEngine(models);
    } else {
      _ocrEngine = null;
      ocrEngine = null;
    }
    final profiles = _remoteProfiles(
      appdata.settings['comicTranslationRemoteProfiles'],
    );
    final activeId = appdata.settings['comicTranslationRemoteProfile'] as String;
    final profile = profiles.where((profile) => profile.id == activeId).firstOrNull ??
        ComicTranslationRemoteProfile(
          id: 'default',
          backend: 'openaiCompatible',
          name: appdata.settings['comicTranslationRemoteModel'] as String,
          endpoint: appdata.settings['comicTranslationRemoteEndpoint'] as String,
          model: appdata.settings['comicTranslationRemoteModel'] as String,
          additionalPrompt:
              appdata.settings['comicTranslationAdditionalPrompt'] as String,
        );
    final backend = appdata.settings['comicTranslationBackend'] as String;
    final localModelId =
        appdata.settings['comicTranslationLocalModel'] as String;
    if (backend != 'none' && backend != 'local' && profile.backend != backend) {
      throw StateError(
        'Comic translation profile ${profile.id} belongs to '
        '${profile.backend}, not $backend',
      );
    }
    final apiKey = ComicTranslationSecrets.instance.apiKeyFor(profile.id);
    final translationConfiguration = backend == 'local'
        ? jsonEncode([
            backend,
            localModelId,
            for (final model in ComicLocalTranslationModelManager.instance.models)
              model.runtimeKey,
          ])
        : jsonEncode([
            backend,
            profile.endpoint.trim(),
            profile.model.trim(),
            profile.additionalPrompt.trim(),
            apiKey,
          ]);
    if (_translationConfiguration != translationConfiguration) {
      _translationConfiguration = translationConfiguration;
      _translationEngine = switch (backend) {
        'openaiCompatible' => OpenAiCompatibleComicTranslationEngine(
          endpoint: profile.endpoint.trim(),
          model: profile.model.trim(),
          apiKey: apiKey,
          additionalPrompt: profile.additionalPrompt.trim(),
        ),
        'deepl' => DeepLComicTranslationEngine(
          endpoint: profile.endpoint.trim(),
          modelType: profile.model.trim(),
          apiKey: apiKey,
        ),
        'local' when Platform.isAndroid => LocalComicTranslationEngine(
          ComicLocalTranslationModelManager.instance,
          selectedModelId: localModelId,
        ),
        _ => null,
      };
    }
    registry.configure(
      ocrEngine: ocrEngine,
      translationEngine: _translationEngine,
    );
  }
}
