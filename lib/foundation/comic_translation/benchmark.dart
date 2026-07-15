import 'dart:io';

import 'engine.dart';
import 'input_resolver.dart';
import 'models.dart';

final class ComicTranslationBenchmarkSample {
  final ComicTranslationPageIdentity identity;
  final Duration inputResolveTime;
  final Duration ocrTime;
  final Duration translationTime;
  final int regionCount;
  final int rssBefore;
  final int rssAfter;

  const ComicTranslationBenchmarkSample({
    required this.identity,
    required this.inputResolveTime,
    required this.ocrTime,
    required this.translationTime,
    required this.regionCount,
    required this.rssBefore,
    required this.rssAfter,
  });
}

final class ComicTranslationBenchmarkResult {
  final Duration ocrLoadTime;
  final Duration translationLoadTime;
  final bool translationMeasured;
  final List<ComicTranslationBenchmarkSample> samples;

  const ComicTranslationBenchmarkResult({
    required this.ocrLoadTime,
    required this.translationLoadTime,
    required this.translationMeasured,
    required this.samples,
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
    try {
      final timer = Stopwatch()..start();
      await benchmarkEngines.loadOcr(pair);
      final ocrLoad = timer.elapsed;
      timer.reset();
      await benchmarkEngines.loadTranslator(pair);
      final translationLoad = timer.elapsed;
      final samples = <ComicTranslationBenchmarkSample>[];
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
        await pair.translator.translate(ComicTranslationRequest(
          ocr: artifact,
          targetLanguage: targetLanguage,
          previousPages: const [],
        ));
        samples.add(ComicTranslationBenchmarkSample(
          identity: page,
          inputResolveTime: inputTime,
          ocrTime: ocrTime,
          translationTime: timer.elapsed,
          regionCount: artifact.regions.length,
          rssBefore: rssBefore,
          rssAfter: ProcessInfo.currentRss,
        ));
      }
      return ComicTranslationBenchmarkResult(
        ocrLoadTime: ocrLoad,
        translationLoadTime: translationLoad,
        translationMeasured: translationMeasured,
        samples: samples,
      );
    } finally {
      await benchmarkEngines.release(pair);
    }
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
