part of '../webp_image.dart';

double webpPlaybackSpeed = 1.0;
const List<double> webpSpeedPresets = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

final _clock = Stopwatch()..start();
int _nowMs() => _clock.elapsedMilliseconds;

String _short(String key) {
  final end = key.indexOf('@');
  final s = end < 0 ? key : key.substring(0, end);
  final slash = s.lastIndexOf('/');
  final bslash = s.lastIndexOf('\\');
  final start = (slash > bslash ? slash : bslash) + 1;
  final name = s.substring(start);
  if (name.length >= 2 &&
      name.codeUnitAt(0) >= 0x30 &&
      name.codeUnitAt(0) <= 0x39) {
    final digits = name.split('.').first;
    return digits.length <= 4
        ? '$digits.webp'
        : '${digits.substring(digits.length - 4)}.webp';
  }
  return name;
}

enum PageState { current, next, last, precache }

PageState _priorityToPageState(PagePriority p) {
  switch (p) {
    case PagePriority.current:
      return PageState.current;
    case PagePriority.near:
      return PageState.next;
    case PagePriority.far:
    case PagePriority.keep:
    case PagePriority.distant:
      return PageState.precache;
  }
}

// ═══════════════════════════════════════════════════════════════
// 1. BufferedFrame
// ═══════════════════════════════════════════════════════════════

class BufferedFrame {
  final ui.Image image;
  final int durationMs;
  BufferedFrame(this.image, this.durationMs);
}

// ═══════════════════════════════════════════════════════════════
// 2. DecoderHolder — pure decoder wrapper
//
// [FIX] No longer knows about DecoderManager, WorkerPoolScheduler,
// or generation counters. Decode is driven externally by
// [HolderDecodeService].
// ═══════════════════════════════════════════════════════════════
