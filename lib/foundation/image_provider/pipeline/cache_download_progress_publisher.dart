import 'dart:async';

import 'package:flutter/foundation.dart';

import '../session/download_session.dart';

final class CacheDownloadProgress {
  final DownloadIdentity identity;
  final DownloadTransportState transport;
  final int priority;
  final int currentBytes;
  final int? totalBytes;
  final double speedBytesPerSecond;

  const CacheDownloadProgress({
    required this.identity,
    required this.transport,
    required this.priority,
    required this.currentBytes,
    required this.totalBytes,
    required this.speedBytesPerSecond,
  });

  double get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return 0;
    return (currentBytes / total).clamp(0.0, 1.0);
  }

  String get label {
    final path = identity.imageKey.split('?').first;
    return path.substring(path.lastIndexOf('/') + 1);
  }
}

/// Projects active WebP cache transports for UI without changing session demand.
final class CacheDownloadProgressPublisher {
  final notifier = ValueNotifier<List<CacheDownloadProgress>>(const []);
  final _subscriptions = <DownloadIdentity, StreamSubscription>{};
  final _items = <DownloadIdentity, CacheDownloadProgress>{};
  final _samples = <DownloadIdentity, _ProgressSample>{};
  int _lastNotifyMs = 0;

  void observe(DownloadSession session) {
    if (_subscriptions.containsKey(session.identity)) return;
    _subscriptions[session.identity] = session.watch().listen(
      (snapshot) => _update(session.identity, snapshot),
      onDone: () {
        _subscriptions.remove(session.identity);
        _items.remove(session.identity);
        _samples.remove(session.identity);
        _publish(force: true);
      },
    );
  }

  void _update(DownloadIdentity identity, DownloadSessionSnapshot snapshot) {
    final transport = snapshot.transport;
    final visible = switch (transport) {
      DownloadTransportState.queued ||
      DownloadTransportState.receiving ||
      DownloadTransportState.paused => true,
      DownloadTransportState.failed => snapshot.failureRetryable,
      DownloadTransportState.idle || DownloadTransportState.sealed => false,
    };
    if (!visible) {
      if (_items.remove(identity) != null) _publish(force: true);
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = _samples[identity];
    var speed = previous?.speed ?? 0.0;
    if (previous != null && now > previous.ms &&
        snapshot.committedLength >= previous.bytes) {
      final instant =
          (snapshot.committedLength - previous.bytes) * 1000.0 / (now - previous.ms);
      speed = speed <= 0 ? instant : speed * 0.7 + instant * 0.3;
    } else if (previous != null && snapshot.committedLength < previous.bytes) {
      speed = 0;
    }
    _samples[identity] = _ProgressSample(snapshot.committedLength, now, speed);
    _items[identity] = CacheDownloadProgress(
      identity: identity,
      transport: transport,
      priority: snapshot.desiredPriority,
      currentBytes: snapshot.committedLength,
      totalBytes: snapshot.expectedLength > 0 ? snapshot.expectedLength : null,
      speedBytesPerSecond: speed,
    );
    _publish(force: transport != DownloadTransportState.receiving);
  }

  void _publish({bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastNotifyMs < 500) return;
    _lastNotifyMs = now;
    final items = _items.values.toList()
      ..sort((a, b) {
        final priority = b.priority.compareTo(a.priority);
        return priority != 0 ? priority : a.identity.cacheKey.compareTo(b.identity.cacheKey);
      });
    notifier.value = List.unmodifiable(items);
  }

  void dispose() {
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _items.clear();
    _samples.clear();
    notifier.dispose();
  }
}

final class _ProgressSample {
  final int bytes;
  final int ms;
  final double speed;

  const _ProgressSample(this.bytes, this.ms, this.speed);
}
