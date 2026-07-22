import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/network/app_dio.dart' show RHttpAdapter;

final class ComicLocalTranslationModel {
  static const schemaVersion = 5;
  static const ctranslate2Engine = 'ctranslate2-seq2seq';
  static const hyMtGgufEngine = 'llama.cpp-hymt';
  static const _legacyEngine = 'ctranslate2-marian';

  final String engine;
  final String id;
  final String version;
  final String displayName;
  final List<String> sourceLanguages;
  final String targetLanguage;
  final String license;
  final List<String> sourcePrefixTokens;
  final String sourceEosToken;
  final List<String> targetPrefixTokens;
  final int beamSize;
  final String promptTemplate;
  final int contextSize;
  final int maxOutputTokens;
  final String sourceUrl;
  final Map<String, String> files;
  final String path;

  const ComicLocalTranslationModel({
    required this.engine,
    required this.id,
    required this.version,
    required this.displayName,
    required this.sourceLanguages,
    required this.targetLanguage,
    required this.license,
    required this.sourcePrefixTokens,
    required this.sourceEosToken,
    required this.targetPrefixTokens,
    required this.beamSize,
    required this.promptTemplate,
    required this.contextSize,
    required this.maxOutputTokens,
    required this.sourceUrl,
    required this.files,
    required this.path,
  });

  factory ComicLocalTranslationModel.fromManifest(
    Map<String, dynamic> json,
    String path,
  ) {
    final manifestVersion = json['schemaVersion'] as int;
    final engine = json['engine'] as String;
    if (manifestVersion < 1 ||
        manifestVersion > schemaVersion ||
        engine != ctranslate2Engine &&
            engine != hyMtGgufEngine &&
            engine != _legacyEngine) {
      throw const FormatException('Unsupported local translation model format');
    }
    final files = Map<String, dynamic>.from(
      json['files'] as Map,
    ).map((name, digest) => MapEntry(name, digest as String));
    final model = ComicLocalTranslationModel(
      engine: engine == _legacyEngine ? ctranslate2Engine : engine,
      id: json['id'] as String,
      version: json['version'] as String,
      displayName: json['displayName'] as String,
      sourceLanguages: manifestVersion >= 4
          ? (json['sourceLanguages'] as List)
                .cast<String>()
                .map(_language)
                .toList()
          : [_language(json['sourceLanguage'] as String)],
      targetLanguage: _language(json['targetLanguage'] as String),
      license: json['license'] as String,
      sourcePrefixTokens: manifestVersion >= 3
          ? (json['sourcePrefixTokens'] as List).cast<String>()
          : (json['sourcePrefix'] as String? ?? '')
                .trim()
                .split(RegExp(r'\s+'))
                .where((token) => token.isNotEmpty)
                .toList(),
      sourceEosToken: manifestVersion == 1
          ? '</s>'
          : json['sourceEosToken'] as String,
      targetPrefixTokens: manifestVersion >= 4
          ? (json['targetPrefixTokens'] as List).cast<String>()
          : const [],
      beamSize: manifestVersion >= 4 ? json['beamSize'] as int : 2,
      promptTemplate: manifestVersion >= 5
          ? json['promptTemplate'] as String? ?? ''
          : '',
      contextSize: manifestVersion >= 5 ? json['contextSize'] as int? ?? 0 : 0,
      maxOutputTokens: manifestVersion >= 5
          ? json['maxOutputTokens'] as int? ?? 0
          : 0,
      sourceUrl: json['sourceUrl'] as String? ?? '',
      files: files,
      path: path,
    );
    model._validateManifest();
    return model;
  }

  String filePath(String name) => '$path${Platform.pathSeparator}$name';

  String get sourceLanguage => sourceLanguages.join('/');

  String get runtimeKey {
    final entries = files.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final fingerprint = sha256.convert(
      utf8.encode(
        jsonEncode({
          'schema': schemaVersion,
          'engine': engine,
          'prefixTokens': sourcePrefixTokens,
          'eos': sourceEosToken,
          'targetPrefixTokens': targetPrefixTokens,
          'beamSize': beamSize,
          'promptTemplate': promptTemplate,
          'contextSize': contextSize,
          'maxOutputTokens': maxOutputTokens,
          'files': {for (final entry in entries) entry.key: entry.value},
        }),
      ),
    );
    return '$id:$version:$fingerprint';
  }

  Map<String, dynamic> toManifest() => {
    'schemaVersion': schemaVersion,
    'engine': engine,
    'id': id,
    'version': version,
    'displayName': displayName,
    'sourceLanguages': sourceLanguages,
    'targetLanguage': targetLanguage,
    'license': license,
    'sourcePrefixTokens': sourcePrefixTokens,
    'sourceEosToken': sourceEosToken,
    'targetPrefixTokens': targetPrefixTokens,
    'beamSize': beamSize,
    'promptTemplate': promptTemplate,
    'contextSize': contextSize,
    'maxOutputTokens': maxOutputTokens,
    'sourceUrl': sourceUrl,
    'files': files,
  };

  void _validateManifest() {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(id) ||
        id.isEmpty ||
        version.isEmpty ||
        displayName.isEmpty ||
        license.isEmpty ||
        sourceLanguages.isEmpty ||
        engine == ctranslate2Engine &&
            (sourceEosToken.isEmpty || beamSize < 1 || beamSize > 16) ||
        engine == hyMtGgufEngine &&
            (!promptTemplate.contains('{text}') ||
                contextSize < 256 ||
                maxOutputTokens < 1 ||
                maxOutputTokens >= contextSize)) {
      throw const FormatException('Invalid local translation model metadata');
    }
    final required = engine == hyMtGgufEngine
        ? const {'model.gguf'}
        : const {'model.bin', 'config.json', 'source.spm', 'target.spm'};
    if (!files.keys.toSet().containsAll(required)) {
      throw const FormatException('Local translation model is incomplete');
    }
    final shared = files.containsKey('shared_vocabulary.json');
    final separate =
        files.containsKey('source_vocabulary.json') &&
        files.containsKey('target_vocabulary.json');
    if (engine == ctranslate2Engine && !shared && !separate) {
      throw const FormatException('Local translation vocabulary is missing');
    }
    for (final entry in files.entries) {
      if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(entry.key) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value)) {
        throw const FormatException('Invalid local translation model file');
      }
    }
  }

  static String _language(String value) {
    final language = value.trim().replaceAll('_', '-').toLowerCase();
    if (language.isEmpty || language == 'auto' || language == 'system') {
      throw const FormatException('Local model language must be explicit');
    }
    return language;
  }
}

const hyMt15TwoBitModel = (
  id: 'hy-mt1.5-1.8b-2bit',
  version: 'ef3a410f443c',
  displayName: 'Hy-MT1.5-1.8B 2-bit',
  fileName: 'model.gguf',
  bytes: 600535360,
  sha256: '46e587d917fc4f6f5bda602f10c4a53da8840240355824bcc0e227559c9cba3e',
  url:
      'https://huggingface.co/AngelSlim/Hy-MT1.5-1.8B-2bit-GGUF/resolve/'
      'ef3a410f443c23a155e563814defc5a933a3a35c/'
      'Hy-MT1.5-1.8B-2bit.gguf',
  sourceUrl:
      'https://huggingface.co/AngelSlim/Hy-MT1.5-1.8B-2bit-GGUF/'
      'tree/ef3a410f443c23a155e563814defc5a933a3a35c',
);

enum ComicLocalModelPhase { idle, downloading, copying, verifying }

final class ComicLocalModelProgress {
  final ComicLocalModelPhase phase;
  final String? fileName;
  final int completedFiles;
  final int totalFiles;
  final int receivedBytes;
  final int totalBytes;

  const ComicLocalModelProgress({
    this.phase = ComicLocalModelPhase.idle,
    this.fileName,
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
  });

  double get fraction => totalBytes > 0
      ? receivedBytes / totalBytes
      : totalFiles == 0
      ? 0
      : completedFiles / totalFiles;
}

final class ComicLocalTranslationModelManager {
  ComicLocalTranslationModelManager._();

  static final instance = ComicLocalTranslationModelManager._();

  final progress = ValueNotifier(const ComicLocalModelProgress());
  late final Directory _root;
  List<ComicLocalTranslationModel> _models = const [];
  Future<ComicLocalTranslationModel>? _installing;

  List<ComicLocalTranslationModel> get models => List.unmodifiable(_models);
  bool get installing => _installing != null;

  Future<void> init(String dataPath) async {
    _root = Directory(
      '$dataPath${Platform.pathSeparator}comic_translation'
      '${Platform.pathSeparator}models${Platform.pathSeparator}translation',
    );
    await _root.create(recursive: true);
    await _recoverInterruptedInstall();
    await _scan();
  }

  Future<void> _recoverInterruptedInstall() async {
    await for (final entry in _root.list()) {
      if (entry is! Directory) continue;
      if (entry.path.endsWith('.installing')) {
        if (entry.path ==
            '${_root.path}${Platform.pathSeparator}'
                '.${hyMt15TwoBitModel.id}-${hyMt15TwoBitModel.version}.installing') {
          final model = File(
            '${entry.path}${Platform.pathSeparator}'
            '${hyMt15TwoBitModel.fileName}',
          );
          if (await model.exists()) {
            final downloads = Directory(
              '${_root.path}${Platform.pathSeparator}.downloads',
            );
            await downloads.create(recursive: true);
            final partial = File(
              '${downloads.path}${Platform.pathSeparator}'
              '${hyMt15TwoBitModel.id}-${hyMt15TwoBitModel.version}.part',
            );
            if (await partial.exists()) await partial.delete();
            await model.rename(partial.path);
          }
        }
        await entry.delete(recursive: true);
      } else if (entry.path.endsWith('.old')) {
        final target = Directory(
          entry.path.substring(0, entry.path.length - '.old'.length),
        );
        if (await target.exists()) {
          await entry.delete(recursive: true);
        } else {
          await entry.rename(target.path);
        }
      }
    }
  }

  ComicLocalTranslationModel? modelById(String id) =>
      _models.where((model) => model.id == id).firstOrNull;

  ComicLocalTranslationModel? modelFor(String source, String target) {
    final normalizedSource = _normalizeSource(source);
    final normalizedTarget = _normalizeTarget(target);
    return _models
        .where(
          (model) =>
              model.sourceLanguages.contains(normalizedSource) &&
              model.targetLanguage == normalizedTarget,
        )
        .firstOrNull;
  }

  List<ComicLocalTranslationModel>? pipelineFor(
    String source,
    String target, {
    String modelId = '',
  }) {
    if (modelId.isNotEmpty) {
      final model = modelById(modelId);
      if (model == null ||
          !model.sourceLanguages.contains(_normalizeSource(source))) {
        return null;
      }
      final normalizedTarget = _normalizeTarget(target);
      if (model.targetLanguage == normalizedTarget) return [model];
      if (model.targetLanguage != 'en') return null;
      final second = modelFor('en', normalizedTarget);
      return second == null ? null : [model, second];
    }
    final direct = modelFor(source, target);
    if (direct != null) return [direct];
    final first = modelFor(source, 'en');
    final second = modelFor('en', target);
    return first == null || second == null ? null : [first, second];
  }

  Future<ComicLocalTranslationModel> installFromDirectory(String sourcePath) {
    final task = _installing;
    if (task != null)
      throw StateError('Local model installation is in progress');
    final future = _install(sourcePath).whenComplete(() {
      _installing = null;
      progress.value = const ComicLocalModelProgress();
    });
    _installing = future;
    return future;
  }

  Future<ComicLocalTranslationModel> installHyMt15TwoBit() {
    final task = _installing;
    if (task != null)
      throw StateError('Local model installation is in progress');
    final future = _installHyMt15TwoBit().whenComplete(() {
      _installing = null;
      progress.value = const ComicLocalModelProgress();
    });
    _installing = future;
    return future;
  }

  Future<ComicLocalTranslationModel> _installHyMt15TwoBit() async {
    final downloadDirectory = Directory(
      '${_root.path}${Platform.pathSeparator}.downloads',
    );
    await downloadDirectory.create(recursive: true);
    final partial = File(
      '${downloadDirectory.path}${Platform.pathSeparator}'
      '${hyMt15TwoBitModel.id}-${hyMt15TwoBitModel.version}.part',
    );
    final completeLength =
        await partial.exists() &&
        await partial.length() == hyMt15TwoBitModel.bytes;
    if (completeLength) {
      progress.value = ComicLocalModelProgress(
        phase: ComicLocalModelPhase.verifying,
        fileName: hyMt15TwoBitModel.fileName,
        receivedBytes: hyMt15TwoBitModel.bytes,
        totalBytes: hyMt15TwoBitModel.bytes,
      );
    }
    if (!await _verifiedFile(
      partial,
      hyMt15TwoBitModel.bytes,
      hyMt15TwoBitModel.sha256,
    )) {
      if (await partial.exists() &&
          await partial.length() == hyMt15TwoBitModel.bytes) {
        await partial.writeAsBytes(const []);
      }
      await _downloadHyMt(partial);
      progress.value = ComicLocalModelProgress(
        phase: ComicLocalModelPhase.verifying,
        fileName: hyMt15TwoBitModel.fileName,
        receivedBytes: hyMt15TwoBitModel.bytes,
        totalBytes: hyMt15TwoBitModel.bytes,
      );
      if (!await _verifiedFile(
        partial,
        hyMt15TwoBitModel.bytes,
        hyMt15TwoBitModel.sha256,
      )) {
        await partial.writeAsBytes(const []);
        throw StateError('SHA-256 mismatch: ${hyMt15TwoBitModel.fileName}');
      }
    }
    final manifest = <String, dynamic>{
      'schemaVersion': ComicLocalTranslationModel.schemaVersion,
      'engine': ComicLocalTranslationModel.hyMtGgufEngine,
      'id': hyMt15TwoBitModel.id,
      'version': hyMt15TwoBitModel.version,
      'displayName': hyMt15TwoBitModel.displayName,
      'sourceLanguages': const ['ja', 'ko'],
      'targetLanguage': 'zh-CN',
      'license': 'Tencent Hunyuan Community License',
      'sourcePrefixTokens': const <String>[],
      'sourceEosToken': '',
      'targetPrefixTokens': const <String>[],
      'beamSize': 1,
      'promptTemplate':
          '将以下文本翻译为{target_language}，'
          '注意只需要输出翻译后的结果，不要额外解释：\n\n{text}',
      'contextSize': 1024,
      'maxOutputTokens': 64,
      'sourceUrl': hyMt15TwoBitModel.sourceUrl,
      'files': {hyMt15TwoBitModel.fileName: hyMt15TwoBitModel.sha256},
    };
    final staging = Directory(
      '${_root.path}${Platform.pathSeparator}.${hyMt15TwoBitModel.id}-'
      '${hyMt15TwoBitModel.version}.installing',
    );
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    await partial.rename(
      '${staging.path}${Platform.pathSeparator}${hyMt15TwoBitModel.fileName}',
    );
    final staged = ComicLocalTranslationModel.fromManifest(
      manifest,
      staging.path,
    );
    await File(
      '${staging.path}${Platform.pathSeparator}installation.json',
    ).writeAsString(jsonEncode(staged.toManifest()), flush: true);
    await _promote(staging, staged.id);
    return _models.firstWhere((model) => model.id == staged.id);
  }

  Future<void> _downloadHyMt(File partial) async {
    var offset = await partial.exists() ? await partial.length() : 0;
    if (offset > hyMt15TwoBitModel.bytes) {
      await partial.writeAsBytes(const []);
      offset = 0;
    }
    if (offset == hyMt15TwoBitModel.bytes) return;
    final client = Dio()..httpClientAdapter = RHttpAdapter();
    try {
      final response = await client.get<ResponseBody>(
        hyMt15TwoBitModel.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {if (offset > 0) 'Range': 'bytes=$offset-'},
        ),
      );
      final append =
          offset > 0 && response.statusCode == HttpStatus.partialContent;
      if (offset > 0 && !append) offset = 0;
      if (append) {
        final range = response.headers.value('content-range');
        if (range == null || !range.startsWith('bytes $offset-')) {
          throw StateError('Invalid Content-Range for Hy-MT: $range');
        }
      }
      final output = await partial.open(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = offset;
      final publishTimer = Stopwatch()..start();
      progress.value = ComicLocalModelProgress(
        phase: ComicLocalModelPhase.downloading,
        fileName: hyMt15TwoBitModel.fileName,
        receivedBytes: received,
        totalBytes: hyMt15TwoBitModel.bytes,
      );
      try {
        await for (final chunk in response.data!.stream) {
          await output.writeFrom(chunk);
          received += chunk.length;
          if (publishTimer.elapsedMilliseconds >= 500 ||
              received == hyMt15TwoBitModel.bytes) {
            publishTimer.reset();
            progress.value = ComicLocalModelProgress(
              phase: ComicLocalModelPhase.downloading,
              fileName: hyMt15TwoBitModel.fileName,
              receivedBytes: received,
              totalBytes: hyMt15TwoBitModel.bytes,
            );
          }
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (received != hyMt15TwoBitModel.bytes) {
        throw StateError(
          'Model length mismatch: $received/${hyMt15TwoBitModel.bytes}',
        );
      }
    } finally {
      client.close();
    }
  }

  Future<bool> _verifiedFile(File file, int bytes, String expected) async {
    if (!await file.exists() || await file.length() != bytes) return false;
    final path = file.path;
    final digest = await Isolate.run(
      () async => (await sha256.bind(File(path).openRead()).first).toString(),
    );
    return digest == expected;
  }

  Future<ComicLocalTranslationModel> _install(String sourcePath) async {
    final source = Directory(sourcePath);
    final manifestFile = File(
      '${source.path}${Platform.pathSeparator}manifest.json',
    );
    if (!await manifestFile.exists()) {
      throw const FormatException('Local model manifest.json is missing');
    }
    final manifest = Map<String, dynamic>.from(
      jsonDecode(await manifestFile.readAsString()) as Map,
    );
    final parsed = ComicLocalTranslationModel.fromManifest(
      manifest,
      source.path,
    );
    final staging = Directory(
      '${_root.path}${Platform.pathSeparator}.${parsed.id}.installing',
    );
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    var completed = 0;
    for (final entry in parsed.files.entries) {
      progress.value = ComicLocalModelProgress(
        phase: ComicLocalModelPhase.copying,
        fileName: entry.key,
        completedFiles: completed,
        totalFiles: parsed.files.length,
      );
      final input = File(parsed.filePath(entry.key));
      if (!await input.exists()) {
        throw FormatException('Local model file is missing: ${entry.key}');
      }
      await input.copy('${staging.path}${Platform.pathSeparator}${entry.key}');
      completed++;
    }
    final staged = ComicLocalTranslationModel.fromManifest(
      manifest,
      staging.path,
    );
    await _verify(staged);
    await File(
      '${staging.path}${Platform.pathSeparator}installation.json',
    ).writeAsString(jsonEncode(staged.toManifest()), flush: true);
    await _promote(staging, parsed.id);
    return _models.firstWhere((model) => model.id == parsed.id);
  }

  Future<void> _promote(Directory staging, String id) async {
    final target = Directory('${_root.path}${Platform.pathSeparator}$id');
    final backup = Directory('${target.path}.old');
    if (await backup.exists()) await backup.delete(recursive: true);
    if (await target.exists()) await target.rename(backup.path);
    try {
      await staging.rename(target.path);
    } catch (_) {
      if (await backup.exists()) await backup.rename(target.path);
      rethrow;
    }
    if (await backup.exists()) await backup.delete(recursive: true);
    await _scan();
  }

  Future<void> _verify(ComicLocalTranslationModel model) async {
    var completed = 0;
    for (final entry in model.files.entries) {
      progress.value = ComicLocalModelProgress(
        phase: ComicLocalModelPhase.verifying,
        fileName: entry.key,
        completedFiles: completed,
        totalFiles: model.files.length,
      );
      final path = model.filePath(entry.key);
      final digest = await Isolate.run(
        () async => (await sha256.bind(File(path).openRead()).first).toString(),
      );
      if (digest != entry.value) {
        throw StateError('SHA-256 mismatch: ${entry.key}');
      }
      completed++;
    }
  }

  Future<void> remove(String id) async {
    if (_installing != null) {
      throw StateError('Local model installation is in progress');
    }
    final model = _models.firstWhere((model) => model.id == id);
    await Directory(model.path).delete(recursive: true);
    await _scan();
  }

  Future<void> _scan() async {
    final models = <ComicLocalTranslationModel>[];
    await for (final entry in _root.list()) {
      if (entry is! Directory ||
          entry.path.endsWith('.old') ||
          entry.path.endsWith('.installing')) {
        continue;
      }
      final manifest = File(
        '${entry.path}${Platform.pathSeparator}installation.json',
      );
      if (!await manifest.exists()) {
        continue;
      }
      final json = Map<String, dynamic>.from(
        jsonDecode(await manifest.readAsString()) as Map,
      );
      final model = ComicLocalTranslationModel.fromManifest(json, entry.path);
      if (model.id == hyMt15TwoBitModel.id &&
          (model.version != hyMt15TwoBitModel.version ||
              model.files[hyMt15TwoBitModel.fileName] !=
                  hyMt15TwoBitModel.sha256)) {
        continue;
      }
      if (json['schemaVersion'] != ComicLocalTranslationModel.schemaVersion) {
        await manifest.writeAsString(
          jsonEncode(model.toManifest()),
          flush: true,
        );
      }
      for (final name in model.files.keys) {
        if (!await File(model.filePath(name)).exists()) {
          throw StateError('Installed local model is incomplete: ${model.id}');
        }
      }
      models.add(model);
    }
    models.sort((a, b) => a.displayName.compareTo(b.displayName));
    _models = List.unmodifiable(models);
  }

  static String _normalizeSource(String language) =>
      language.trim().replaceAll('_', '-').toLowerCase().split('-').first;

  static String _normalizeTarget(String language) {
    final value = language.trim().replaceAll('_', '-').toLowerCase();
    return value == 'zh-tw' || value == 'zh-hk' || value == 'zh-hant'
        ? 'zh-cn'
        : value;
  }
}
