import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/task_scheduler.dart';
import 'package:venera/foundation/image_provider/pipeline/tasks.dart';

void main() {
  test('network saturation does not delay decode lane', () async {
    final scheduler = TaskScheduler.instance;
    scheduler.clear();
    final network = List.generate(
      4,
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
      decode.started.future,
    ]);

    expect(network[3].started.isCompleted, isFalse);
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
