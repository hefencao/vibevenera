import 'dart:async';

import 'package:flutter/foundation.dart';

import '../session/download_session.dart';

final class CacheDownloadProgress {
  final DownloadIdentity identity;
  final DownloadTransportState transport;
  final int rank;
  final int currentBytes;
  final int? totalBytes;
  final double speedBytesPerSecond;

  const CacheDownloadProgress({
    required this.identity,
    required this.transport,
    required this.rank,
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
  Timer? _publishTimer;
  bool _publishScheduled = false;
  bool _disposed = false;
  int _lastNotifyMs = 0;
  static const int _progressPublishIntervalMs = 500;

  void observe(DownloadSession session) {
    if (_subscriptions.containsKey(session.identity)) return;
    _subscriptions[session.identity] = session.watch().listen(
      (snapshot) => _update(session.identity, snapshot),
      onDone: () {
        _subscriptions.remove(session.identity);
        _items.remove(session.identity);
        _samples.remove(session.identity);
        _requestPublish(immediate: true);
      },
    );
  }

  void _update(DownloadIdentity identity, DownloadSessionSnapshot snapshot) {
    final transport = snapshot.transport;
    final demanded = snapshot.demandCount > 0;
    final visible = switch (transport) {
      DownloadTransportState.receiving => snapshot.networkActive,
      DownloadTransportState.queued || DownloadTransportState.paused =>
        snapshot.networkActive && demanded,
      DownloadTransportState.failed => demanded,
      DownloadTransportState.idle || DownloadTransportState.sealed => false,
    };
    if (!visible) {
      _samples.remove(identity);
      if (_items.remove(identity) != null) {
        _requestPublish(immediate: true);
      }
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
    final previousItem = _items[identity];
    final rank = snapshot.desiredPriority;
    _items[identity] = CacheDownloadProgress(
      identity: identity,
      transport: transport,
      rank: rank,
      currentBytes: snapshot.committedLength,
      totalBytes: snapshot.expectedLength > 0 ? snapshot.expectedLength : null,
      speedBytesPerSecond: speed,
    );
    _requestPublish(
      immediate: previousItem?.transport != transport || _orderChanged(),
    );
  }

  void _requestPublish({bool immediate = false}) {
    if (_disposed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (immediate || now - _lastNotifyMs >= _progressPublishIntervalMs) {
      _publishTimer?.cancel();
      _publishTimer = null;
      if (_publishScheduled) return;
      _publishScheduled = true;
      scheduleMicrotask(() {
        _publishScheduled = false;
        if (!_disposed) _publish();
      });
      return;
    }
    _publishTimer ??= Timer(
      Duration(
        milliseconds: _progressPublishIntervalMs - (now - _lastNotifyMs),
      ),
      () {
        _publishTimer = null;
        _requestPublish(immediate: true);
      },
    );
  }

  void _publish() {
    _lastNotifyMs = DateTime.now().millisecondsSinceEpoch;
    notifier.value = List.unmodifiable(_sortedItems());
  }

  bool _orderChanged() {
    final current = notifier.value;
    final next = _sortedItems();
    if (current.length != next.length) return true;
    for (var i = 0; i < current.length; i++) {
      if (current[i].identity != next[i].identity) return true;
    }
    return false;
  }

  List<CacheDownloadProgress> _sortedItems() => _items.values.toList()
    ..sort((a, b) {
      final rank = b.rank.compareTo(a.rank);
      return rank != 0
          ? rank
          : a.identity.cacheKey.compareTo(b.identity.cacheKey);
    });

  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _items.clear();
    _samples.clear();
    _publishTimer?.cancel();
    notifier.dispose();
  }
}

final class _ProgressSample {
  final int bytes;
  final int ms;
  final double speed;

  const _ProgressSample(this.bytes, this.ms, this.speed);
}
