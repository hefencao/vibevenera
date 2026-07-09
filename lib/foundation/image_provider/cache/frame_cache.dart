import 'dart:typed_data';

class FrameCache {
  final _frames = <String, Uint8List>{};

  Uint8List? get(String key) => _frames[key];
  void put(String key, Uint8List rgba) => _frames[key] = rgba;
  void evict(String key) => _frames.remove(key);
  void clear() => _frames.clear();
}