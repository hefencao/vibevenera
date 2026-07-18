import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:venera/network/app_dio.dart';

import 'engine.dart';
import 'models.dart';

final class OpenAiCompatibleComicTranslationEngine
    implements ComicTextTranslationEngine, ComicTextTranslationEngineDiagnostics {
  static const _maxBatchUnits = 16;
  static const _maxBatchCharacters = 960;
  static const _batchConcurrency = 2;

  final String endpoint;
  final String model;
  final String apiKey;
  final String additionalPrompt;
  Dio? _client;
  ComicTextTranslationRunMetrics? _lastRunMetrics;
  List<String> _lastRawResponses = const [];

  OpenAiCompatibleComicTranslationEngine({
    required this.endpoint,
    required this.model,
    required this.apiKey,
    this.additionalPrompt = '',
  });

  @override
  String get id => 'openai-compatible:${sha256.convert(utf8.encode(endpoint))}';

  @override
  String get modelVersion => '$model:bubble-unit-lines-v22:'
      '${sha256.convert(utf8.encode(additionalPrompt.trim()))}';

  @override
  ComicTextTranslationRunMetrics? get lastRunMetrics => _lastRunMetrics;

  @override
  List<String> get lastRawResponses => _lastRawResponses;

  @override
  Future<void> load() async => _client ??= _createClient();

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    _lastRunMetrics = null;
    _lastRawResponses = const [];
    if (model.trim().isEmpty) throw StateError('Remote translation model is empty');
    if (request.units.isEmpty) return const ComicTranslationResult({});
    final batches = _buildBatches(request.units);
    final results = List<Map<String, List<String>>?>.filled(batches.length, null);
    final durations = List<Duration>.filled(batches.length, Duration.zero);
    final rawResponses = List<String>.filled(batches.length, '');
    _lastRawResponses = rawResponses;
    final total = Stopwatch()..start();
    final client = _client ?? _createClient();
    final temporaryClient = _client == null;
    var nextBatch = 0;
    Future<void> worker() async {
      while (nextBatch < batches.length) {
        final index = nextBatch++;
        final timer = Stopwatch()..start();
        results[index] = await _translateBatch(
          request,
          batches[index],
          client,
          (value) => rawResponses[index] = value,
        );
        durations[index] = timer.elapsed;
      }
    }
    try {
      await Future.wait(List.generate(
        math.min(_batchConcurrency, batches.length),
        (_) => worker(),
      ));
    } finally {
      if (temporaryClient) client.close();
    }
    final translations = <String, List<String>>{};
    for (final result in results) {
      translations.addAll(result!);
    }
    _lastRunMetrics = ComicTextTranslationRunMetrics(
      elapsed: total.elapsed,
      batchDurations: durations,
      unitCount: request.units.length,
      sourceCharacters: request.units.fold(
        0,
        (sum, unit) => sum + unit.sourceLines.fold(0, (a, b) => a + b.runes.length),
      ),
    );
    return ComicTranslationResult(translations);
  }

  List<List<ComicTranslationUnit>> _buildBatches(
    List<ComicTranslationUnit> units,
  ) {
    final batches = <List<ComicTranslationUnit>>[];
    var batch = <ComicTranslationUnit>[];
    var characters = 0;
    for (final unit in units) {
      final unitCharacters =
          unit.sourceLines.fold(0, (sum, line) => sum + line.runes.length);
      if (batch.isNotEmpty &&
          (batch.length == _maxBatchUnits ||
              characters + unitCharacters > _maxBatchCharacters)) {
        batches.add(batch);
        batch = [];
        characters = 0;
      }
      batch.add(unit);
      characters += unitCharacters;
    }
    if (batch.isNotEmpty) batches.add(batch);
    return batches;
  }

  Future<Map<String, List<String>>> _translateBatch(
    ComicTranslationRequest request,
    List<ComicTranslationUnit> units,
    Dio client,
    void Function(String value) onResponse,
  ) async {
    final preference = additionalPrompt.trim();
    final systemPrompt = [
      'Translate comic OCR ${request.ocr.sourceLanguage == 'auto' ? '' : 'from ${request.ocr.sourceLanguage} '}to ${request.targetLanguage}; use prior pages only as context and preserve names and tone.',
      'Each unit is one balloon. Translate its ordered sourceLines jointly, then return one concise natural string per regionId in the same order without romanization or repeated full translations.',
      'Preserve source punctuation and ellipses exactly. Where the translation needs an additional sentence or clause break absent from sourceLines, use only $comicTranslationBreakMarker as the separator and do not add ordinary punctuation.',
      if (preference.isNotEmpty)
        'Preference: $preference Do not change unit boundaries or output format.',
      'Return JSON only: {"translations":{"unitId":["text per region"]}}. Include every unitId exactly once; arrays must contain exactly sourceLines.length non-empty strings. A one-line unit may use one string.',
    ].join(' ');
    final response = await client.post<dynamic>(
      endpoint,
      data: {
          'model': model,
          'temperature': 0,
          'response_format': {'type': 'json_object'},
          'messages': [
            {
              'role': 'system',
              'content': systemPrompt,
            },
            {
              'role': 'user',
              'content': jsonEncode({
                'previousPages': request.previousPages.map((page) => {
                  'page': page.pageIndex,
                  'source': page.sourceTexts,
                  'translation': page.translatedTexts,
                }).toList(),
                'glossary': request.glossary,
                'units': units.map((unit) => {
                  'id': unit.id,
                  'regionIds': unit.regionIds,
                  'sourceLines': unit.sourceLines,
                }).toList(),
              }),
            },
          ],
        },
    );
    final rawData = response.data!;
    onResponse(rawData is String
        ? rawData
        : const JsonEncoder.withIndent('  ').convert(rawData));
    final data = rawData is String
        ? decodeComicTranslationJson(rawData)
        : Map<String, dynamic>.from(rawData as Map);
    final choices = data['choices'] as List;
    final message = Map<String, dynamic>.from(
      (choices.first as Map)['message'] as Map,
    );
    final payload = decodeComicTranslationJson(message['content'] as String);
    final values = Map<String, dynamic>.from(
      payload['translations'] as Map,
    );
    return values.map((key, value) {
        final unit = units.singleWhere((unit) => unit.id == key);
        if (value is String) {
          if (unit.regionIds.length != 1) {
            throw FormatException(
              'Translation unit $key must contain ${unit.regionIds.length} lines',
            );
          }
          return MapEntry(key, [value]);
        }
        return MapEntry(key, List<String>.from(value as List));
      });
  }

  @override
  Future<void> unload() async {
    _client?.close();
    _client = null;
  }

  Dio _createClient() => Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    headers: {
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    },
  ))..httpClientAdapter = RHttpAdapter();
}

Map<String, dynamic> decodeComicTranslationJson(String value) {
  final start = value.indexOf('{');
  if (start < 0) throw const FormatException('Translation response has no JSON object');
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var index = start; index < value.length; index++) {
    final code = value.codeUnitAt(index);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code == 0x5c) {
        escaped = true;
      } else if (code == 0x22) {
        inString = false;
      }
      continue;
    }
    if (code == 0x22) {
      inString = true;
    } else if (code == 0x7b) {
      depth++;
    } else if (code == 0x7d && --depth == 0) {
      return Map<String, dynamic>.from(
        jsonDecode(value.substring(start, index + 1)) as Map,
      );
    }
  }
  throw const FormatException('Translation response has incomplete JSON object');
}
