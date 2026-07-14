import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/reading_direction_predictor.dart';

void main() {
  // ... 原有测试保持不变（single backward peek, two consecutive, large jumps 等）

  test('weighted history resolves irregular navigation', () {
    final predictor = ReadingDirectionPredictor()..reset(nowMs: 0);
    expect(predictor.record(-1, 2500), 1);
    expect(predictor.record(1, 2600), 1);
    expect(predictor.record(-1, 5100), 1);
    expect(predictor.record(1, 5200), 1);
    expect(predictor.record(-1, 7700), -1); // 趋势主导
  });

  test('reversal does not clear history, allows quick recovery', () {
    final predictor = ReadingDirectionPredictor()..reset(nowMs: 0);
    // 建立前进惯性
    predictor.record(1, 3000);
    predictor.record(1, 6000);
    // 反转
    predictor.record(-1, 8000);
    predictor.record(-1, 10000);
    expect(predictor.direction, -1);
    // 高权重前进快速恢复
    predictor.record(1, 15000); // 长 dwell
    expect(predictor.direction, 1);
  });

  test('large jump does not affect dwell time', () {
    final predictor = ReadingDirectionPredictor()..reset(nowMs: 0);
    predictor.record(1, 1000);
    predictor.record(50, 1100); // 跳转
    predictor.record(-1, 1300); // dwell ~300ms，低权重
    expect(predictor.direction, 1);
  });

  test('random small jitter does not flip direction', () {
    final predictor = ReadingDirectionPredictor()..reset(nowMs: 0);
    for (int i = 0; i < 10; i++) {
      predictor.record(i % 2 == 0 ? 1 : -1, 1000 + i * 200);
    }
    expect(predictor.direction, 1); // 保持稳定
  });

  // 新增稳定性测试
  test('long reading stabilizes direction strongly', () {
    final predictor = ReadingDirectionPredictor()..reset(nowMs: 0);
    for (int i = 0; i < 6; i++) {
      predictor.record(1, 10000 + i * 3000); // 长 dwell
    }
    expect(predictor.direction, 1);
    // 轻微后退不应翻转
    predictor.record(-1, 30000);
    expect(predictor.direction, 1);
  });
}