part of '../webp_image_provider.dart';

class DecoderManager {
  static final DecoderManager instance = DecoderManager._();
  DecoderManager._();

  final Map<String, DecoderHolder> _holders = {};
  final HolderDecodeService decodeService = HolderDecodeService();

  int get generation => decodeService.generation;

  // Page range for policy assignment to new holders.
  String _currentKey = '';
  final Set<String> _nextKeys = {};
  final Set<String> _lastKeys = {};
  final Set<String> _precacheKeys = {};
  InteractionState _interaction = InteractionState.idle;

  Timer? _evictionTimer;

  void setInteractionState(InteractionState state) {
    _interaction = state;
  }

  bool isCurrentImageKey(String imageKey) => _baseKey(imageKey) == _currentKey;
  bool isActiveImageKey(String imageKey) {
    final key = _baseKey(imageKey);
    return _currentKey.isEmpty ||
        key == _currentKey ||
        _nextKeys.contains(key) ||
        _lastKeys.contains(key) ||
        _precacheKeys.contains(key);
  }
  bool isCurrentHolder(DecoderHolder holder) =>
      _baseKey(holder.key) == _currentKey && holder.state == PageState.current;

  DecodedImageCache? cache;

  /// Extract bare imageKey from a fullKey (imageKey@WxH).
  static String _baseKey(String fullKey) {
    // The resolution suffix always has the form @WxH at the end.
    // Split on the last '@' — the imageKey itself may contain '@'
    // in rare URL cases, but the resolution suffix is always last.
    final at = fullKey.lastIndexOf('@');
    if (at < 0) return fullKey;
    final suffix = fullKey.substring(at + 1);
    // Verify it looks like WxH (digits, 'x', digits)
    if (RegExp(r'^\d+x\d+$').hasMatch(suffix)) {
      return fullKey.substring(0, at);
    }
    return fullKey;
  }

  // ── Holder management ──────────────────────────────────────

  DecoderHolder? getHolder(String key) => _holders[key];

  void removeHolder(String key) {
    final holder = _holders.remove(key);
    if (holder == null) return;
    holder.dispose();
    if (_holders.isEmpty) _cancelEvictionTimer();
  }

  DecoderHolder getOrCreateHolder(
    String key,
    webp.WebPAnimDecoder decoder,
    int tw,
    int th,
    double scale,
  ) {
    _ensureEvictionTimer();
    final existing = _holders[key];
    if (existing != null && !existing.disposed) {
      decoder.dispose();
      return existing;
    }
    if (existing != null) {
      _holders.remove(key);
    }
    return _holders.putIfAbsent(key, () {
      final h = DecoderHolder(
        key: key,
        decoder: decoder,
        targetW: tw,
        targetH: th,
        scale: scale,
      );
      decodeService.attach(h);
      final bk = _baseKey(key);
      if (bk == _currentKey) {
        h.updateState(PageState.current);
        h.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.current),
        );
      } else if (_nextKeys.contains(bk) || _lastKeys.contains(bk)) {
        h.updateState(PageState.next);
        h.updatePolicy(ResourcePolicy.compute(_interaction, PagePriority.near));
      } else if (_precacheKeys.contains(bk)) {
        h.updateState(PageState.precache);
        h.updatePolicy(ResourcePolicy.compute(_interaction, PagePriority.far));
      }
      return h;
    });
  }

  // ── Page range tracking ────────────────────────────────────

  void setPageRange({
    required String currentKey,
    required Set<String> nextKeys,
    required Set<String> lastKeys,
    required Set<String> precacheKeys,
  }) {
    _currentKey = currentKey;
    _nextKeys
      ..clear()
      ..addAll(nextKeys);
    _lastKeys
      ..clear()
      ..addAll(lastKeys);
    _precacheKeys
      ..clear()
      ..addAll(precacheKeys);

    // Update holder states by matching base keys
    for (final e in _holders.entries) {
      final bk = _baseKey(e.key);
      if (bk == currentKey) {
        e.value.updateState(PageState.current);
        e.value.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.current),
        );
      } else if (nextKeys.contains(bk) || lastKeys.contains(bk)) {
        e.value.updateState(PageState.next);
        e.value.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.near),
        );
      } else if (precacheKeys.contains(bk)) {
        e.value.updateState(PageState.precache);
        e.value.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.far),
        );
      } else {
        e.value.updateState(PageState.precache);
        e.value.updatePolicy(
          ResourcePolicy.compute(_interaction, PagePriority.distant),
        );
      }
    }
  }

  void applyPolicyToHolder(
    String imageKey,
    ResourcePolicy policy,
    PagePriority priority,
  ) {
    for (final e in _holders.entries) {
      if (_baseKey(e.key) == imageKey && !e.value.disposed) {
        e.value.updateState(_priorityToPageState(priority));
        e.value.updatePolicy(policy);
        return;
      }
    }
  }

  // ── Eviction ───────────────────────────────────────────────

  void _ensureEvictionTimer() {
    _evictionTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _evictDistant(),
    );
  }

  void _cancelEvictionTimer() {
    _evictionTimer?.cancel();
    _evictionTimer = null;
  }

  void _evictDistant() {
    final now = _nowMs();
    final toRemove = <String>[];
    _holders.forEach((key, holder) {
      final bk = _baseKey(key);
      if (bk != _currentKey &&
          !_nextKeys.contains(bk) &&
          !_lastKeys.contains(bk) &&
          !_precacheKeys.contains(bk)) {
        if (now - holder.lastAccessTime > 2000) toRemove.add(key);
      }
    });
    for (final k in toRemove) {
      final h = _holders.remove(k);
      if (h != null) {
        h.markPendingDispose();
      }
    }
    if (_holders.isEmpty) _cancelEvictionTimer();
  }

  // ── Lifecycle ──────────────────────────────────────────────

  void clearAll() {
    decodeService.updateGeneration(decodeService.generation + 1);
    _interaction = InteractionState.idle;
    for (final h in _holders.values) {
      h.dispose();
    }
    _holders.clear();
    _currentKey = '';
    _nextKeys.clear();
    _lastKeys.clear();
    _precacheKeys.clear();
    _cancelEvictionTimer();
  }
}

// ═══════════════════════════════════════════════════════════════
// 5. WebPImageProvider — Flutter ImageProvider
//
// [FIX] Simplified: delegates to PipelineController for resource
// state, uses decomposed ensureHolder steps.
// ═══════════════════════════════════════════════════════════════

