import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';

/// 记住「哪些漫画源实际提供流式动图」，用于无扩展名图片的显示层路由判定。
///
/// 无扩展名图片在transport确认GIF头，或native游标产出WebP帧后学习该源。
///
/// 新源会立即触发[revision]重建当前provider，并写入implicitData供下次启动复用。
abstract final class WebPSourceRegistry {
  static const _key = 'streamingAnimatedSources';
  static const _legacyKey = 'webpAnimatedSources';

  /// 本会话已确认为流式动图的源（含本次新学 + 从磁盘加载的历史）。
  static Set<String>? _sources;

  /// 通知显示层「新学到一个源」→ 触发当前页 provider 翻转重建。仅在**新增**源时 bump。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Set<String> get _set {
    final cached = _sources;
    if (cached != null) return cached;
    final loaded = <String>{};
    for (final key in const [_legacyKey, _key]) {
      final raw = appdata.implicitData[key];
      if (raw is List) {
        for (final e in raw) {
          if (e is String && e.isNotEmpty) loaded.add(e);
        }
      }
    }
    return _sources = loaded;
  }

  static bool isStreamingSource(String? sourceKey) {
    if (sourceKey == null || sourceKey.isEmpty) return false;
    return _set.contains(sourceKey);
  }

  /// 学习：确认某源产出流式动图时调用。新源立即纳入路由（本会话生效）、
  /// 持久化到磁盘（未来会话生效）、并通知显示层翻转当前页。已知源为 no-op（不重复
  /// 通知、不重复写盘）。
  static void markStreaming(String? sourceKey) {
    if (sourceKey == null || sourceKey.isEmpty) return;
    if (!_set.add(sourceKey)) return;
    appdata.implicitData[_key] = _set.toList();
    appdata.writeImplicitData();
    revision.value++;
  }
}
