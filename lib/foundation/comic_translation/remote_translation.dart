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
  String get modelVersion => model;

  @override
  Future<void> load() async {}

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    if (model.trim().isEmpty) throw StateError('Remote translation model is empty');
    final source = {
      for (final region in request.ocr.regions) region.id: region.text,
    };
    final client = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      headers: {
        'Content-Type': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      },
    ))..httpClientAdapter = RHttpAdapter();
    late Response<Map<String, dynamic>> response;
    try {
      response = await client.post<Map<String, dynamic>>(
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
                  'Use prior pages only as context. Preserve names and tone. '
                  'Use natural target-language writing without romanization and keep each region concise. '
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
                'regions': source,
              }),
            },
          ],
        },
      );
    } finally {
      client.close();
    }
    final data = response.data!;
    final choices = data['choices'] as List;
    final message = Map<String, dynamic>.from(
      (choices.first as Map)['message'] as Map,
    );
    final payload = jsonDecode(message['content'] as String) as Map;
    final translations = Map<String, dynamic>.from(
      payload['translations'] as Map,
    );
    return ComicTranslationResult(
      translations.map((key, value) => MapEntry(key, value as String)),
    );
  }

  @override
  Future<void> unload() async {}
}
