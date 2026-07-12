import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';

/// 记住「哪些漫画源实际提供动图 WebP」，用于显示层路由判定。
///
/// 背景：`_createImageProviderFromKey` 原先只按文件名（含 `.webp`）决定走
/// `WebPImageProvider`（native texture 流式）还是 `ReaderImageProvider`（标准 codec、
/// 整包下载才播）。有的源图片 key 是纯数字（如 `111`）无扩展名 → 恒判非 webp → 动图
/// WebP 被打回非流式老路（转圈转完才播）。
///
/// 学习信号：native 播放游标**成功解出一帧动图 WebP**（见 WebPDecodeSession 首帧产出
/// 处）即最硬的内容证据——非 webp 会被 transport 分类为 fallback 而不解码，静态 webp
/// 无 ANMF 帧游标也解不出，故只有真·动图 WebP 才触发 [mark]。这也正是「只对真正需要
/// native 流式的动图翻转、静态/jpg/png 永不翻转」的精确判据。
///
/// 双层设计，兼顾「首次浏览即流式」与「翻页无 provider 翻转」：
/// - **本会话 live 源集**：[mark] 一确认立即加入并 [revision]++ 通知。当前页据此从
///   `ReaderImageProvider` 翻成 `WebPImageProvider`，completer 挂到策略管道**正在解码
///   的同一 session**，拿到已缓冲帧 → 首次浏览即流式。翻转发生在下载早期（首个 ANMF
///   就绪、ReaderImageProvider 尚未出图），无可见跳变。同一源只在首张动图页翻转一次，
///   之后该源所有页 build 时已在 live 集 → 直接 WebP 无翻转。
/// - **持久化源集**（写 implicitData.json）：未来会话启动即知该源为动图 WebP，首页
///   直接走 WebP 路由，连首次翻转都省（缓存命中则秒开，未命中则直接流式）。
///
/// jpg/png 源永不产出 WebP 帧 → 永不 [mark] → 永不翻转、永远走轻量 ReaderImageProvider
/// 快路径（渐进加载 + 自定义图像处理），零影响。
abstract final class WebPSourceRegistry {
  static const _key = 'webpAnimatedSources';

  /// 本会话已确认为动图 WebP 的源（含本次新学 + 从磁盘加载的历史）。路由实时读它。
  static Set<String>? _sources;

  /// 通知显示层「新学到一个源」→ 触发当前页 provider 翻转重建。仅在**新增**源时 bump。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Set<String> get _set {
    final cached = _sources;
    if (cached != null) return cached;
    final raw = appdata.implicitData[_key];
    final loaded = <String>{};
    if (raw is List) {
      for (final e in raw) {
        if (e is String && e.isNotEmpty) loaded.add(e);
      }
    }
    return _sources = loaded;
  }

  /// 路由判定：该源是否已知为动图 WebP（本会话 live + 历史持久化）。
  static bool isWebPSource(String? sourceKey) {
    if (sourceKey == null || sourceKey.isEmpty) return false;
    return _set.contains(sourceKey);
  }

  /// 学习：解码器确认某源产出动图 WebP 帧时调用。新源立即纳入路由（本会话生效）、
  /// 持久化到磁盘（未来会话生效）、并通知显示层翻转当前页。已知源为 no-op（不重复
  /// 通知、不重复写盘）。
  static void mark(String? sourceKey) {
    if (sourceKey == null || sourceKey.isEmpty) return;
    if (!_set.add(sourceKey)) return;
    appdata.implicitData[_key] = _set.toList();
    appdata.writeImplicitData();
    revision.value++;
  }
}
