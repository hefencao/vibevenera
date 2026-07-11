import 'preload_policy.dart';
import 'resource_entry.dart';

class PipelineWindowPlan {
  final String currentKey;
  final Set<String> nearKeys;
  final Set<String> prevKeys;
  final Set<String> farKeys;
  final Set<String> keepKeys;
  final Map<String, int> offsetByKey;
  final int ruleIndex;
  final int windowKey;

  const PipelineWindowPlan({
    required this.currentKey,
    required this.nearKeys,
    required this.prevKeys,
    required this.farKeys,
    required this.keepKeys,
    required this.offsetByKey,
    required this.ruleIndex,
    required this.windowKey,
  });
}

class PipelineWindowPlanner {
  const PipelineWindowPlanner();

  PipelineWindowPlan build({
    required int currentIdx,
    required int stableIdx,
    required List<String> images,
    required int currentBufferedFrames,
    required int preloadCount,
    required int existingRuleIndex,
    required int readDirection,
    required InteractionState interaction,
    required bool protectJump,
  }) {
    String fk(int i) => (i >= 0 && i < images.length) ? images[i] : '';
    final ruleIndex = existingRuleIndex < 0
        ? DynamicPreloadPolicy.ruleIndexFor(
            currentBufferedFrames: currentBufferedFrames,
            preloadCount: preloadCount,
          )
        : existingRuleIndex;
    // 页集合用固定窗口，不随 ruleIndex 伸缩（避免近邻页反复进出 decode 集被清帧
    // 重解）。ruleIndex 仍传出，仅供 FrameDepthTable 调每页目标帧深。
    const window = DynamicPreloadPolicy.stableWindow;
    final currentKey = fk(currentIdx);
    final nearKeys = <String>{};
    final prevKeys = <String>{};
    final farKeys = <String>{};
    final keepKeys = <String>{};
    final offsetByKey = <String, int>{};
    final offsets = DynamicPreloadPolicy.offsetsFor(
      preloadCount: preloadCount,
      window: window,
      direction: readDirection,
    );
    for (final offset in offsets.decodeNext) {
      final k = fk(currentIdx + offset);
      if (k.isNotEmpty) {
        nearKeys.add(k);
        offsetByKey[k] = offset;
      }
    }
    for (final offset in offsets.decodePrev) {
      final k = fk(currentIdx + offset);
      if (k.isNotEmpty) {
        prevKeys.add(k);
        offsetByKey[k] = offset;
      }
    }
    for (final offset in offsets.downloadOnly) {
      final k = fk(currentIdx + offset);
      if (k.isNotEmpty) {
        farKeys.add(k);
        offsetByKey[k] = offset;
      }
    }
    for (final offset in offsets.keep) {
      final k = fk(currentIdx + offset);
      if (k.isNotEmpty) {
        keepKeys.add(k);
        offsetByKey[k] = offset;
      }
    }
    if (interaction == InteractionState.dragging) {
      final offset = readDirection >= 0 ? 1 : -1;
      final k = fk(currentIdx + offset);
      if (k.isNotEmpty) {
        if (offset > 0) {
          nearKeys.add(k);
        } else {
          prevKeys.add(k);
        }
        farKeys.remove(k);
        keepKeys.remove(k);
        offsetByKey[k] = offset;
      }
    }
    if (currentKey.isNotEmpty) offsetByKey[currentKey] = 0;
    if (protectJump) {
      final stableKey = fk(stableIdx);
      if (stableKey.isNotEmpty && stableKey != currentKey) {
        nearKeys.remove(stableKey);
        prevKeys.remove(stableKey);
        farKeys.remove(stableKey);
        keepKeys.add(stableKey);
        offsetByKey[stableKey] = stableIdx - currentIdx;
      }
    }
    return PipelineWindowPlan(
      currentKey: currentKey,
      nearKeys: nearKeys,
      prevKeys: prevKeys,
      farKeys: farKeys,
      keepKeys: keepKeys,
      offsetByKey: offsetByKey,
      ruleIndex: ruleIndex,
      windowKey: window.key,
    );
  }
}