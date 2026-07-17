import 'dart:io';

import 'engine.dart';
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
  final List<String?> translationUnitIds;
  final List<int?> translationUnitOrders;
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
    required this.translationUnitIds,
    required this.translationUnitOrders,
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
  }) async {
    final translationMeasured = engines.translationEngine != null;
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
        final artifact = await pair.ocr.recognize(ComicOcrInput(
          identity: page,
          filePath: resolved.file.path,
          contentDigest: resolved.contentDigest,
          sourceLanguage: sourceLanguage,
          maxAnalysisSide: maxAnalysisSide,
          animatedMode: AnimatedTranslationMode.posterFrame,
        ));
        final ocrTime = timer.elapsed;
        timer.reset();
        final request = ComicTranslationRequest(
          ocr: artifact,
          targetLanguage: targetLanguage,
          previousPages: const [],
        );
        final translation = await pair.translator.translate(request);
        final translatedRegions = request.expandUnitTranslations(translation);
        final unitIds = <String, String>{};
        final unitOrders = <String, int>{};
        for (final unit in request.units) {
          for (var i = 0; i < unit.regionIds.length; i++) {
            unitIds[unit.regionIds[i]] = unit.id;
            unitOrders[unit.regionIds[i]] = i;
          }
        }
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
          translationUnitIds:
              artifact.regions.map((region) => unitIds[region.id]).toList(),
          translationUnitOrders:
              artifact.regions.map((region) => unitOrders[region.id]).toList(),
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

final class _BenchmarkNoopTranslationEngine
    implements ComicTextTranslationEngine {
  const _BenchmarkNoopTranslationEngine();

  @override
  String get id => 'benchmark-noop';

  @override
  String get modelVersion => '1';

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
