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

final class ComicTranslationUnit {
  final String id;
  final List<String> regionIds;
  final List<String> sourceLines;

  const ComicTranslationUnit({
    required this.id,
    required this.regionIds,
    required this.sourceLines,
  });

  static List<ComicTranslationUnit> fromOcr(ComicOcrArtifact ocr) {
    final regions = [...ocr.regions]
      ..sort((a, b) {
        final order = a.readingOrder.compareTo(b.readingOrder);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    final groups = <String, List<ComicOcrRegion>>{};
    for (final region in regions) {
      if (region.kind == ComicTextKind.soundEffect) continue;
      final id = region.bubbleGroupId == null
          ? region.id
          : 'bubble:${region.bubbleGroupId}';
      groups.putIfAbsent(id, () => []).add(region);
    }
    return groups.entries.map((entry) {
      final regions = entry.value;
      final vertical = regions
          .where((region) =>
              region.orientation == ComicTextOrientation.vertical)
          .length;
      if (vertical * 2 > regions.length) {
        regions.sort((a, b) {
          final column = _centerX(b).compareTo(_centerX(a));
          return column != 0 ? column : _top(a).compareTo(_top(b));
        });
      } else if (vertical * 2 < regions.length) {
        regions.sort((a, b) {
          final row = _top(a).compareTo(_top(b));
          return row != 0 ? row : _left(a).compareTo(_left(b));
        });
      }
      return ComicTranslationUnit(
        id: entry.key,
        regionIds: regions.map((region) => region.id).toList(),
        sourceLines: regions.map((region) => region.text).toList(),
      );
    }).toList();
  }

  static double _left(ComicOcrRegion region) => region.polygon
      .map((point) => point.x)
      .reduce((value, next) => value < next ? value : next);

  static double _top(ComicOcrRegion region) => region.polygon
      .map((point) => point.y)
      .reduce((value, next) => value < next ? value : next);

  static double _centerX(ComicOcrRegion region) {
    final xs = region.polygon.map((point) => point.x);
    final left = xs.reduce((value, next) => value < next ? value : next);
    final right = xs.reduce((value, next) => value > next ? value : next);
    return (left + right) / 2;
  }
}

final class ComicTranslationRequest {
  final ComicOcrArtifact ocr;
  final List<ComicTranslationUnit> units;
  final String targetLanguage;
  final List<ComicTranslationContextEntry> previousPages;
  final Map<String, String> glossary;

  ComicTranslationRequest({
    required this.ocr,
    required this.targetLanguage,
    required this.previousPages,
    this.glossary = const {},
  }) : units = ComicTranslationUnit.fromOcr(ocr);

  Map<String, String> expandUnitTranslations(
    ComicTranslationResult result,
  ) {
    final expected = units.map((unit) => unit.id).toSet();
    if (result.translations.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(result.translations.keys.toSet()).isNotEmpty) {
      throw StateError('Translation unit IDs do not match the request');
    }
    final expanded = {for (final region in ocr.regions) region.id: ''};
    for (final unit in units) {
      final lines = result.translations[unit.id]!;
      if (lines.length != unit.regionIds.length) {
        throw StateError(
          'Translation unit ${unit.id} has ${lines.length} lines; '
          'expected ${unit.regionIds.length}',
        );
      }
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trim().isEmpty) {
          throw StateError('Translation unit ${unit.id} line $i is empty');
        }
        expanded[unit.regionIds[i]] = lines[i];
      }
    }
    return expanded;
  }
}

final class ComicTranslationResult {
  final Map<String, List<String>> translations;

  const ComicTranslationResult(this.translations);
}

final class ComicOcrRunMetrics {
  final String recognizer;
  final int tileCount;
  final int detectionInputPixels;
  final List<List<int>> detectionInputShapes;
  final int detectedCount;
  final int rawDecodedCount;
  final int acceptedCount;
  final int balloonCandidates;
  final int rescuedRegions;
  final int cleanOverlayBytes;
  final Duration detectionPreprocess;
  final Duration detectionInference;
  final Duration detectionPostprocess;
  final Duration recognitionPreprocess;
  final Duration recognitionInference;
  final Duration recognitionPostprocess;
  final Duration bubbleSegmentation;
  final Duration balloonProposal;
  final Duration cleanOverlayEncode;

  const ComicOcrRunMetrics({
    required this.recognizer,
    required this.tileCount,
    required this.detectionInputPixels,
    required this.detectionInputShapes,
    required this.detectedCount,
    required this.rawDecodedCount,
    required this.acceptedCount,
    required this.balloonCandidates,
    required this.rescuedRegions,
    required this.cleanOverlayBytes,
    required this.detectionPreprocess,
    required this.detectionInference,
    required this.detectionPostprocess,
    required this.recognitionPreprocess,
    required this.recognitionInference,
    required this.recognitionPostprocess,
    required this.bubbleSegmentation,
    required this.balloonProposal,
    required this.cleanOverlayEncode,
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
