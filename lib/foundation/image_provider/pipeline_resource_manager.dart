import 'dart:async';

import 'pipeline_models.dart';

/// Manages the lifecycle of [ResourceEntry] objects and orchestrates
/// the download → decode pipeline for a set of image pages.
class ResourceManager {
  final Map<String, ResourceEntry> _entries = {};
  final Map<String, List<ResourceEntry>> _entriesByImageKey = {};

  /// Stream controller for resource state changes.
  final _stateController = StreamController<ResourceEvent>.broadcast();
  Stream<ResourceEvent> get events => _stateController.stream;

  int get entryCount => _entries.length;

  // ── Entry lifecycle ────────────────────────────────────────

  ResourceEntry ensure({
    required String imageKey,
    required String fullKey,
    String? sourceKey,
    required String cid,
    required String eid,
  }) {
    var entry = _entries[fullKey];
    if (entry == null) {
      entry = ResourceEntry(
        imageKey: imageKey,
        fullKey: fullKey,
        sourceKey: sourceKey,
        cid: cid,
        eid: eid,
      );
      _entries[fullKey] = entry;
      _entriesByImageKey.putIfAbsent(imageKey, () => []).add(entry);
    }
    return entry;
  }

  ResourceEntry? get(String key) {
    return _entries[key] ?? _entriesByImageKey[key]?.firstOrNull;
  }

  /// All entries for a given bare imageKey (supports multi-size).
  List<ResourceEntry> getAllForImage(String imageKey) {
    return _entriesByImageKey[imageKey] ?? [];
  }

  void forEach(void Function(ResourceEntry) fn) {
    for (final e in _entries.values) {
      fn(e);
    }
  }

  /// Release resources for an entry (bytes, holder, frame data).
  void release(ResourceEntry entry) {
    final keepDownload = entry.download.inProgress;
    final holder = entry.holder;
    if (holder != null) {
      // holder.dispose() is called by DecoderManager eviction
      entry.holder = null;
    }
    entry.bytes = null;
    if (!keepDownload) entry.download.reset();
    entry.decode.reset();
    _stateController.add(
      ResourceEvent(entry.fullKey, ResourceEventType.released),
    );
  }

  void remove(String fullKey) {
    final entry = _entries.remove(fullKey);
    if (entry != null) {
      final list = _entriesByImageKey[entry.imageKey];
      if (list != null) {
        list.remove(entry);
        if (list.isEmpty) _entriesByImageKey.remove(entry.imageKey);
      }
    }
  }

  void clear() {
    _entries.clear();
    _entriesByImageKey.clear();
  }

  void dispose() {
    clear();
    _stateController.close();
  }
}

// ───────────────────────────────────────────────────────────────
// Resource events
// ───────────────────────────────────────────────────────────────

enum ResourceEventType {
  bytesReady, // Download complete
  holderReady, // Decoder created
  released, // Resources freed
  policyChanged, // allowDownload/allowDecode changed
}

class ResourceEvent {
  final String fullKey;
  final ResourceEventType type;
  ResourceEvent(this.fullKey, this.type);
}
