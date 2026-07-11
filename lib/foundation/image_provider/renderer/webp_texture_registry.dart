import 'package:flutter/foundation.dart';

/// 一个可见 WebP 动图显示当前的纹理状态。
@immutable
class WebPTextureInfo {
  final int textureId;
  final int width;
  final int height;

  const WebPTextureInfo({
    required this.textureId,
    required this.width,
    required this.height,
  });

  @override
  bool operator ==(Object other) =>
      other is WebPTextureInfo &&
      textureId == other.textureId &&
      width == other.width &&
      height == other.height;

  @override
  int get hashCode => Object.hash(textureId, width, height);
}

/// native texture 通路的显示侧通道。
///
/// `ImageInfo`/`ImageStream` 只能承载 `ui.Image`，无法携带 textureId。completer
/// 创建纹理后把 [WebPTextureInfo] 写到这里（键为 provider 的 fullKey），ComicImage
/// 监听同一 fullKey：有纹理就渲染 `Texture(textureId)`，否则回退 `RawImage(ui.Image)`。
///
/// 键用 fullKey（含目标尺寸）而非 imageKey，保证旋转/视口变化产生的不同解码目标
/// 各自独立，不会串纹理。
class WebPTextureRegistry {
  WebPTextureRegistry._();

  static final WebPTextureRegistry instance = WebPTextureRegistry._();

  final Map<String, ValueNotifier<WebPTextureInfo?>> _notifiers = {};

  /// 获取（或创建）某 fullKey 的纹理状态通知器。ComicImage 与 completer 共享同一个。
  ValueNotifier<WebPTextureInfo?> listenable(String fullKey) =>
      _notifiers.putIfAbsent(fullKey, () => ValueNotifier<WebPTextureInfo?>(null));

  /// completer 上传首帧后发布纹理信息。
  void publish(String fullKey, WebPTextureInfo info) {
    listenable(fullKey).value = info;
  }

  /// completer 释放纹理时清空（回退到 ui.Image 路径 / 占位）。
  void clear(String fullKey) {
    _notifiers[fullKey]?.value = null;
  }

  /// fullKey 不再有任何显示引用时移除通知器，避免长期泄漏。
  void remove(String fullKey) {
    final n = _notifiers.remove(fullKey);
    n?.dispose();
  }
}
