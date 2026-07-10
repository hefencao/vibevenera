import 'package:flutter/foundation.dart';

import '../session/download_session.dart';
import 'resource_entry.dart';

/// Publishes download progress for the page that is current *now*.
///
/// Samples are keyed by the complete download identity instead of imageKey so
/// the same URL reused by another source/chapter cannot inherit stale speed or
/// byte counts. [ReaderDownloadProgress.imageKey] remains the public UI key.
class DownloadProgressPublisher {
  final notifier = ValueNotifier<ReaderDownloadProgress>(
    const ReaderDownloadProgress.idle(),
  );

  final Map<String, _ProgressSample> _samples = {};
  int _lastNotifyMs = 0;

  void complete(String imageKey, String currentKey, {String? progressKey}) {
    _samples.remove(progressKey ?? imageKey);
    if (imageKey == currentKey) {
      notifier.value = const ReaderDownloadProgress.idle();
    }
  }

  void update(
    String imageKey,
    int current,
    int? total, {
    required String currentKey,
    String? progressKey,
    bool done = false,
  }) {
    final sampleKey = progressKey ?? imageKey;
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _samples[sampleKey];

    var speed = old?.speed ?? 0.0;
    if (old != null && now > old.ms && current >= old.bytes) {
      final instant = (current - old.bytes) * 1000.0 / (now - old.ms);
      speed = speed <= 0 ? instant : speed * 0.7 + instant * 0.3;
    } else if (old != null && current < old.bytes) {
      // Reset/source switch. Never carry the previous epoch's speed forward.
      speed = 0;
    }
    _samples[sampleKey] = _ProgressSample(current, now, speed);

    if (imageKey != currentKey) return;

    final normalizedTotal = total != null && total > 0 ? total : null;
    final complete =
        done || (normalizedTotal != null && current >= normalizedTotal);
    if (complete) {
      notifier.value = const ReaderDownloadProgress.idle();
      return;
    }

    // Progress events may arrive for every network chunk. Throttle UI updates,
    // but current-page switches use [syncCurrentSession] and are immediate.
    if (now - _lastNotifyMs < 100 && current > 0) return;
    _lastNotifyMs = now;
    notifier.value = ReaderDownloadProgress(
      imageKey: imageKey,
      active: true,
      currentBytes: current,
      totalBytes: normalizedTotal,
      speedBytesPerSecond: speed,
    );
  }

  /// Immediately projects an already-running retained DownloadSession when the
  /// current page changes. This prevents the previous page's progress from
  /// remaining visible until the new session emits its next network chunk.
  void syncCurrentSession({
    required String imageKey,
    required String progressKey,
    required DownloadSessionSnapshot? snapshot,
  }) {
    if (imageKey.isEmpty || snapshot == null) {
      notifier.value = const ReaderDownloadProgress.idle();
      return;
    }

    final active = switch (snapshot.transport) {
      DownloadTransportState.queued ||
      DownloadTransportState.receiving ||
      DownloadTransportState.paused => true,
      DownloadTransportState.failed => snapshot.failureRetryable,
      DownloadTransportState.idle || DownloadTransportState.sealed => false,
    };

    if (!active) {
      notifier.value = const ReaderDownloadProgress.idle();
      return;
    }

    final sample = _samples[progressKey];
    final total = snapshot.expectedLength > 0 ? snapshot.expectedLength : null;
    notifier.value = ReaderDownloadProgress(
      imageKey: imageKey,
      active: true,
      currentBytes: snapshot.committedLength,
      totalBytes: total,
      speedBytesPerSecond: sample?.speed ?? 0,
    );
  }

  /// Compatibility projection for the legacy ResourceEntry pipeline.
  void syncCurrent(String currentKey, ResourceEntry? entry) {
    if (entry == null || entry.hasBytes || !entry.download.inProgress) {
      notifier.value = const ReaderDownloadProgress.idle();
      return;
    }
    final sample = _samples[currentKey];
    notifier.value = ReaderDownloadProgress(
      imageKey: currentKey,
      active: true,
      currentBytes: entry.download.currentBytes,
      totalBytes: entry.download.totalBytes,
      speedBytesPerSecond: sample?.speed ?? 0,
    );
  }

  void reset() {
    _samples.clear();
    _lastNotifyMs = 0;
    notifier.value = const ReaderDownloadProgress.idle();
  }
}

class _ProgressSample {
  int bytes;
  int ms;
  double speed;

  _ProgressSample(this.bytes, this.ms, this.speed);
}
