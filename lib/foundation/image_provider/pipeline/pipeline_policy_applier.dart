import 'resource_entry.dart';
import 'resource_manager.dart';

class PipelinePolicyApplier {
  const PipelinePolicyApplier();

  Set<String> apply({
    required ResourceManager resources,
    required InteractionState interaction,
    required String currentKey,
    required Set<String> transitionKeys,
    required Set<String> nearKeys,
    required Set<String> prevKeys,
    required Set<String> farKeys,
    required Set<String> keepKeys,
    required int Function(ResourceEntry entry, PagePriority priority) downloadRank,
    bool markDistant = true,
  }) {
    final active = <String>{
      currentKey,
      ...transitionKeys,
      ...nearKeys,
      ...prevKeys,
      ...farKeys,
      ...keepKeys,
    }..remove('');
    final byKey = <String, ResourceEntry>{};
    resources.forEach((e) => byKey[e.imageKey] = e);

    void applyKey(String key, PagePriority priority) {
      final entry = byKey[key];
      if (entry == null) return;
      entry.updatePriority(priority);
      final base = ResourcePolicy.compute(interaction, priority);
      entry.updatePolicy(
        base.allowDownload
            ? base.withDownloadPriority(downloadRank(entry, priority))
            : base,
      );
    }

    for (final k in nearKeys) {
      applyKey(k, PagePriority.near);
    }
    for (final k in prevKeys) {
      applyKey(k, PagePriority.near);
    }
    for (final k in farKeys) {
      applyKey(k, PagePriority.far);
    }
    for (final k in keepKeys) {
      applyKey(k, PagePriority.keep);
    }
    for (final k in transitionKeys) {
      if (k != currentKey) applyKey(k, PagePriority.transition);
    }
    applyKey(currentKey, PagePriority.current);
    if (markDistant) {
      resources.forEach((entry) {
        if (active.contains(entry.imageKey)) return;
        entry.updatePriority(PagePriority.distant);
        entry.updatePolicy(
          ResourcePolicy.compute(interaction, PagePriority.distant),
        );
      });
    }
    return active;
  }
}
