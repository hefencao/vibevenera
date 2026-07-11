import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/resource_entry.dart';

void main() {
  test('frame and playback demand is owned by resource policy', () {
    final current = ResourcePolicy.compute(
      InteractionState.idle,
      PagePriority.current,
    );
    final near = ResourcePolicy.compute(
      InteractionState.idle,
      PagePriority.near,
    );
    final draggingNear = ResourcePolicy.compute(
      InteractionState.dragging,
      PagePriority.near,
    );

    expect(
      (current.frameTarget, current.renderedFrameTarget, current.allowPlayback),
      (7, 7, true),
    );
    expect(
      (near.frameTarget, near.renderedFrameTarget, near.allowPlayback),
      (5, 1, false),
    );
    expect(
      (
        draggingNear.allowDownload,
        draggingNear.allowDecode,
        draggingNear.allowGpuUpload,
      ),
      (true, false, false),
    );
  });
}
