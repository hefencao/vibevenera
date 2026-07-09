import 'dart:typed_data';
import 'dart:ui' as ui;

import 'byte_cache.dart';
import 'frame_cache.dart';
import 'gpu_cache.dart';

/// 三级缓存：L1 ui.Image、L2 原始字节、L3 RGBA。
///
/// 生命周期绑定到 _GalleryModeState，翻页时显式驱逐。
class DecodedImageCache {
  final _gpu = GpuImageCache();
  final _bytes = ByteCache();
  final _frames = FrameCache();

  int get maxL1Entries => _gpu.maxEntries;
  set maxL1Entries(int value) => _gpu.maxEntries = value;

  int get maxL2Entries => _bytes.maxEntries;
  set maxL2Entries(int value) => _bytes.maxEntries = value;

  // ─── L1 ───
  ui.Image? getL1(String key) => _gpu.get(key);
  void putL1(String key, ui.Image image) => _gpu.put(key, image);
  void evictL1(String key) => _gpu.evict(key);
  void evictInactiveL1() => _gpu.evictInactive();

  // ─── L2 ───
  Uint8List? getL2(String key) => _bytes.get(key);
  void putL2(String key, Uint8List data) => _bytes.put(key, data);
  bool hasL2(String key) => _bytes.contains(key);
  void evictL2(String key) => _bytes.evict(key);

  // ─── L3 ───
  Uint8List? getL3(String key) => _frames.get(key);
  void putL3(String key, Uint8List rgba) => _frames.put(key, rgba);
  void evictL3(String key) => _frames.evict(key);
  void clearL3() => _frames.clear();

  // ─── 生命周期管理 ───
  void setActivePages(Iterable<String> keys) => _gpu.setActiveKeys(keys);

  void dispose() {
    _gpu.dispose();
    _bytes.clear();
    _frames.clear();
  }
}