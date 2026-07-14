import 'dart:math';

final class ReadingDirectionPredictor {
  int _direction = 1;
  int _candidateDirection = 0;
  int _candidateCount = 0;
  int? _lastChangeMs;

  // 历史样本：使用指数衰减权重
  final List<_DirectionSample> _history = [];

  int get direction => _direction;

  static const int _maxHistory = 12;
  static const int _dwellShort = 400;
  static const int _dwellMedium = 2000;
  static const double _decayFactor = 0.85; // 每步衰减

  void reset({int direction = 1, int? nowMs}) {
    _direction = direction < 0 ? -1 : 1;
    _candidateDirection = 0;
    _candidateCount = 0;
    _lastChangeMs = nowMs;
    _history.clear();
  }

  int record(int delta, int nowMs, {bool directional = true}) {
    // 非 directional 或大跳跃：不学习方向，但更新时间戳以保持 dwell 连续性
    if (!directional || delta.abs() > 5) {  // 放宽到 ±5 避免小跳干扰
      _candidateDirection = 0;
      _candidateCount = 0;
      // 仍更新时间戳，避免下一次正常 move 被污染
      _lastChangeMs = nowMs;
      return _direction;
    }

    final dwellMs = _lastChangeMs == null ? 0 : (nowMs - _lastChangeMs!).clamp(0, 10000);
    _lastChangeMs = nowMs;

    final movement = delta < 0 ? -1 : 1;
    final baseWeight = dwellMs >= _dwellMedium
        ? 4
        : dwellMs >= _dwellShort
            ? 2
            : 1;

    _history.add(_DirectionSample(movement, baseWeight));

    // 保留最近 N 个 + 衰减旧样本
    if (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
    _applyDecay();

    // === 快速候选切换 ===
    if (movement == _direction) {
      _candidateDirection = 0;
      _candidateCount = 0;
    } else {
      if (_candidateDirection == movement) {
        _candidateCount++;
      } else {
        _candidateDirection = movement;
        _candidateCount = 1;
      }

      // 连续 2 次反向 + 至少一次有权重，立即切换
      if (_candidateCount >= 2) {
        _direction = movement;
        _candidateDirection = 0;
        _candidateCount = 0;
        return _direction;
      }
    }

    // === 趋势判断（加权 + 衰减）===
    int trend = 0;
    for (final sample in _history) {
      trend += sample.direction * sample.weight;
    }

    // 动态阈值：至少需要一定历史强度
    final totalWeight = _history.fold<int>(0, (sum, s) => sum + s.weight);
    final threshold = (totalWeight / 3).ceil().clamp(3, 6);

    if (trend.abs() >= threshold) {
      final newDir = trend > 0 ? 1 : -1;
      if (newDir != _direction) {
        _direction = newDir;
        _candidateDirection = 0;
        _candidateCount = 0;
      }
    }

    return _direction;
  }

  void _applyDecay() {
    for (int i = 0; i < _history.length; i++) {
      final age = _history.length - 1 - i; // 越新 age 越小
      _history[i] = _DirectionSample(
        _history[i].direction,
        (_history[i].weight * pow(_decayFactor, age)).round().clamp(1, 5),
      );
    }
  }
}

final class _DirectionSample {
  final int direction;
  final int weight;
  const _DirectionSample(this.direction, this.weight);
}

// 需要 import 'dart:math'; 用于 pow