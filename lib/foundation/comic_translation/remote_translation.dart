import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/network/app_dio.dart';

import 'engine.dart';

final class OpenAiCompatibleComicTranslationEngine
    implements ComicTextTranslationEngine {
  final String endpoint;
  final String model;
  final String apiKey;

  const OpenAiCompatibleComicTranslationEngine({
    required this.endpoint,
    required this.model,
    required this.apiKey,
  });

  @override
  String get id => 'openai-compatible:${sha256.convert(utf8.encode(endpoint))}';

  @override
  String get modelVersion => '$model:comic-v2';

  @override
  Future<void> load() async {}

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    if (model.trim().isEmpty) throw StateError('Remote translation model is empty');
    final regions = {
      for (final region in request.ocr.regions)
        region.id: {
          'text': region.text,
          'confidence': region.confidence,
          'orientation': region.orientation.name,
        },
    };
    final client = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      headers: {
        'Content-Type': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      },
    ))..httpClientAdapter = RHttpAdapter();
    try {
      final translations = await _request(
        client,
        request,
        regions,
        repair: false,
      );
      final failed = Map.fromEntries(regions.entries.where((entry) {
        final translated = translations[entry.key];
        return translated != null &&
            _hasText(entry.value['text'] as String) &&
            !_hasText(translated);
      }));
      if (failed.isNotEmpty) {
        translations.addAll(await _request(
          client,
          request,
          failed,
          repair: true,
        ));
      }
      return ComicTranslationResult(translations);
    } finally {
      client.close();
    }
  }

  Future<Map<String, String>> _request(
    Dio client,
    ComicTranslationRequest request,
    Map<String, Map<String, Object>> regions, {
    required bool repair,
  }) async {
    final response = await client.post<Map<String, dynamic>>(
      endpoint,
      data: {
        'model': model,
        'temperature': 0,
        'response_format': {'type': 'json_object'},
        'messages': [
          {
            'role': 'system',
            'content':
                'Translate comic text ${request.ocr.sourceLanguage == 'auto' ? '' : 'from ${request.ocr.sourceLanguage} '}into ${request.targetLanguage}. '
                'OCR confidence describes recognition certainty; it is never permission to skip a region. '
                'Use neighboring regions and prior pages to infer noisy OCR. Preserve names and tone. '
                'Use natural target-language writing without romanization and keep each region concise. '
                '${repair ? 'The previous result for these regions contained no translated words. Translate them again; do not answer with only question marks or punctuation. ' : ''}'
                'Return one JSON object: {"translations":{"regionId":"text"}}. '
                'Every input regionId must appear exactly once.',
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
              'regions': regions,
            }),
          },
        ],
      },
    );
    final data = response.data!;
    final choices = data['choices'] as List;
    final message = Map<String, dynamic>.from(
      (choices.first as Map)['message'] as Map,
    );
    final payload = jsonDecode(message['content'] as String) as Map;
    final translations = Map<String, dynamic>.from(
      payload['translations'] as Map,
    );
    return translations.map((key, value) => MapEntry(key, value as String));
  }

  bool _hasText(String value) => RegExp(
    r'[A-Za-z0-9\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]',
  ).hasMatch(value);

  @override
  Future<void> unload() async {}
}
