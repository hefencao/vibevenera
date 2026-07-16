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
  final int regionCount;
  final int bubbleCount;
  final int sourceMaskCount;
  final List<String> sourceTexts;
  final List<double> sourceConfidences;
  final List<String> translatedTexts;
  final int rssBefore;
  final int rssAfter;

  const ComicTranslationBenchmarkSample({
    required this.identity,
    required this.inputResolveTime,
    required this.ocrTime,
    required this.translationTime,
    required this.ocrMetrics,
    required this.regionCount,
    required this.bubbleCount,
    required this.sourceMaskCount,
    required this.sourceTexts,
    required this.sourceConfidences,
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
        final translation = await pair.translator.translate(ComicTranslationRequest(
          ocr: artifact,
          targetLanguage: targetLanguage,
          previousPages: const [],
        ));
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
          regionCount: artifact.regions.length,
          bubbleCount:
              artifact.regions.where((region) => region.bubblePolygon != null).length,
          sourceMaskCount: artifact.regions.fold(
            0,
            (count, region) => count + region.sourceMaskPolygons.length,
          ),
          sourceTexts: artifact.regions.map((region) => region.text).toList(),
          sourceConfidences:
              artifact.regions.map((region) => region.confidence).toList(),
          translatedTexts: artifact.regions
              .map((region) => translation.translations[region.id]!)
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
    for (final region in request.ocr.regions) region.id: region.text,
  });

  @override
  Future<void> unload() async {}
}
