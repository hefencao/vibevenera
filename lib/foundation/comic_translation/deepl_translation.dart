import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/network/app_dio.dart';

import 'engine.dart';

final class DeepLComicTranslationEngine
    implements ComicTextTranslationEngine, ComicTextTranslationEngineDiagnostics {
  static const _maxBatchUnits = 50;
  static const _maxRequestBytes = 120 * 1024;
  static const _maxContextBytes = 12 * 1024;
  static const _maxAttempts = 2;
  static const _modelTypes = {
    'latency_optimized',
    'quality_optimized',
    'prefer_quality_optimized',
  };

  final String endpoint;
  final String apiKey;
  final String modelType;
  Dio? _client;
  final bool _ownsClient;
  ComicTextTranslationRunMetrics? _lastRunMetrics;
  List<String> _lastRawResponses = const [];

  DeepLComicTranslationEngine({
    required this.endpoint,
    required this.apiKey,
    this.modelType = 'latency_optimized',
    Dio? client,
  }) : _client = client,
       _ownsClient = client == null;

  @override
  String get id =>
      'deepl:${sha256.convert(utf8.encode(_translateEndpoint.toString()))}';

  @override
  String get modelVersion => 'deepl-v1:$_validatedModelType';

  @override
  ComicTextTranslationRunMetrics? get lastRunMetrics => _lastRunMetrics;

  @override
  List<String> get lastRawResponses => List.unmodifiable(_lastRawResponses);

  String get _validatedModelType {
    final value = modelType.trim();
    if (!_modelTypes.contains(value)) {
      throw StateError('Unsupported DeepL model type: $value');
    }
    return value;
  }

  Uri get _translateEndpoint {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw StateError('DeepL translation endpoint is invalid');
    }
    return uri.path.isEmpty || uri.path == '/'
        ? uri.replace(path: '/v2/translate')
        : uri;
  }

  @override
  Future<void> load() async => _client ??= _createClient();

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    _lastRunMetrics = null;
    _lastRawResponses = const [];
    if (apiKey.trim().isEmpty) throw StateError('DeepL API key is empty');
    if (request.units.isEmpty) return const ComicTranslationResult({});
    final batches = _buildBatches(request);
    final durations = <Duration>[];
    final rawResponses = <String>[];
    final translations = <String, List<String>>{};
    final total = Stopwatch()..start();
    final client = _client ?? _createClient();
    final temporaryClient = _client == null;
    try {
      for (final batch in batches) {
        final timer = Stopwatch()..start();
        final response = await _post(client, _requestBody(request, batch));
        timer.stop();
        durations.add(timer.elapsed);
        final raw = response.data;
        final printable = raw is String
            ? raw
            : const JsonEncoder.withIndent('  ').convert(raw);
        rawResponses.add(printable);
        _lastRawResponses = List.unmodifiable(rawResponses);
        translations.addAll(_decodeBatch(request, batch, raw));
      }
    } finally {
      if (temporaryClient) client.close();
    }
    total.stop();
    _lastRunMetrics = ComicTextTranslationRunMetrics(
      elapsed: total.elapsed,
      batchDurations: durations,
      unitCount: request.units.length,
      sourceCharacters: request.units.fold(
        0,
        (sum, unit) =>
            sum + unit.sourceLines.fold(0, (a, b) => a + b.runes.length),
      ),
    );
    return ComicTranslationResult(translations);
  }

  List<List<ComicTranslationUnit>> _buildBatches(
    ComicTranslationRequest request,
  ) {
    final batches = <List<ComicTranslationUnit>>[];
    var batch = <ComicTranslationUnit>[];
    for (final unit in request.units) {
      final candidate = [...batch, unit];
      final bytes = utf8.encode(jsonEncode(_requestBody(request, candidate))).length;
      if (batch.isNotEmpty &&
          (candidate.length > _maxBatchUnits || bytes > _maxRequestBytes)) {
        batches.add(batch);
        batch = [unit];
      } else {
        batch = candidate;
      }
      final singleBytes = utf8.encode(jsonEncode(_requestBody(request, batch))).length;
      if (singleBytes > _maxRequestBytes) {
        throw StateError('A DeepL translation unit exceeds the request limit');
      }
    }
    if (batch.isNotEmpty) batches.add(batch);
    return batches;
  }

  Map<String, dynamic> _requestBody(
    ComicTranslationRequest request,
    List<ComicTranslationUnit> units,
  ) {
    final sourceLanguage = _sourceLanguage(request.ocr.sourceLanguage);
    final context = _context(request);
    return {
      'text': units.map((unit) => unit.sourceLines.join('\n')).toList(),
      'target_lang': _targetLanguage(request.targetLanguage),
      if (sourceLanguage != null) 'source_lang': sourceLanguage,
      if (context.isNotEmpty) 'context': context,
      'model_type': _validatedModelType,
      'preserve_formatting': true,
      'split_sentences': 'nonewlines',
    };
  }

  Future<Response<dynamic>> _post(
    Dio client,
    Map<String, dynamic> body,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await client.post<dynamic>(
          _translateEndpoint.toString(),
          data: body,
          options: Options(headers: {
            'Content-Type': 'application/json',
            'Authorization': 'DeepL-Auth-Key ${apiKey.trim()}',
          }),
        );
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        final transient = status == null || status == 408 || status == 429 ||
            status == 500 || status == 502 || status == 503 || status == 504;
        if (!transient || attempt + 1 >= _maxAttempts) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  Map<String, List<String>> _decodeBatch(
    ComicTranslationRequest request,
    List<ComicTranslationUnit> units,
    dynamic raw,
  ) {
    final data = raw is String ? jsonDecode(raw) : raw;
    if (data is! Map || data['translations'] is! List) {
      throw const FormatException('DeepL response has no translations array');
    }
    final values = data['translations'] as List;
    if (values.length != units.length) {
      throw FormatException(
        'DeepL returned ${values.length} translations for ${units.length} units',
      );
    }
    final result = <String, List<String>>{};
    for (var index = 0; index < units.length; index++) {
      final value = values[index];
      if (value is! Map || value['text'] is! String) {
        throw FormatException('DeepL translation $index has no text field');
      }
      final text = (value['text'] as String).trim();
      if (text.isEmpty) {
        throw FormatException('DeepL translation $index is empty');
      }
      final lines = text
          .split(RegExp(r'\r\n?|\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      result[units[index].id] = lines.length == units[index].sourceLines.length
          ? lines
          : [lines.join(_targetSeparator(request.targetLanguage))];
    }
    return result;
  }

  String _context(ComicTranslationRequest request) {
    final values = request.previousPages
        .expand((page) => page.sourceTexts)
        .where((text) => text.trim().isNotEmpty)
        .join('\n');
    final bytes = utf8.encode(values);
    if (bytes.length <= _maxContextBytes) return values;
    final runes = values.runes.toList();
    var start = runes.length;
    var size = 0;
    while (start > 0) {
      final runeBytes = utf8.encode(String.fromCharCode(runes[start - 1])).length;
      if (size + runeBytes > _maxContextBytes) break;
      size += runeBytes;
      start--;
    }
    return String.fromCharCodes(runes.sublist(start));
  }

  String? _sourceLanguage(String language) {
    final normalized = language.trim().replaceAll('_', '-').toUpperCase();
    if (normalized.isEmpty || normalized == 'AUTO') return null;
    return switch (normalized) {
      'ZH-CN' || 'ZH-HANS' || 'ZH-TW' || 'ZH-HANT' => 'ZH',
      _ => normalized.split('-').first,
    };
  }

  String _targetLanguage(String language) {
    final normalized = language.trim().replaceAll('_', '-').toUpperCase();
    if (normalized.isEmpty || normalized == 'AUTO' || normalized == 'SYSTEM') {
      throw StateError('DeepL target language is not resolved');
    }
    return switch (normalized) {
      'ZH' || 'ZH-CN' || 'ZH-HANS' => 'ZH-HANS',
      'ZH-TW' || 'ZH-HK' || 'ZH-HANT' => 'ZH-HANT',
      'EN-US' => 'EN-US',
      'EN-GB' => 'EN-GB',
      'PT-BR' => 'PT-BR',
      'PT-PT' => 'PT-PT',
      _ => normalized.split('-').first,
    };
  }

  String _targetSeparator(String language) {
    final base = language.split(RegExp('[-_]')).first.toLowerCase();
    return {'zh', 'ja', 'ko'}.contains(base) ? '' : ' ';
  }

  @override
  Future<void> unload() async {
    if (!_ownsClient) return;
    _client?.close();
    _client = null;
  }

  Dio _createClient() => Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    sendTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'DeepL-Auth-Key ${apiKey.trim()}',
    },
  ))..httpClientAdapter = RHttpAdapter();
}
