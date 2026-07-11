import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/scheduler.dart';

import 'package:venera/foundation/log.dart';

/// Lightweight, strippable instrumentation for the WebP reader pipeline.
///
/// Goal: find where a page switch spends UI-isolate time and where jank frames
/// come from, without a profiler build. Every measurement is grouped into a
/// "swipe epoch" (bumped on each reader page change), and a compact summary is
/// logged when the next epoch starts.
///
/// To disable ALL overhead, set [enabled] to false — every hook becomes a
/// no-op (the `sync`/`slice` bodies still run, but no timing/logging happens),
/// and the whole file can be deleted once diagnosis is done.
class WebPPerf {
  WebPPerf._();

  /// Master switch. Flip to false to make every probe a no-op.
  static bool enabled = true;

  /// When true, also emits Dart Timeline slices (visible in DevTools timeline
  /// / `flutter run --profile` timeline). Cheap but not free; keep on while
  /// diagnosing.
  static bool timeline = true;

  static int _epoch = 0;
  static int get epoch => _epoch;

  static final Map<String, _Stat> _stats = {};
  static int _epochStartMs = 0;

  // Jank tracking (raster+build over budget) within the current epoch.
  static int _jankFrames = 0;
  static int _maxFrameMs = 0;
  static bool _timingsHooked = false;
  static const int _frameBudgetMs = 17; // ~60fps; anything above drops a frame.

  /// Periodic live dump so a crash-on-entry (before any page change) still
  /// leaves a trail. Dumps the CURRENT epoch's accumulating stats without
  /// resetting them.
  static Timer? _liveTimer;
  static const Duration _livePeriod = Duration(milliseconds: 700);

  /// Begin a new swipe epoch. Dumps the previous epoch's summary first.
  /// [label] is usually the page index, e.g. "page 42".
  static void markPageChange(String label) {
    if (!enabled) return;
    _ensureTimingsHook();
    _dumpEpoch(reason: 'page-change -> $label');
    _epoch++;
    _stats.clear();
    _jankFrames = 0;
    _maxFrameMs = 0;
    _epochStartMs = DateTime.now().millisecondsSinceEpoch;
    if (timeline) {
      developer.Timeline.instantSync('WebP.swipe', arguments: {'to': label});
    }
  }

  /// Measure a synchronous block. Returns the block's value.
  static T sync<T>(String name, T Function() body) {
    if (!enabled) return body();
    final sw = Stopwatch()..start();
    if (timeline) developer.Timeline.startSync(name);
    try {
      return body();
    } finally {
      if (timeline) developer.Timeline.finishSync();
      sw.stop();
      _record(name, sw.elapsedMicroseconds);
    }
  }

  /// Record a single event occurrence with an optional duration in microseconds.
  /// Use for async-completed work (e.g. a GPU upload callback) where wrapping a
  /// sync block is not possible.
  static void event(String name, {int micros = 0}) {
    if (!enabled) return;
    _record(name, micros);
  }

  /// Count an occurrence with no duration (e.g. "native cursor created").
  static void count(String name) {
    if (!enabled) return;
    _record(name, 0);
  }

  static void _record(String name, int micros) {
    final stat = _stats[name] ??= _Stat();
    stat.count++;
    stat.totalMicros += micros;
    if (micros > stat.maxMicros) stat.maxMicros = micros;
  }

  static void _ensureTimingsHook() {
    if (_timingsHooked) return;
    _timingsHooked = true;
    SchedulerBinding.instance.addTimingsCallback((timings) {
      if (!enabled) return;
      for (final t in timings) {
        final totalMs = (t.totalSpan.inMicroseconds / 1000).round();
        if (totalMs > _maxFrameMs) _maxFrameMs = totalMs;
        if (t.totalSpan.inMilliseconds > _frameBudgetMs) _jankFrames++;
      }
    });
    _liveTimer ??= Timer.periodic(_livePeriod, (_) {
      if (!enabled || _epochStartMs == 0) return;
      _dumpEpoch(reason: 'live', keepStats: true);
    });
  }

  static void _dumpEpoch({required String reason, bool keepStats = false}) {
    if (_epochStartMs == 0) return; // first call, nothing to dump yet
    final wallMs = DateTime.now().millisecondsSinceEpoch - _epochStartMs;
    final buf = StringBuffer()
      ..write('[$reason] epoch=$_epoch wall=${wallMs}ms ')
      ..write('jankFrames=$_jankFrames maxFrame=${_maxFrameMs}ms | ');
    if (_stats.isEmpty) {
      buf.write('(no probes fired)');
    } else {
      final entries = _stats.entries.toList()
        ..sort((a, b) => b.value.totalMicros.compareTo(a.value.totalMicros));
      buf.write(
        entries
            .map((e) => '${e.key} x${e.value.count} '
                'sum=${e.value.totalMs}ms max=${e.value.maxMs}ms')
            .join('  '),
      );
    }
    // Use warning level so the line reaches logcat/console in profile & release
    // builds too (info is debug-only per Log.addLog). This is diagnostic output,
    // not a real warning.
    Log.warning('WebP.Perf', buf.toString());
  }
}

class _Stat {
  int count = 0;
  int totalMicros = 0;
  int maxMicros = 0;

  String get totalMs => (totalMicros / 1000).toStringAsFixed(1);
  String get maxMs => (maxMicros / 1000).toStringAsFixed(1);
}
