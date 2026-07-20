import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:venera/utils/opencc.dart';

import 'engine.dart';
import 'local_model_manager.dart';

final class LocalCTranslate2ComicTranslationEngine
    implements ComicTextTranslationEngine, ComicTextTranslationEngineDiagnostics {
  static const _channel = MethodChannel('venera/comic_translation_local');

  final ComicLocalTranslationModelManager models;
  final _loadedModels = <String>{};
  ComicTextTranslationRunMetrics? _lastRunMetrics;
  List<String> _lastRawResponses = const [];

  LocalCTranslate2ComicTranslationEngine(this.models);

  static Future<bool> isNativeAvailable() async =>
      Platform.isAndroid &&
      await _channel.invokeMethod<bool>('isAvailable') == true;

  @override
  ComicTranslationContextMode get contextMode => ComicTranslationContextMode.none;

  @override
  ComicTranslationEngineIdentity identityFor(
    ComicTranslationRequest request,
  ) {
    final pipeline = _pipelineFor(request);
    return ComicTranslationEngineIdentity(
      id: 'local-ctranslate2:${pipeline.map((model) => model.id).join('+')}',
      modelVersion: '${pipeline.map((model) => model.runtimeKey).join('>')}:'
          'package-v${ComicLocalTranslationModel.schemaVersion}:'
          'group-seq2seq-protocol-v3',
    );
  }

  @override
  ComicTextTranslationRunMetrics? get lastRunMetrics => _lastRunMetrics;

  @override
  List<String> get lastRawResponses => _lastRawResponses;

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
    _lastRawResponses = const [];
    if (request.units.isEmpty) return const ComicTranslationResult({});
    final pipeline = _pipelineFor(request);
    final timer = Stopwatch()..start();
    var texts = request.units
        .map((unit) => unit.sourceLines.join('\n'))
        .toList(growable: false);
    final sourceCharacters = texts.fold(
      0,
      (sum, text) => sum + text.runes.length,
    );
    final batchDurations = <Duration>[];
    for (final model in pipeline) {
      await _loadModel(model);
      final stageTimer = Stopwatch()..start();
      final raw = await _channel.invokeListMethod<String>('translate', {
        'modelKey': model.runtimeKey,
        'texts': texts,
      });
      stageTimer.stop();
      batchDurations.add(stageTimer.elapsed);
      if (raw == null || raw.length != request.units.length) {
        throw StateError(
          'Local translator returned ${raw?.length} results for '
          '${request.units.length} units',
        );
      }
      _lastRawResponses = [
        ..._lastRawResponses,
        '${model.displayName} (${model.sourceLanguage} → ${model.targetLanguage})\n'
            '${List.generate(request.units.length, (i) => '${request.units[i].id}: ${texts[i].replaceAll('\n', ' | ')} → ${raw[i]}').join('\n')}',
      ];
      texts = raw.map((text) => text.trim()).toList(growable: false);
      final empty = texts.indexWhere((text) => text.isEmpty);
      if (empty >= 0) {
        throw StateError('Local translation unit ${request.units[empty].id} is empty');
      }
    }
    timer.stop();
    final traditional = _isTraditionalTarget(request.targetLanguage);
    final translations = <String, List<String>>{};
    for (var i = 0; i < request.units.length; i++) {
      translations[request.units[i].id] = [
        traditional
            ? OpenCC.simplifiedToTraditional(
                OpenCC.traditionalToSimplified(texts[i]),
              )
            : OpenCC.traditionalToSimplified(texts[i]),
      ];
    }
    _lastRunMetrics = ComicTextTranslationRunMetrics(
      elapsed: timer.elapsed,
      batchDurations: batchDurations,
      unitCount: request.units.length,
      sourceCharacters: sourceCharacters,
    );
    return ComicTranslationResult(translations);
  }

  Future<void> _loadModel(ComicLocalTranslationModel model) async {
    if (_loadedModels.contains(model.runtimeKey)) return;
    await _channel.invokeMethod<void>('load', {
      'modelKey': model.runtimeKey,
      'modelPath': model.path,
      'sourceSpm': model.filePath('source.spm'),
      'targetSpm': model.filePath('target.spm'),
      'sourcePrefixTokens': model.sourcePrefixTokens,
      'sourceEosToken': model.sourceEosToken,
      'targetPrefixTokens': model.targetPrefixTokens,
      'beamSize': model.beamSize,
      'threads': math.min(4, math.max(1, Platform.numberOfProcessors ~/ 2)),
    });
    _loadedModels.add(model.runtimeKey);
  }

  List<ComicLocalTranslationModel> _pipelineFor(
    ComicTranslationRequest request,
  ) {
    final source = _sourceLanguage(request);
    final pipeline = models.pipelineFor(source, request.targetLanguage);
    if (pipeline == null) {
      throw StateError(
        'No local translation pipeline for $source → ${request.targetLanguage}',
      );
    }
    return pipeline;
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
    if (han > 0 && models.pipelineFor('ja', request.targetLanguage) != null) {
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
    if (_loadedModels.isEmpty) return;
    await _channel.invokeMethod<void>('unload');
    _loadedModels.clear();
  }
}
