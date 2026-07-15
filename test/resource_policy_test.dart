import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/resource_entry.dart';

/// 校验 [ResourcePolicy] 交互状态 × 页面优先级的授权表。
///
/// 注意：逐页「解到几帧」的帧目标已不在 ResourcePolicy 上（移到
/// FrameDepthTable / StreamingResourceDemand.decodeTargetFrames），屏外不播放也
/// 不再由 policy 的 allowPlayback 表达，而是在播放泵里按 decode.isCurrent 门控。
/// 因此本测试只覆盖 policy 真正拥有的授权位与优先级。
void main() {
  test('idle 授权与优先级随优先级档位递减', () {
    final current = ResourcePolicy.compute(
      InteractionState.idle,
      PagePriority.current,
    );
    final near = ResourcePolicy.compute(
      InteractionState.idle,
      PagePriority.near,
    );
    final far = ResourcePolicy.compute(
      InteractionState.idle,
      PagePriority.far,
    );
    final distant = ResourcePolicy.compute(
      InteractionState.idle,
      PagePriority.distant,
    );

    // 当前页：下载/解码/上传全开，最高优先级。
    expect(
      (
        current.allowDownload,
        current.allowDecode,
        current.allowGpuUpload,
        current.downloadPriority,
        current.decodePriority,
      ),
      (true, true, true, 100, 100),
    );
    // 近邻页：三档全开，但优先级低于当前页（不抢当前页解码核靠 pump 门控 + 优先级）。
    expect(
      (
        near.allowDownload,
        near.allowDecode,
        near.allowGpuUpload,
        near.downloadPriority,
        near.decodePriority,
      ),
      (true, true, true, 50, 50),
    );
    // 远页：只下字节不解码。
    expect(
      (far.allowDownload, far.allowDecode, far.allowGpuUpload),
      (true, false, false),
    );
    // distant：不授权任何工作，可被回收。
    expect(
      (distant.allowDownload, distant.allowDecode, distant.allowEviction),
      (false, false, true),
    );
  });

  test('jumping 时近邻/远页降为可回收，仅当前页保留全授权', () {
    final current = ResourcePolicy.compute(
      InteractionState.jumping,
      PagePriority.current,
    );
    final near = ResourcePolicy.compute(
      InteractionState.jumping,
      PagePriority.near,
    );

    expect(
      (current.allowDownload, current.allowDecode, current.allowGpuUpload),
      (true, true, true),
    );
    // 快速跳页时近邻不预取（避免为一闪而过的页做无意义下载/解码）。
    expect(
      (near.allowDownload, near.allowDecode, near.allowEviction),
      (false, false, true),
    );
  });

  test('dragging 近邻允许下载与解码，但下载优先级低于 idle', () {
    final draggingNear = ResourcePolicy.compute(
      InteractionState.dragging,
      PagePriority.near,
    );
    final draggingFar = ResourcePolicy.compute(
      InteractionState.dragging,
      PagePriority.far,
    );

    expect(
      (
        draggingNear.allowDownload,
        draggingNear.allowDecode,
        draggingNear.allowGpuUpload,
        draggingNear.downloadPriority,
      ),
      (true, true, true, 30),
    );
    // 拖动中远页只排队下载，不解码。
    expect(
      (draggingFar.allowDownload, draggingFar.allowDecode),
      (true, false),
    );
  });

  test('viewport 目标页在交互中保持完整准备权限', () {
    for (final interaction in InteractionState.values) {
      final transition = ResourcePolicy.compute(
        interaction,
        PagePriority.transition,
      );
      expect(
        (
          transition.allowDownload,
          transition.allowDecode,
          transition.allowGpuUpload,
          transition.decodePriority,
        ),
        (true, true, true, 80),
      );
    }
  });

  test('viewport 只在两页明显重叠时冻结 present', () {
    final dominant = ViewportTransitionState.moving(
      currentCoverage: 0.9,
      targetKeys: {'next'},
    );
    final overlap = ViewportTransitionState.moving(
      currentCoverage: 0.7,
      targetKeys: {'next'},
    );
    final hysteresis = ViewportTransitionState.moving(
      currentCoverage: 0.85,
      targetKeys: {'next'},
      previousPhase: ViewportTransitionPhase.overlap,
    );

    expect(dominant.phase, ViewportTransitionPhase.dominant);
    expect(dominant.shouldFreezePlayback, isFalse);
    expect(dominant.prepares('next'), isTrue);
    expect(overlap.phase, ViewportTransitionPhase.overlap);
    expect(overlap.shouldFreezePlayback, isTrue);
    expect(hysteresis.phase, ViewportTransitionPhase.overlap);
    expect(ViewportTransitionState.idle.shouldFreezePlayback, isFalse);
  });

  test('withDownloadPriority 只改下载优先级，其余不变', () {
    final base = ResourcePolicy.compute(
      InteractionState.idle,
      PagePriority.near,
    );
    final bumped = base.withDownloadPriority(999);

    expect(bumped.downloadPriority, 999);
    expect(bumped.decodePriority, base.decodePriority);
    expect(bumped.allowDownload, base.allowDownload);
    expect(bumped.allowDecode, base.allowDecode);
  });
}
