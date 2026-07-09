import 'package:flutter/foundation.dart';

import 'resource_entry.dart';

class DownloadProgressPublisher {
  final notifier = ValueNotifier<ReaderDownloadProgress>(
    const ReaderDownloadProgress.idle(),
  );
  final Map<String, _ProgressSample> _samples = {};
  int _lastNotifyMs = 0;

  void complete(String imageKey, String currentKey) {
    _samples.remove(imageKey);
    if (imageKey == currentKey) notifier.value = const ReaderDownloadProgress.idle();
  }

  void update(
    String imageKey,
    int current,
    int? total, {
    required String currentKey,
    bool done = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _samples[imageKey];
    var speed = old?.speed ?? 0.0;
    if (old != null && now > old.ms && current >= old.bytes) {
      final instant = (current - old.bytes) * 1000.0 / (now - old.ms);
      speed = speed <= 0 ? instant : speed * 0.7 + instant * 0.3;
    } else if (old != null && current < old.bytes) {
      speed = 0;
    }
    _samples[imageKey] = _ProgressSample(current, now, speed);
    if (imageKey != currentKey) return;
    final complete = done || (total != null && total > 0 && current >= total);
    if (complete) {
      notifier.value = const ReaderDownloadProgress.idle();
      return;
    }
    if (now - _lastNotifyMs < 100 && current > 0) return;
    _lastNotifyMs = now;
    notifier.value = ReaderDownloadProgress(
      imageKey: imageKey,
      active: true,
      currentBytes: current,
      totalBytes: total,
      speedBytesPerSecond: speed,
    );
  }

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
    notifier.value = const ReaderDownloadProgress.idle();
  }
}

class _ProgressSample {
  int bytes;
  int ms;
  double speed;
  _ProgressSample(this.bytes, this.ms, this.speed);
}