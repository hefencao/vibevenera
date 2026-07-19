import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'bubble_boundary.dart';
import 'engine.dart';
import 'grouping.dart';
import 'input_resolver.dart';
import 'models.dart';

final class ComicTranslationBenchmarkSample {
  final ComicTranslationPageIdentity identity;
  final Duration inputResolveTime;
  final Duration ocrTime;
  final Duration translationTime;
  final ComicOcrRunMetrics? ocrMetrics;
  final ComicTextTranslationRunMetrics? translationMetrics;
  final int regionCount;
  final int bubbleCount;
  final int sourceMaskCount;
  final List<String> sourceTexts;
  final List<double> sourceConfidences;
  final List<int?> bubbleGroupIds;
  final List<bool> bubbleCandidateAvailable;
  final List<String?> translationUnitIds;
  final List<int?> translationUnitOrders;
  final List<int?> translationBandIndices;
  final List<ComicTextOrientation?> translationUnitOrientations;
  final List<String> relationDiagnostics;
  final List<String> bubbleBoundaryDiagnostics;
  final List<String> translatedTexts;
  final int rssBefore;
  final int rssAfter;

  const ComicTranslationBenchmarkSample({
    required this.identity,
    required this.inputResolveTime,
    required this.ocrTime,
    required this.translationTime,
    required this.ocrMetrics,
    required this.translationMetrics,
    required this.regionCount,
    required this.bubbleCount,
    required this.sourceMaskCount,
    required this.sourceTexts,
    required this.sourceConfidences,
    required this.bubbleGroupIds,
    required this.bubbleCandidateAvailable,
    required this.translationUnitIds,
    required this.translationUnitOrders,
    required this.translationBandIndices,
    required this.translationUnitOrientations,
    required this.relationDiagnostics,
    required this.bubbleBoundaryDiagnostics,
    required this.translatedTexts,
    required this.rssBefore,
    required this.rssAfter,
  });
}

final class ComicTranslationBenchmarkResult {
  final Duration ocrLoadTime;
  final Duration translationLoadTime;
  final bool translationMeasured;
  final List<ComicTranslationBenchmarkSample> samples;
  final int rssBeforeLoad;
  final int rssAfterLoad;
  /// Highest whole-process RSS sampled at load/page boundaries, not the
  /// instantaneous OCR inference peak.
  final int maxObservedRss;
  final int rssAfterRelease;

  const ComicTranslationBenchmarkResult({
    required this.ocrLoadTime,
    required this.translationLoadTime,
    required this.translationMeasured,
    required this.samples,
    required this.rssBeforeLoad,
    required this.rssAfterLoad,
    required this.maxObservedRss,
    required this.rssAfterRelease,
  });
}

final class ComicTranslationBenchmark {
  final ComicTranslationEngineRegistry engines;
  final ComicTranslationInputResolver inputResolver;

  ComicTranslationBenchmark({
    ComicTranslationEngineRegistry? engines,
    this.inputResolver = const ComicTranslationInputResolver(),
  }) : engines = engines ?? ComicTranslationEngineRegistry.instance;

  Future<ComicTranslationBenchmarkResult> run({
    required List<ComicTranslationPageIdentity> pages,
    required String sourceLanguage,
    required String targetLanguage,
    int maxAnalysisSide = 1600,
    bool runTranslation = true,
    bool diagnoseGrouping = true,
  }) async {
    final translationMeasured =
        runTranslation && engines.translationEngine != null;
    final benchmarkEngines = translationMeasured
        ? engines
        : (ComicTranslationEngineRegistry()
            ..ocrEngine = engines.ocrEngine
            ..translationEngine = const _BenchmarkNoopTranslationEngine());
    final pair = await benchmarkEngines.acquire();
    final rssBeforeLoad = ProcessInfo.currentRss;
    late Duration ocrLoad;
    late Duration translationLoad;
    late int rssAfterLoad;
    var maxObservedRss = rssBeforeLoad;
    final samples = <ComicTranslationBenchmarkSample>[];
    try {
      final timer = Stopwatch()..start();
      await benchmarkEngines.loadOcr(pair, sourceLanguage);
      ocrLoad = timer.elapsed;
      timer.reset();
      await benchmarkEngines.loadTranslator(pair);
      translationLoad = timer.elapsed;
      rssAfterLoad = ProcessInfo.currentRss;
      maxObservedRss = rssAfterLoad > maxObservedRss
          ? rssAfterLoad
          : maxObservedRss;
      for (final page in pages) {
        final rssBefore = ProcessInfo.currentRss;
        timer.reset();
        final resolved = await inputResolver.resolve(page);
        if (resolved == null) {
          throw StateError('Benchmark page is not available: ${page.imageKey}');
        }
        if (resolved.mediaKind == ComicTranslationMediaKind.animatedImage) {
          throw StateError('Animated image translation is not implemented');
        }
        final inputTime = timer.elapsed;
        timer.reset();
        final artifact = await benchmarkEngines.recognize(
          pair,
          sourceLanguage,
          ComicOcrInput(
            identity: page,
            filePath: resolved.file.path,
            contentDigest: resolved.contentDigest,
            sourceLanguage: sourceLanguage,
            maxAnalysisSide: maxAnalysisSide,
            animatedMode: AnimatedTranslationMode.posterFrame,
          ),
        );
        final ocrTime = timer.elapsed;
        timer.reset();
        final request = ComicTranslationRequest(
          ocr: artifact,
          targetLanguage: targetLanguage,
          previousPages: const [],
        );
        final translation = await benchmarkEngines.translate(pair, request);
        final translatedRegions = request.expandUnitTranslations(translation);
        final unitIds = <String, String>{};
        final unitOrders = <String, int>{};
        final bandIndices = <String, int>{};
        final unitOrientations = <String, ComicTextOrientation>{};
        for (final unit in request.units) {
          for (var band = 0; band < unit.bandRegionIds.length; band++) {
            for (final regionId in unit.bandRegionIds[band]) {
              bandIndices[regionId] = band;
            }
          }
          for (var i = 0; i < unit.regionIds.length; i++) {
            unitIds[unit.regionIds[i]] = unit.id;
            unitOrders[unit.regionIds[i]] = i;
            unitOrientations[unit.regionIds[i]] = unit.orientation;
          }
        }
        final grouping = ComicTextGrouping(
          imageWidth: artifact.imageWidth,
          imageHeight: artifact.imageHeight,
          sourceLanguage: artifact.sourceLanguage,
        );
        final textRegions = artifact.regions.map((region) => ComicTextRegion(
            value: region,
            id: region.id,
            text: region.text,
            polygon: region.polygon,
            sourceMaskPolygons: region.sourceMaskPolygons,
            orientation: region.orientation,
            backgroundArgb: region.backgroundArgb,
            bubbleGroupId: region.bubbleGroupId,
            bubblePolygon: region.bubblePolygon,
          )).toList();
        final relationDiagnostics = diagnoseGrouping
            ? grouping.diagnoseRelations(textRegions, unitIds)
            : const <String>[];
        final candidates = artifact.regions
            .map((region) => region.bubbleCandidatePolygon)
            .whereType<List<NormalizedPoint>>()
            .map((polygon) => _benchmarkPolygon(
              polygon, artifact.imageWidth, artifact.imageHeight,
            )).toList();
        final bubbleBoundaryDiagnostics = !diagnoseGrouping
            ? const <String>[]
            : grouping.resolve(textRegions)
            .map((group) {
          final regions = group.regions.map((region) => region.value).toList();
          final inkBounds = regions.map((region) => _benchmarkInkBounds(
            region, artifact.imageWidth, artifact.imageHeight,
          )).toList();
          final decision = exploreComicBubbleBoundary(
            inkBounds: inkBounds,
            confirmedPolygons: regions
                .map((region) => region.bubblePolygon)
                .whereType<List<NormalizedPoint>>()
                .map((polygon) => _benchmarkPolygon(
                  polygon, artifact.imageWidth, artifact.imageHeight,
                )).toList(),
            candidatePolygons: candidates,
          );
          if (!decision.initialOpen) return null;
          final ids = regions.map((region) =>
              '#${artifact.regions.indexOf(region) + 1}').join(',');
          final boundary = decision.boundaryBounds;
          final ratio = boundary == null
              ? '-'
              : '${(boundary.width / decision.sourceBounds.width).toStringAsFixed(2)}x'
                  '${(boundary.height / decision.sourceBounds.height).toStringAsFixed(2)}';
          var innerRatio = '-';
          var fallback = false;
          final polygons = decision.polygons;
          if (polygons != null) {
            final weights = inkBounds.map((bounds) =>
                math.max(1.0, bounds.width * bounds.height)).toList();
            final totalWeight = weights.reduce((a, b) => a + b);
            final sourceCenter = Offset(
              List.generate(inkBounds.length, (index) =>
                  inkBounds[index].center.dx * weights[index]).reduce((a, b) => a + b) /
                  totalWeight,
              List.generate(inkBounds.length, (index) =>
                  inkBounds[index].center.dy * weights[index]).reduce((a, b) => a + b) /
                  totalWeight,
            );
            var fontWeight = 0.0;
            var fontSum = 0.0;
            for (var index = 0; index < regions.length; index++) {
              final decodedCharacters = math.max(
                1,
                regions[index].text.trim().runes
                    .where((rune) => !String.fromCharCode(rune)
                        .contains(RegExp(r'\s'))).length,
              );
              final bounds = inkBounds[index];
              final vertical = group.orientation ==
                  ComicTextOrientation.vertical;
              final crossExtent = vertical ? bounds.width : bounds.height;
              final mainExtent = vertical ? bounds.height : bounds.width;
              final characters = math.max(
                decodedCharacters,
                (mainExtent / math.max(1, crossExtent)).round(),
              );
              final size = comicTextFontSize(
                crossExtent: crossExtent,
                mainExtent: mainExtent,
                characters: characters,
                bodyContext: true,
              );
              fontSum += size * characters;
              fontWeight += characters;
            }
            final inner = comicBubbleInnerBounds(
              polygons: polygons,
              sourceBounds: decision.sourceBounds,
              sourceCenter: sourceCenter,
              sourceFontSize: fontSum / fontWeight,
            );
            innerRatio =
                '${(inner.width / decision.sourceBounds.width).toStringAsFixed(2)}x'
                '${(inner.height / decision.sourceBounds.height).toStringAsFixed(2)}';
            fallback = inner.width < decision.sourceBounds.width ||
                inner.height < decision.sourceBounds.height;
          }
          return 'u${group.key} regions=$ids open=true '
              'nearbyCandidates=${decision.nearbyCandidates} '
              'formed=${decision.formedBoundary} '
              'source=${decision.source?.name ?? '-'} '
              'relaxed=${decision.relaxed} boundary/source=$ratio '
              'inner/source=$innerRatio fallback=$fallback';
        }).whereType<String>().toList();
        final rssAfter = ProcessInfo.currentRss;
        if (rssAfter > maxObservedRss) maxObservedRss = rssAfter;
        samples.add(ComicTranslationBenchmarkSample(
          identity: page,
          inputResolveTime: inputTime,
          ocrTime: ocrTime,
          translationTime: timer.elapsed,
          ocrMetrics: pair.ocr is ComicOcrEngineDiagnostics
              ? (pair.ocr as ComicOcrEngineDiagnostics).lastRunMetrics
              : null,
          translationMetrics:
              pair.translator is ComicTextTranslationEngineDiagnostics
                  ? (pair.translator as ComicTextTranslationEngineDiagnostics)
                      .lastRunMetrics
                  : null,
          regionCount: artifact.regions.length,
          bubbleCount: artifact.regions
              .map((region) => region.bubbleGroupId)
              .whereType<int>()
              .toSet()
              .length,
          sourceMaskCount: artifact.regions.fold(
            0,
            (count, region) => count + region.sourceMaskPolygons.length,
          ),
          sourceTexts: artifact.regions.map((region) => region.text).toList(),
          sourceConfidences:
              artifact.regions.map((region) => region.confidence).toList(),
          bubbleGroupIds:
              artifact.regions.map((region) => region.bubbleGroupId).toList(),
          bubbleCandidateAvailable: artifact.regions
              .map((region) => region.bubbleCandidatePolygon != null)
              .toList(),
          translationUnitIds:
              artifact.regions.map((region) => unitIds[region.id]).toList(),
          translationUnitOrders:
              artifact.regions.map((region) => unitOrders[region.id]).toList(),
          translationBandIndices:
              artifact.regions.map((region) => bandIndices[region.id]).toList(),
          translationUnitOrientations: artifact.regions
              .map((region) => unitOrientations[region.id]).toList(),
          relationDiagnostics: relationDiagnostics,
          bubbleBoundaryDiagnostics: bubbleBoundaryDiagnostics,
          translatedTexts: artifact.regions
              .map((region) => translatedRegions[region.id]!)
              .toList(),
          rssBefore: rssBefore,
          rssAfter: rssAfter,
        ));
      }
    } finally {
      await benchmarkEngines.release(pair);
    }
    return ComicTranslationBenchmarkResult(
      ocrLoadTime: ocrLoad,
      translationLoadTime: translationLoad,
      translationMeasured: translationMeasured,
      samples: samples,
      rssBeforeLoad: rssBeforeLoad,
      rssAfterLoad: rssAfterLoad,
      maxObservedRss: maxObservedRss,
      rssAfterRelease: ProcessInfo.currentRss,
    );
  }
}

List<Offset> _benchmarkPolygon(
  List<NormalizedPoint> polygon,
  int width,
  int height,
) => polygon.map((point) => Offset(point.x * width, point.y * height)).toList();

Rect _benchmarkInkBounds(ComicOcrRegion region, int width, int height) {
  final points = region.sourceMaskPolygons
      .expand((polygon) => polygon)
      .toList();
  return _benchmarkBounds(
    points.isEmpty ? region.polygon : points,
    width,
    height,
  );
}

Rect _benchmarkBounds(List<NormalizedPoint> points, int width, int height) =>
    Rect.fromLTRB(
      points.map((point) => point.x * width).reduce((a, b) => a < b ? a : b),
      points.map((point) => point.y * height).reduce((a, b) => a < b ? a : b),
      points.map((point) => point.x * width).reduce((a, b) => a > b ? a : b),
      points.map((point) => point.y * height).reduce((a, b) => a > b ? a : b),
    );

final class _BenchmarkNoopTranslationEngine
    implements ComicTextTranslationEngine {
  const _BenchmarkNoopTranslationEngine();

  @override
  ComicTranslationContextMode get contextMode =>
      ComicTranslationContextMode.none;

  @override
  ComicTranslationEngineIdentity identityFor(
    ComicTranslationRequest request,
  ) => const ComicTranslationEngineIdentity(
    id: 'benchmark-noop',
    modelVersion: '1',
  );

  @override
  Future<void> load() async {}

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async => ComicTranslationResult({
    for (final unit in request.units) unit.id: unit.sourceLines,
  });

  @override
  Future<void> unload() async {}
}
