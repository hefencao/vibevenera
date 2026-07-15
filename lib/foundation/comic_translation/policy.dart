enum ComicTranslationInteraction { idle, dragging, settling, scrolling, jumping }

final class ComicTranslationPolicy {
  final Duration dragSubmissionDelay;
  final int prefetchPages;
  final int maxAnalysisSide;
  final int contextPages;

  const ComicTranslationPolicy({
    this.dragSubmissionDelay = const Duration(milliseconds: 180),
    this.prefetchPages = 1,
    this.maxAnalysisSide = 1600,
    this.contextPages = 2,
  });

  Duration submissionDelay(ComicTranslationInteraction interaction) =>
      switch (interaction) {
        ComicTranslationInteraction.dragging ||
        ComicTranslationInteraction.scrolling => dragSubmissionDelay,
        _ => Duration.zero,
      };

  int priority({required int distance, required bool current}) =>
      current ? 1000 : 500 - distance;
}
