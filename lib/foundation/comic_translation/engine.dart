import 'dart:async';
import 'dart:math' as math;

import 'grouping.dart';
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
  final ComicTextOrientation orientation;
  final List<List<String>> bandRegionIds;

  const ComicTranslationUnit({
    required this.id,
    required this.regionIds,
    required this.sourceLines,
    required this.orientation,
    required this.bandRegionIds,
  });

  static List<ComicTranslationUnit> fromOcr(
    ComicOcrArtifact ocr, {
    bool translateSoundEffects = false,
  }) {
    final regions = ocr.regions
        .where((region) =>
            translateSoundEffects || region.kind != ComicTextKind.soundEffect)
        .toList();
    final grouping = ComicTextGrouping(
      imageWidth: ocr.imageWidth,
      imageHeight: ocr.imageHeight,
      sourceLanguage: ocr.sourceLanguage,
    );
    final groups = grouping.resolve(regions.map((region) => ComicTextRegion(
      value: region,
      id: region.id,
      text: region.text,
      polygon: region.polygon,
      sourceMaskPolygons: region.sourceMaskPolygons,
      orientation: region.orientation,
      backgroundArgb: region.backgroundArgb,
      bubbleGroupId: region.bubbleGroupId,
      bubblePolygon: region.bubblePolygon,
    )).toList());
    final bodyThickness = _dominantBodyThickness(ocr, regions);
    return groups.where((group) {
      final members = group.regions.map((region) => region.value).toList();
      return _hasMeaningfulText(members) &&
          (translateSoundEffects ||
              !_likelySoundEffect(ocr, members, bodyThickness));
    }).map((group) {
      final regions = group.regions.map((region) => region.value).toList();
      return ComicTranslationUnit(
        id: group.key,
        regionIds: regions.map((region) => region.id).toList(),
        sourceLines: regions.map((region) => region.text).toList(),
        orientation: group.orientation,
        bandRegionIds: group.bands.map((band) =>
            band.regions.map((region) => region.id).toList()).toList(),
      );
    }).toList();
  }

  static bool _hasMeaningfulText(List<ComicOcrRegion> regions) {
    final runes = regions
        .expand((region) => region.text.trim().runes)
        .toList();
    final meaningful = runes.where(_isMeaningfulRune).length;
    return meaningful > 0 && !(meaningful == 1 && runes.length >= 3);
  }

  static bool _likelySoundEffect(
    ComicOcrArtifact ocr,
    List<ComicOcrRegion> regions,
    double bodyThickness,
  ) {
    if (regions.any((region) => region.kind == ComicTextKind.soundEffect)) {
      return true;
    }
    if (regions.any((region) =>
        region.bubbleGroupId != null || region.bubblePolygon != null)) {
      return false;
    }
    final meaningful = regions
        .expand((region) => region.text.runes)
        .where(_isMeaningfulRune)
        .toList();
    if (meaningful.length > 12) return false;
    final thickness = regions
        .map((region) => _fontThickness(ocr, region))
        .reduce(math.max);
    final large = thickness >= bodyThickness * 1.55;
    final oblique = regions.any(_isOblique);
    final language =
        ocr.sourceLanguage.split(RegExp('[-_]')).first.toLowerCase();
    final katakana = meaningful
        .where((rune) => rune >= 0x30a0 && rune <= 0x30ff)
        .length;
    return oblique || large ||
        (language == 'ja' &&
            meaningful.length <= 8 &&
            katakana / meaningful.length >= 0.7);
  }

  static double _dominantBodyThickness(
    ComicOcrArtifact ocr,
    List<ComicOcrRegion> regions,
  ) {
    final values = regions
        .where((region) => _hasMeaningfulText([region]))
        .map((region) => _fontThickness(ocr, region))
        .where((value) => value > 0)
        .toList()
      ..sort();
    if (values.isEmpty) return 1;
    var bestStart = 0;
    var bestEnd = 1;
    for (var start = 0; start < values.length; start++) {
      var end = start + 1;
      while (end < values.length && values[end] <= values[start] * 1.35) {
        end++;
      }
      if (end - start > bestEnd - bestStart) {
        bestStart = start;
        bestEnd = end;
      }
    }
    final cluster = values.sublist(bestStart, bestEnd);
    return cluster[cluster.length ~/ 2];
  }

  static double _fontThickness(ComicOcrArtifact ocr, ComicOcrRegion region) {
    final xs = region.polygon.map((point) => point.x * ocr.imageWidth);
    final ys = region.polygon.map((point) => point.y * ocr.imageHeight);
    final width = xs.reduce(math.max) - xs.reduce(math.min);
    final height = ys.reduce(math.max) - ys.reduce(math.min);
    final characters = region.text
        .replaceAll(RegExp(r'\s'), '')
        .runes
        .length
        .clamp(1, 1000);
    return math.sqrt(width * height / characters);
  }

  static bool _isOblique(ComicOcrRegion region) {
    if (region.polygon.length < 2) return false;
    final edge = region.polygon[1];
    final start = region.polygon.first;
    final dx = edge.x - start.x;
    final dy = edge.y - start.y;
    return dx.abs() > 0.0001 && (dy / dx).abs() > 0.18;
  }

  static bool _isMeaningfulRune(int rune) =>
      rune >= 0x30 && rune <= 0x39 ||
      rune >= 0x41 && rune <= 0x5a ||
      rune >= 0x61 && rune <= 0x7a ||
      rune >= 0xc0 && rune <= 0x2af ||
      rune >= 0x370 && rune <= 0x52f ||
      rune >= 0x3040 && rune <= 0x30ff ||
      rune >= 0x31f0 && rune <= 0x31ff ||
      rune >= 0x3400 && rune <= 0x9fff ||
      rune >= 0xac00 && rune <= 0xd7af ||
      rune >= 0xf900 && rune <= 0xfaff ||
      rune >= 0xff10 && rune <= 0xff5a;
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
    bool translateSoundEffects = false,
    this.glossary = const {},
  }) : units = ComicTranslationUnit.fromOcr(
          ocr,
          translateSoundEffects: translateSoundEffects,
        );

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
      final rawLines = result.translations[unit.id]!;
      final lines = _normalizeUnitTranslation(unit, rawLines);
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

  List<String> _normalizeUnitTranslation(
    ComicTranslationUnit unit,
    List<String> lines,
  ) {
    if (lines.length != unit.sourceLines.length) return lines;
    final trimmed = lines.map((line) => line.trim()).toList();
    final repeated = trimmed.length > 1 &&
        trimmed.map(_letters).toSet().length == 1 &&
        unit.sourceLines.map(_letters).toSet().length > 1 &&
        trimmed.first.runes.length >= trimmed.length;
    if (repeated) {
      final text = _preservePunctuation(
        unit.sourceLines.join(),
        trimmed.first,
      );
      return _splitBySourceWeight(text, unit.sourceLines);
    }
    return List.generate(lines.length, (index) =>
        _preservePunctuation(unit.sourceLines[index], trimmed[index]));
  }

  List<String> _splitBySourceWeight(String text, List<String> sources) {
    final glyphs = text.runes.map(String.fromCharCode).toList();
    final weights = sources.map((source) => math.max(1, _letters(source).length))
        .toList();
    final total = weights.reduce((a, b) => a + b);
    var sourceTotal = 0;
    var start = 0;
    return List.generate(sources.length, (index) {
      sourceTotal += weights[index];
      final end = index == sources.length - 1
          ? glyphs.length
          : (glyphs.length * sourceTotal / total).round().clamp(
              start + 1,
              glyphs.length - sources.length + index + 1,
            ).toInt();
      final value = glyphs.sublist(start, end).join().trim();
      start = end;
      return value;
    });
  }

  String _preservePunctuation(String source, String translation) {
    final sourceGlyphs = source.trim().runes.map(String.fromCharCode).toList();
    var trailingStart = sourceGlyphs.length;
    while (trailingStart > 0 &&
        _punctuationClass(sourceGlyphs[trailingStart - 1]) != null) {
      trailingStart--;
    }
    final sourceMarks = <_SourcePunctuation>[];
    for (var index = 0; index < sourceGlyphs.length; index++) {
      final glyph = sourceGlyphs[index];
      final category = _punctuationClass(glyph);
      if (category != null) {
        sourceMarks.add(_SourcePunctuation(
          glyph,
          category,
          index >= trailingStart,
        ));
      }
    }
    final output = StringBuffer();
    final remaining = <int, int>{};
    for (final rune in translation.runes) {
      final category = _punctuationClass(String.fromCharCode(rune));
      if (category != null) remaining[category] = (remaining[category] ?? 0) + 1;
    }
    for (final rune in translation.runes) {
      final glyph = String.fromCharCode(rune);
      final category = _punctuationClass(glyph);
      if (category == null) {
        output.write(glyph);
        continue;
      }
      remaining[category] = remaining[category]! - 1;
      final available = sourceMarks
          .where((mark) => !mark.used && mark.category == category)
          .length;
      if (remaining[category]! >= available) continue;
      final match = sourceMarks.indexWhere(
        (mark) => !mark.used && mark.category == category,
      );
      if (match < 0) continue;
      sourceMarks[match].used = true;
      output.write(sourceMarks[match].glyph);
    }
    final suffix = sourceMarks
        .where((mark) => mark.trailing && !mark.used)
        .map((mark) => mark.glyph)
        .join();
    return '${output.toString().trim()}$suffix';
  }

  String _letters(String value) => String.fromCharCodes(value.runes.where(
    (rune) {
      final glyph = String.fromCharCode(rune);
      return glyph != comicTranslationBreakMarker &&
          _punctuationClass(glyph) == null &&
          glyph.trim().isNotEmpty;
    },
  ));

  int? _punctuationClass(String glyph) {
    if (const {'。', '.', '！', '!', '？', '?'}.contains(glyph)) return 0;
    if (const {'…', '⋯', '︙', '⋮', '・'}.contains(glyph)) return 1;
    if (const {'，', ',', '、', '；', ';', '：', ':'}.contains(glyph)) return 2;
    return null;
  }
}

final class _SourcePunctuation {
  final String glyph;
  final int category;
  final bool trailing;
  bool used = false;

  _SourcePunctuation(this.glyph, this.category, this.trailing);
}

final class ComicTranslationResult {
  final Map<String, List<String>> translations;

  const ComicTranslationResult(this.translations);
}

final class ComicTextTranslationRunMetrics {
  final Duration elapsed;
  final List<Duration> batchDurations;
  final int unitCount;
  final int sourceCharacters;

  const ComicTextTranslationRunMetrics({
    required this.elapsed,
    required this.batchDurations,
    required this.unitCount,
    required this.sourceCharacters,
  });
}

abstract interface class ComicTextTranslationEngineDiagnostics {
  ComicTextTranslationRunMetrics? get lastRunMetrics;

  List<String> get lastRawResponses;
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
