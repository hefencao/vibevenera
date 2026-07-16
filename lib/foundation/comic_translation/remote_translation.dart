import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/network/app_dio.dart';

import 'engine.dart';

final class OpenAiCompatibleComicTranslationEngine
    implements ComicTextTranslationEngine {
  final String endpoint;
  final String model;
  final String apiKey;
  final String additionalPrompt;
  Dio? _client;

  OpenAiCompatibleComicTranslationEngine({
    required this.endpoint,
    required this.model,
    required this.apiKey,
    this.additionalPrompt = '',
  });

  @override
  String get id => 'openai-compatible:${sha256.convert(utf8.encode(endpoint))}';

  @override
  String get modelVersion => '$model:bubble-unit-lines-v3:'
      '${sha256.convert(utf8.encode(additionalPrompt.trim()))}';

  @override
  Future<void> load() async => _client ??= _createClient();

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    if (model.trim().isEmpty) throw StateError('Remote translation model is empty');
    if (request.units.isEmpty) return const ComicTranslationResult({});
    final preference = additionalPrompt.trim();
    final systemPrompt = [
      'Translate comic text ${request.ocr.sourceLanguage == 'auto' ? '' : 'from ${request.ocr.sourceLanguage} '}into ${request.targetLanguage}.',
      'Use prior pages only as context. Preserve names and tone.',
      'Use natural target-language writing without romanization and keep each unit concise.',
      'Each unit is one complete translation target. Its sourceLines are ordered OCR rows or columns from the same speech balloon.',
      'Translate all sourceLines jointly as one coherent utterance, then split the translation back into the same number of ordered strings.',
      'Each output string must correspond one-to-one with the regionId and sourceLine at the same index; never repeat the complete translation in every string.',
      if (preference.isNotEmpty)
        'Additional translation preference: $preference The additional preference must not change unit boundaries or the output protocol.',
      'Return one JSON object: {"translations":{"unitId":["region text", "region text"]}}.',
      'A multi-line unit must use an array with exactly sourceLines.length non-empty strings. A single-line unit may use one string or a one-item array.',
      'Every input unitId must appear exactly once.',
    ].join(' ');
    final client = _client ?? _createClient();
    final temporaryClient = _client == null;
    late Response<dynamic> response;
    try {
      response = await client.post<dynamic>(
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
                'units': request.units.map((unit) => {
                  'id': unit.id,
                  'regionIds': unit.regionIds,
                  'sourceLines': unit.sourceLines,
                }).toList(),
              }),
            },
          ],
        },
      );
    } finally {
      if (temporaryClient) client.close();
    }
    final rawData = response.data!;
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
    return ComicTranslationResult(
      values.map((key, value) {
        final unit = request.units.singleWhere((unit) => unit.id == key);
        if (value is String) {
          if (unit.regionIds.length != 1) {
            throw FormatException(
              'Translation unit $key must contain ${unit.regionIds.length} lines',
            );
          }
          return MapEntry(key, [value]);
        }
        return MapEntry(key, List<String>.from(value as List));
      }),
    );
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
