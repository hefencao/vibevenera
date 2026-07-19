import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:venera/utils/opencc.dart';

import 'engine.dart';
import 'local_model_manager.dart';

final class LocalMarianComicTranslationEngine
    implements ComicTextTranslationEngine, ComicTextTranslationEngineDiagnostics {
  static const _channel = MethodChannel('venera/comic_translation_local');

  final ComicLocalTranslationModelManager models;
  String? _loadedModel;
  ComicTextTranslationRunMetrics? _lastRunMetrics;

  LocalMarianComicTranslationEngine(this.models);

  static Future<bool> isNativeAvailable() async =>
      Platform.isAndroid &&
      await _channel.invokeMethod<bool>('isAvailable') == true;

  @override
  ComicTranslationContextMode get contextMode => ComicTranslationContextMode.none;

  @override
  ComicTranslationEngineIdentity identityFor(
    ComicTranslationRequest request,
  ) {
    final model = _modelFor(request);
    return ComicTranslationEngineIdentity(
      id: 'local-ctranslate2:${model.id}',
      modelVersion: '${model.version}:pair=${model.sourceLanguage}'
          '-${model.targetLanguage}:package-v1',
    );
  }

  @override
  ComicTextTranslationRunMetrics? get lastRunMetrics => _lastRunMetrics;

  @override
  List<String> get lastRawResponses => const [];

  @override
  Future<void> load() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Local translation is currently Android-only');
    }
    if (!await isNativeAvailable()) {
      throw StateError('CTranslate2 native runtime is not included in this build');
    }
  }

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    _lastRunMetrics = null;
    if (request.units.isEmpty) return const ComicTranslationResult({});
    final model = _modelFor(request);
    final timer = Stopwatch()..start();
    await _loadModel(model);
    final texts = request.units
        .map((unit) => unit.sourceLines.join('\n'))
        .toList(growable: false);
    final raw = await _channel.invokeListMethod<String>('translate', {
      'texts': texts,
    });
    timer.stop();
    if (raw == null || raw.length != request.units.length) {
      throw StateError(
        'Local translator returned ${raw?.length} results for '
        '${request.units.length} units',
      );
    }
    final traditional = _isTraditionalTarget(request.targetLanguage);
    final translations = <String, List<String>>{};
    for (var i = 0; i < request.units.length; i++) {
      final text = raw[i].trim();
      if (text.isEmpty) {
        throw StateError('Local translation unit ${request.units[i].id} is empty');
      }
      translations[request.units[i].id] = [
        traditional ? OpenCC.simplifiedToTraditional(text) : text,
      ];
    }
    _lastRunMetrics = ComicTextTranslationRunMetrics(
      elapsed: timer.elapsed,
      batchDurations: [timer.elapsed],
      unitCount: request.units.length,
      sourceCharacters: texts.fold(0, (sum, text) => sum + text.runes.length),
    );
    return ComicTranslationResult(translations);
  }

  Future<void> _loadModel(ComicLocalTranslationModel model) async {
    final identity = '${model.id}:${model.version}';
    if (_loadedModel == identity) return;
    await _channel.invokeMethod<void>('load', {
      'modelPath': model.path,
      'sourceSpm': model.filePath('source.spm'),
      'targetSpm': model.filePath('target.spm'),
      'threads': math.min(4, math.max(1, Platform.numberOfProcessors ~/ 2)),
    });
    _loadedModel = identity;
  }

  ComicLocalTranslationModel _modelFor(ComicTranslationRequest request) {
    final source = _sourceLanguage(request);
    final model = models.modelFor(source, request.targetLanguage);
    if (model == null) {
      throw StateError(
        'No local translation model for $source → ${request.targetLanguage}',
      );
    }
    return model;
  }

  String _sourceLanguage(ComicTranslationRequest request) {
    final configured = request.ocr.sourceLanguage
        .trim().replaceAll('_', '-').toLowerCase().split('-').first;
    if (configured != 'auto') return configured;
    var hangul = 0;
    var japanese = 0;
    var han = 0;
    for (final rune in request.ocr.regions.expand((region) => region.text.runes)) {
      if (rune >= 0xac00 && rune <= 0xd7af) hangul++;
      if (rune >= 0x3040 && rune <= 0x30ff) japanese++;
      if (rune >= 0x3400 && rune <= 0x9fff) han++;
    }
    if (hangul > japanese) return 'ko';
    if (japanese > 0) return 'ja';
    if (han > 0 && models.modelFor('ja', request.targetLanguage) != null) {
      return 'ja';
    }
    throw StateError('Local translation cannot infer the source language');
  }

  bool _isTraditionalTarget(String language) {
    final value = language.trim().replaceAll('_', '-').toLowerCase();
    return value == 'zh-tw' || value == 'zh-hk' || value == 'zh-hant';
  }

  @override
  Future<void> unload() async {
    if (_loadedModel == null) return;
    await _channel.invokeMethod<void>('unload');
    _loadedModel = null;
  }
}
