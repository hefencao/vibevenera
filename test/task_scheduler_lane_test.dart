import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/task_scheduler.dart';
import 'package:venera/foundation/image_provider/pipeline/tasks.dart';

void main() {
  test('network saturation does not delay decode lane', () async {
    final scheduler = TaskScheduler.instance;
    scheduler.clear();
    scheduler.setNetworkConcurrency(5);
    // network lane maxConcurrent=5：塞 6 个饱和该 lane，第 6 个应排队；同时另一 lane
    // 的 decode 不受网络饱和影响，立即起。
    final network = List.generate(
      6,
      (index) => _BlockingTask('network-$index', SchedulerLane.network),
    );
    final decode = _BlockingTask('decode', SchedulerLane.decode);

    for (final task in network) {
      scheduler.submit(task);
    }
    scheduler.submit(decode);
    await Future.wait([
      network[0].started.future,
      network[1].started.future,
      network[2].started.future,
      network[3].started.future,
      network[4].started.future,
      decode.started.future,
    ]);

    expect(network[5].started.isCompleted, isFalse);
    expect(decode.started.isCompleted, isTrue);

    for (final task in [...network, decode]) {
      task.release.complete();
    }
    await Future<void>.delayed(Duration.zero);
    scheduler.clear();
  });
}

final class _BlockingTask extends SchedulerTask {
  @override
  final SchedulerLane lane;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  _BlockingTask(String key, this.lane)
    : super(key: key, generation: 1, priority: 1, cancelable: true);

  @override
  void execute() async {
    started.complete();
    await release.future;
    if (!isCancelled) notifyCompleted();
  }
}
