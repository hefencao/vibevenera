import 'dart:async';

import 'models.dart';

final class ComicOcrInput {
  final ComicTranslationPageIdentity identity;
  final String filePath;
  final String contentDigest;
  final String sourceLanguage;
  final int maxAnalysisSide;
  final AnimatedTranslationMode animatedMode;

  const ComicOcrInput({
    required this.identity,
    required this.filePath,
    required this.contentDigest,
    required this.sourceLanguage,
    required this.maxAnalysisSide,
    required this.animatedMode,
  });
}

final class ComicTranslationContextEntry {
  final int pageIndex;
  final List<String> sourceTexts;
  final List<String> translatedTexts;

  const ComicTranslationContextEntry({
    required this.pageIndex,
    required this.sourceTexts,
    required this.translatedTexts,
  });
}

final class ComicTranslationRequest {
  final ComicOcrArtifact ocr;
  final String targetLanguage;
  final List<ComicTranslationContextEntry> previousPages;
  final Map<String, String> glossary;

  const ComicTranslationRequest({
    required this.ocr,
    required this.targetLanguage,
    required this.previousPages,
    this.glossary = const {},
  });
}

final class ComicTranslationResult {
  final Map<String, String> translations;

  const ComicTranslationResult(this.translations);
}

final class ComicOcrRunMetrics {
  final int tileCount;
  final Duration detectionPreprocess;
  final Duration detectionInference;
  final Duration detectionPostprocess;
  final Duration recognitionPreprocess;
  final Duration recognitionInference;
  final Duration recognitionPostprocess;
  final Duration bubbleSegmentation;

  const ComicOcrRunMetrics({
    required this.tileCount,
    required this.detectionPreprocess,
    required this.detectionInference,
    required this.detectionPostprocess,
    required this.recognitionPreprocess,
    required this.recognitionInference,
    required this.recognitionPostprocess,
    required this.bubbleSegmentation,
  });

  Duration get detection =>
      detectionPreprocess + detectionInference + detectionPostprocess;

  Duration get recognition =>
      recognitionPreprocess + recognitionInference + recognitionPostprocess;
}

abstract interface class ComicOcrEngineDiagnostics {
  ComicOcrRunMetrics? get lastRunMetrics;
}

abstract interface class ComicOcrEngine {
  String get id;

  String get modelVersion;

  /// Animated analysis requires an independent read-only frame sampler. It
  /// must never share the Reader playback cursor or source epoch.
  bool get supportsAnimatedPosterFrame;

  Future<void> load(String sourceLanguage);

  Future<ComicOcrArtifact> recognize(ComicOcrInput input);

  Future<void> unload();
}

abstract interface class ComicTextTranslationEngine {
  String get id;

  String get modelVersion;

  Future<void> load();

  Future<ComicTranslationResult> translate(ComicTranslationRequest request);

  Future<void> unload();
}

/// Runtime adapters are registered by the model/backend layer. Keeping this
/// registry free of a silent network fallback makes local/remote selection an
/// explicit user decision.
final class ComicTranslationEngineRegistry {
  ComicTranslationEngineRegistry();

  static final instance = ComicTranslationEngineRegistry();

  ComicOcrEngine? ocrEngine;
  ComicTextTranslationEngine? translationEngine;
  ComicTranslationEnginePair? _active;
  int _users = 0;
  bool _ocrLoaded = false;
  bool _translatorLoaded = false;
  Future<void> _tail = Future.value();

  bool get ready => ocrEngine != null && translationEngine != null;

  Future<ComicTranslationEnginePair> acquire() => _serialized(() async {
    final pair = ComicTranslationEnginePair(ocrEngine!, translationEngine!);
    if (_active != null && _active != pair) {
      throw StateError('Comic translation engines changed while in use');
    }
    _active ??= pair;
    _users++;
    return _active!;
  });

  Future<void> loadOcr(
    ComicTranslationEnginePair pair,
    String sourceLanguage,
  ) => _serialized(() async {
    _checkLease(pair);
    if (_ocrLoaded) return;
    await pair.ocr.load(sourceLanguage);
    _ocrLoaded = true;
  });

  Future<void> loadTranslator(ComicTranslationEnginePair pair) =>
      _serialized(() async {
        _checkLease(pair);
        if (_translatorLoaded) return;
        await pair.translator.load();
        _translatorLoaded = true;
      });

  Future<void> release(ComicTranslationEnginePair pair) => _serialized(() async {
    _checkLease(pair);
    if (--_users != 0) return;
    if (_translatorLoaded) await pair.translator.unload();
    if (_ocrLoaded) await pair.ocr.unload();
    _translatorLoaded = false;
    _ocrLoaded = false;
    _active = null;
  });

  void _checkLease(ComicTranslationEnginePair pair) {
    if (_active != pair || _users == 0) {
      throw StateError('Comic translation engine pair is not leased');
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) => action()).then(
      completer.complete,
      onError: completer.completeError,
    );
    return completer.future;
  }
}

final class ComicTranslationEnginePair {
  final ComicOcrEngine ocr;
  final ComicTextTranslationEngine translator;

  const ComicTranslationEnginePair(this.ocr, this.translator);

  @override
  bool operator ==(Object other) =>
      other is ComicTranslationEnginePair &&
      identical(other.ocr, ocr) &&
      identical(other.translator, translator);

  @override
  int get hashCode => Object.hash(identityHashCode(ocr), identityHashCode(translator));
}
