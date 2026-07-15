import 'dart:math' as math;

import 'resource_entry.dart';

class DownloadRanker {
  final int runningDownloads;
  final int queuedDownloads;
  final int maxConcurrent;
  final int readDirection;
  final int Function(String imageKey) offsetFor;

  const DownloadRanker({
    required this.runningDownloads,
    required this.queuedDownloads,
    required this.maxConcurrent,
    required this.readDirection,
    required this.offsetFor,
  });

  int rank(ResourceEntry entry, {PagePriority? priority}) {
    final p = priority ?? entry.priority;
    final offset = offsetFor(entry.imageKey);
    final readDistance = offset * readDirection;
    final distance = offset.abs();
    final progress = entry.download.progress;
    final p2 = progress * progress;
    final progressBoost = (progress * 32 + p2 * 160 + p2 * p2 * 260).round();
    final freeSlots = math.max(0, maxConcurrent - runningDownloads);
    final inProgressBoost = entry.download.inProgress ? 80 + freeSlots * 16 : 0;
    final pressure = runningDownloads + queuedDownloads;
    final hasPressure = pressure >= maxConcurrent;
    final pressurePenalty = p == PagePriority.distant && hasPressure
        ? (pressure - maxConcurrent + 1) * 24
        : 0;
    final base = switch (p) {
      PagePriority.current => 1000,
      PagePriority.transition => 880,
      PagePriority.near when readDistance > 0 => 760,
      PagePriority.near => 720,
      PagePriority.far when readDistance > 0 => 520,
      PagePriority.far => 500,
      PagePriority.keep => 260,
      PagePriority.distant when entry.download.inProgress => 180,
      PagePriority.distant => 0,
    };
    if (base == 0) return 0;
    final directionBias = readDistance < 0 ? -8 : 0;
    final raw = base -
        distance * 12 +
        directionBias +
        inProgressBoost +
        progressBoost -
        pressurePenalty;
    final cap = switch (p) {
      PagePriority.current => 2000,
      PagePriority.transition => 1100,
      PagePriority.near when readDistance > 0 => 940,
      PagePriority.near => 900,
      PagePriority.far when readDistance > 0 => 700,
      PagePriority.far => 680,
      PagePriority.keep => 660,
      PagePriority.distant => 660,
    };
    return raw.clamp(1, cap).toInt();
  }
}
