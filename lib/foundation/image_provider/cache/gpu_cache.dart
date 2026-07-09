import 'dart:ui' as ui;

class GpuImageCache {
  final _entries = <String, _GpuEntry>{};
  final _activeKeys = <String>{};
  int maxEntries;

  GpuImageCache({this.maxEntries = 3});

  ui.Image? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    entry.lastAccess = DateTime.now();
    return entry.image.clone();
  }

  void put(String key, ui.Image image) {
    _entries.remove(key)?.image.dispose();
    _entries[key] = _GpuEntry(image.clone(), DateTime.now());
    _evictIfNeeded();
  }

  void evict(String key) => _entries.remove(key)?.image.dispose();

  void setActiveKeys(Iterable<String> keys) {
    _activeKeys
      ..clear()
      ..addAll(keys);
    evictInactive();
  }

  void evictInactive() {
    final removed = <String>[];
    for (final key in _entries.keys) {
      if (!_activeKeys.contains(key)) removed.add(key);
    }
    for (final key in removed) {
      evict(key);
    }
  }

  void _evictIfNeeded() {
    while (_entries.length > maxEntries) {
      String? oldestKey;
      DateTime? oldestTime;
      for (final entry in _entries.entries) {
        if (_activeKeys.contains(entry.key)) continue;
        if (oldestTime == null || entry.value.lastAccess.isBefore(oldestTime)) {
          oldestKey = entry.key;
          oldestTime = entry.value.lastAccess;
        }
      }
      if (oldestKey == null) break;
      evict(oldestKey);
    }
  }

  void dispose() {
    for (final entry in _entries.values) {
      entry.image.dispose();
    }
    _entries.clear();
    _activeKeys.clear();
  }
}

class _GpuEntry {
  final ui.Image image;
  DateTime lastAccess;
  _GpuEntry(this.image, this.lastAccess);
}