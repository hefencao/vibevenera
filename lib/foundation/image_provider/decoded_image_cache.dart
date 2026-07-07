import 'dart:typed_data';
import 'dart:ui' as ui;

/// 三级缓存：管理 WebP 解码后的图像内存。
///
/// 生命周期绑定到 _GalleryModeState，翻页时显式驱逐。
class DecodedImageCache {
  /// L1: 屏幕分辨率 ui.Image（GPU 内存）
  final _l1 = <String, _L1Entry>{};

  /// L2: 原始 WebP 字节（Dart 堆）
  final _l2 = <String, Uint8List>{};
  final _l2Order = <String>[];

  /// L3: 全分辨率 RGBA（仅缩放 > 阈值时存在）
  final _l3 = <String, Uint8List>{};

  /// L1 最大条目数（静态图页数）
  int maxL1Entries = 3;

  /// L2 最大条目数（预取页数）
  int maxL2Entries = 10;

  /// 当前活跃页面列表（不驱逐这些页的缓存）
  final _activePages = <String>{};

  // ─── L1 ───

  /// 获取 L1 缓存的 ui.Image
  ui.Image? getL1(String key) {
    final entry = _l1[key];
    if (entry == null) return null;
    entry.lastAccess = DateTime.now();
    return entry.image.clone();
  }

  /// 存入 L1，若超出容量则驱逐最久未访问的
  void putL1(String key, ui.Image image) {
    // 如果已存在，先释放旧的
    final existing = _l1.remove(key);
    existing?.image.dispose();

    _l1[key] = _L1Entry(image: image.clone(), lastAccess: DateTime.now());
    _evictL1IfNeeded();
  }

  void _evictL1IfNeeded() {
    while (_l1.length > maxL1Entries) {
      // 找到最久未访问且不在活跃列表中的条目
      String? oldestKey;
      DateTime? oldestTime;
      for (final entry in _l1.entries) {
        if (_activePages.contains(entry.key)) continue;
        if (oldestTime == null || entry.value.lastAccess.isBefore(oldestTime)) {
          oldestKey = entry.key;
          oldestTime = entry.value.lastAccess;
        }
      }
      if (oldestKey == null) break; // 所有条目都在活跃列表中
      _l1.remove(oldestKey)!.image.dispose();
    }
  }

  /// 驱逐指定页的 L1 缓存
  void evictL1(String key) {
    _l1.remove(key)?.image.dispose();
  }

  /// 批量驱逐不在活跃列表中的 L1 缓存
  void evictInactiveL1() {
    final toRemove = <String>[];
    for (final key in _l1.keys) {
      if (!_activePages.contains(key)) {
        toRemove.add(key);
      }
    }
    for (final key in toRemove) {
      _l1.remove(key)?.image.dispose();
    }
  }

  // ─── L2 ───

  Uint8List? getL2(String key) {
    return _l2[key];
  }

  void putL2(String key, Uint8List data) {
    if (!_l2.containsKey(key)) {
      _l2Order.add(key);
    }
    _l2[key] = data;
    while (_l2Order.length > maxL2Entries) {
      final oldest = _l2Order.removeAt(0);
      _l2.remove(oldest);
    }
  }

  bool hasL2(String key) => _l2.containsKey(key);

  // ─── L3 ───

  Uint8List? getL3(String key) => _l3[key];

  void putL3(String key, Uint8List rgba) {
    _l3[key] = rgba;
  }

  void evictL3(String key) {
    _l3.remove(key);
  }

  void clearL3() {
    _l3.clear();
  }

  // ─── 生命周期管理 ───

  /// 通知缓存当前活跃页面集合
  void setActivePages(Iterable<String> keys) {
    _activePages
      ..clear()
      ..addAll(keys);
    evictInactiveL1();
  }

  /// 释放所有资源
  void dispose() {
    for (final entry in _l1.values) {
      entry.image.dispose();
    }
    _l1.clear();
    _l2.clear();
    _l2Order.clear();
    _l3.clear();
    _activePages.clear();
  }
}

class _L1Entry {
  final ui.Image image;
  DateTime lastAccess;

  _L1Entry({required this.image, required this.lastAccess});
}
