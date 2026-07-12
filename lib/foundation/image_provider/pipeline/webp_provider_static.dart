part of '../webp_image.dart';

(int, int) _calculateWebPTargetSize(BuildContext context) {
  // 解码目标尺寸必须只有一个「稳定」的来源。此前用 MediaQuery.of(context).size *
  // dpr：该值在冷启动时随系统栏/安全区 insets 落定而变化（首帧 1080x2400 → 落定
  // 1080x2336）。provider 在 gallery item builder（insets 未定）建立、pipeline 的
  // setTargetSize 在 postFrame（insets 已定）触发 → 两处算出不同尺寸 → 两个不同
  // decodeIdentity/holder → 显示端 completer 监听 holder(2400)，策略把帧解进
  // holder(2336) → completer 永不见帧 → 冷启动首页转圈不播。
  //
  // 改用窗口物理尺寸 View.of(context).physicalSize：它是设备/窗口的物理像素，不随
  // subtree insets 或 build 时机变化，只在真实旋转/多窗口 resize 时改变。这样无论
  // provider 建立还是 setTargetSize，任何时刻、任何 context 都算出同一值，
  // decodeIdentity 恒一致，冷启动/预热都不再错位。下游 BoxFit.contain 负责把略大于
  // 可视区的解码结果缩放显示，视觉无差异。
  final view = View.of(context);
  final size = view.physicalSize;
  final width = _alignWebPDecodeDimension(size.width.round());
  final height = _alignWebPDecodeDimension(size.height.round());
  return (width, height);
}

int _alignWebPDecodeDimension(int value, {int alignment = 8}) {
  if (value <= alignment) return math.max(1, value);
  final aligned = value - (value % alignment);
  return math.max(alignment, aligned);
}

bool _isLikelyWebP(String imageKey) => imageKey.toLowerCase().contains('.webp');
