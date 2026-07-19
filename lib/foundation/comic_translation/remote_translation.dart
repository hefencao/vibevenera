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
  static const _maxAttempts = 3;

  final String endpoint;
  final String model;
  final String apiKey;
  final String additionalPrompt;
  Dio? _client;
  ComicTextTranslationRunMetrics? _lastRunMetrics;
  List<String> _lastRawResponses = const [];
  bool? _responseFormatSupported;

  OpenAiCompatibleComicTranslationEngine({
    required this.endpoint,
    required this.model,
    required this.apiKey,
    this.additionalPrompt = '',
  });

  @override
  String get id =>
      'openai-compatible:${sha256.convert(utf8.encode(endpoint.trim()))}';

  @override
  String get modelVersion => '${model.trim()}:bubble-unit-lines-v27:'
      '${sha256.convert(utf8.encode(additionalPrompt.trim()))}';

  @override
  ComicTextTranslationRunMetrics? get lastRunMetrics => _lastRunMetrics;

  @override
  List<String> get lastRawResponses => List.unmodifiable(_lastRawResponses);

  @override
  Future<void> load() async => _client ??= _createClient();

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    _lastRunMetrics = null;
    _lastRawResponses = const [];
    if (model.trim().isEmpty) {
      throw StateError('Remote translation model is empty');
    }
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw StateError('Remote translation endpoint is invalid');
    }
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
    total.stop();
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
    final aliases = <String, ComicTranslationUnit>{
      for (var index = 0; index < units.length; index++)
        'u$index': units[index],
    };
    final systemPrompt = [
      'Translate comic OCR ${request.ocr.sourceLanguage == 'auto' ? '' : 'from ${request.ocr.sourceLanguage} '}to ${request.targetLanguage}; use prior pages only as context and preserve names and tone.',
      'Each unit is one balloon. Translate its ordered sourceLines jointly and return concise natural text without romanization or explanations.',
      'Preserve punctuation and ellipses. When an extra clause break is required, use only $comicTranslationBreakMarker.',
      if (preference.isNotEmpty)
        'Preference: $preference Do not change unit boundaries or output format.',
      'Return JSON only: {"translations":{"u0":["text"]}}. Include every input id once. Prefer one output string per source line, but never repeat a full translation merely to match line count.',
    ].join(' ');
    final messages = [
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
          'units': aliases.entries.map((entry) => {
            'id': entry.key,
            'sourceLines': entry.value.sourceLines,
          }).toList(),
        }),
      },
    ];
    final rawData = await _postCompletion(
      client,
      messages,
      onResponse,
    );
    final data = _responseMap(rawData);
    final payload = _translationPayload(data);
    final rawTranslations = payload['translations'];
    if (rawTranslations is! Map) {
      throw const FormatException('Translation payload has no translations map');
    }
    final values = Map<String, dynamic>.from(rawTranslations);
    final translations = <String, List<String>>{};
    for (final entry in aliases.entries) {
      final value = values[entry.key];
      if (value == null) {
        throw FormatException('Translation batch is missing ${entry.key}');
      }
      final lines = value is String
          ? <String>[value]
          : value is List
              ? value.map((line) {
                  if (line is! String) {
                    throw FormatException(
                      'Translation unit ${entry.key} contains a non-string line',
                    );
                  }
                  return line;
                }).toList(growable: false)
              : throw FormatException(
                  'Translation unit ${entry.key} must be a string or array',
                );
      final normalized = lines
          .map((line) => line.trim())
          .toList(growable: false);
      if (normalized.isEmpty || normalized.any((line) => line.isEmpty)) {
        throw FormatException('Translation unit ${entry.key} is empty');
      }
      translations[entry.value.id] = normalized;
    }
    return translations;
  }

  Future<dynamic> _postCompletion(
    Dio client,
    List<Map<String, dynamic>> messages,
    void Function(String value) onResponse,
  ) async {
    var includeResponseFormat = _responseFormatSupported != false;
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      try {
        final response = await client.post<dynamic>(
          endpoint.trim(),
          data: {
            'model': model.trim(),
            'temperature': 0,
            if (includeResponseFormat)
              'response_format': {'type': 'json_object'},
            'messages': messages,
          },
        );
        final rawData = response.data;
        if (rawData == null) {
          throw const FormatException('Translation response is empty');
        }
        if (includeResponseFormat) _responseFormatSupported = true;
        onResponse(_prettyResponse(rawData));
        return rawData;
      } on DioException catch (error, stackTrace) {
        lastError = error;
        lastStack = stackTrace;
        if (includeResponseFormat && _rejectsResponseFormat(error)) {
          _responseFormatSupported = false;
          includeResponseFormat = false;
          continue;
        }
        if (!_isTransient(error) || attempt == _maxAttempts - 1) rethrow;
        await Future<void>.delayed(
          Duration(milliseconds: 350 * (1 << attempt)),
        );
      } catch (error, stackTrace) {
        lastError = error;
        lastStack = stackTrace;
        rethrow;
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  bool _rejectsResponseFormat(DioException error) {
    final status = error.response?.statusCode;
    if (status != 400 && status != 422) return false;
    final data = error.response?.data;
    final message = (data is String ? data : jsonEncode(data)).toLowerCase();
    return message.contains('response_format') ||
        message.contains('json_object');
  }

  bool _isTransient(DioException error) {
    if (error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.cancel ||
        error.type == DioExceptionType.badCertificate) {
      return false;
    }
    final status = error.response?.statusCode;
    return status == null ||
        status == 408 ||
        status == 429 ||
        status == 500 ||
        status == 502 ||
        status == 503 ||
        status == 504;
  }

  String _prettyResponse(dynamic value) => value is String
      ? value
      : const JsonEncoder.withIndent('  ').convert(value);

  Map<String, dynamic> _responseMap(dynamic rawData) => rawData is String
      ? decodeComicTranslationJson(rawData)
      : rawData is Map
          ? Map<String, dynamic>.from(rawData)
          : throw const FormatException(
              'Translation response must be a JSON object',
            );

  Map<String, dynamic> _translationPayload(Map<String, dynamic> data) {
    if (data['translations'] is Map) return data;
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const FormatException('Translation response has no choices');
    }
    final message = (choices.first as Map)['message'];
    if (message is! Map) {
      throw const FormatException('Translation response has no message');
    }
    final content = message['content'];
    final text = switch (content) {
      String value => value,
      List value => value.map((part) {
          if (part is Map && part['text'] is String) {
            return part['text'] as String;
          }
          throw const FormatException(
            'Translation message content part is not text',
          );
        }).join(),
      _ => throw const FormatException(
          'Translation message content is not text',
        ),
    };
    return decodeComicTranslationJson(text);
  }

  @override
  Future<void> unload() async {
    _client?.close();
    _client = null;
  }

  Dio _createClient() => Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 90),
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
