enum PreloadPageClass { current, decode, downloadOnly, keep, evict }

class DynamicPreloadOffsets {
  final Set<int> decodeNext;
  final Set<int> decodePrev;
  final Set<int> downloadOnly;
  final Set<int> keep;

  const DynamicPreloadOffsets({
    required this.decodeNext,
    required this.decodePrev,
    required this.downloadOnly,
    required this.keep,
  });
}

class DynamicPreloadWindow {
  final int decodeNext;
  final int decodePrev;
  final int downloadNext;
  final int downloadPrev;

  const DynamicPreloadWindow({
    required this.decodeNext,
    required this.decodePrev,
    required this.downloadNext,
    required this.downloadPrev,
  });

  int get key =>
      Object.hash(decodeNext, decodePrev, downloadNext, downloadPrev);
}

class WaterLevelRule {
  final int minBufferedFrames;
  final int minPreloadCount;
  final DynamicPreloadWindow window;

  const WaterLevelRule({
    required this.minBufferedFrames,
    required this.minPreloadCount,
    required this.window,
  });
}

class RelativePageRule {
  final PreloadPageClass pageClass;
  final bool Function(int offset, DynamicPreloadWindow window) matches;

  const RelativePageRule({required this.pageClass, required this.matches});
}

bool _current(int offset, DynamicPreloadWindow _) => offset == 0;

bool _nextDecode(int offset, DynamicPreloadWindow window) =>
    offset > 0 && offset <= window.decodeNext;

bool _prevDecode(int offset, DynamicPreloadWindow window) =>
    offset < 0 && -offset <= window.decodePrev;

bool _nextDownload(int offset, DynamicPreloadWindow window) =>
    offset > window.decodeNext && offset <= window.downloadNext;

bool _prevDownload(int offset, DynamicPreloadWindow window) =>
    offset < -window.decodePrev && -offset <= window.downloadPrev;

bool _lastKeep(int offset, DynamicPreloadWindow _) => offset == -1;

const waterLevelRules = <WaterLevelRule>[
  WaterLevelRule(
    minBufferedFrames: 7,
    minPreloadCount: 7,
    window: DynamicPreloadWindow(
      decodeNext: 5,
      decodePrev: 2,
      downloadNext: 9,
      downloadPrev: 4,
    ),
  ),
  WaterLevelRule(
    minBufferedFrames: 7,
    minPreloadCount: 0,
    window: DynamicPreloadWindow(
      decodeNext: 3,
      decodePrev: 2,
      downloadNext: 7,
      downloadPrev: 3,
    ),
  ),
  WaterLevelRule(
    minBufferedFrames: 5,
    minPreloadCount: 0,
    window: DynamicPreloadWindow(
      decodeNext: 2,
      decodePrev: 1,
      downloadNext: 5,
      downloadPrev: 2,
    ),
  ),
  WaterLevelRule(
    minBufferedFrames: 3,
    minPreloadCount: 0,
    window: DynamicPreloadWindow(
      decodeNext: 1,
      decodePrev: 0,
      downloadNext: 4,
      downloadPrev: 1,
    ),
  ),
  WaterLevelRule(
    minBufferedFrames: 0,
    minPreloadCount: 0,
    window: DynamicPreloadWindow(
      decodeNext: 0,
      decodePrev: 0,
      downloadNext: 3,
      downloadPrev: 1,
    ),
  ),
];

final relativePageRules = <RelativePageRule>[
  RelativePageRule(pageClass: PreloadPageClass.current, matches: _current),
  RelativePageRule(pageClass: PreloadPageClass.decode, matches: _nextDecode),
  RelativePageRule(pageClass: PreloadPageClass.decode, matches: _prevDecode),
  RelativePageRule(
    pageClass: PreloadPageClass.downloadOnly,
    matches: _nextDownload,
  ),
  RelativePageRule(
    pageClass: PreloadPageClass.downloadOnly,
    matches: _prevDownload,
  ),
  RelativePageRule(pageClass: PreloadPageClass.keep, matches: _lastKeep),
];

/// 每页目标缓冲帧深表（rank 水位）。用户验证过体验良好的原方案。
///
/// 行 = waterLevelRules 的 ruleIndex（0..4）。ruleIndexFor 按 buffered>=min 扫描
/// [7,7,5,3,0]，故：index4=当前页缓冲<3，index3=≥3，index2=≥5，index1=≥7，
/// index0=≥7且preloadCount≥7。恰好对应用户表由浅到深 5 档。
///
/// 列 = 阅读方向相对距离（readDist = offset * readDirection）：
///   0=current，+1=next(n)，+2=next+1(m)，-1=prev(p)。其余距离目标 0（不预解，
///   仅按 policy 下载/keep）——这正是用户表只列 c/n/m/p 的含义：更远的页只下载。
///
/// 「谁先解」不由此表决定（那是 rank/优先级的事）；此表只定「每页想要几帧」。
/// 关键效果：index4（刚切页 current 缓冲<3）时 n/m/p 全 0 → 当前页首帧独占解码
/// 资源、不排队，直击切页首帧延迟。
class FrameDepthTable {
  const FrameDepthTable._();

  // index: 0(最深)..4(最浅)。列 = 阅读方向相对距离 readDist(0/+1/+2/-1)。
  // 值随当前页缓冲档位(ruleIndex)由浅到深递增；ruleIndex4(当前页缓冲<3，刚切页/
  // 播放告急)近邻全 0，当前页首帧/续帧独占解码。
  static const List<int> _current = [7, 7, 5, 3, 3];
  static const List<int> _next = [5, 3, 2, 1, 0]; // readDist +1
  static const List<int> _nextNext = [3, 2, 1, 1, 0]; // readDist +2
  static const List<int> _prev = [2, 2, 1, 1, 0]; // readDist -1
  static const List<int> _transitionMinimum = [3, 3, 2, 1, 1];

  /// 返回某页在给定档位、给定阅读方向距离下的目标缓冲帧深。
  static int targetFor({required int ruleIndex, required int readDist}) {
    final i = ruleIndex.clamp(0, 4);
    switch (readDist) {
      case 0:
        return _current[i];
      case 1:
        return _next[i];
      case 2:
        return _nextNext[i];
      case -1:
        return _prev[i];
      default:
        return 0;
    }
  }

  /// 已进入 viewport 的目标页至少准备一帧；current 水位充足后再逐级加深。
  /// 调用方应与普通相对页目标取 max，不能因此降低顺阅读方向的既有预解深度。
  static int transitionMinimumFor(int ruleIndex) =>
      _transitionMinimum[ruleIndex.clamp(0, 4)];
}

class DynamicPreloadPolicy {
  const DynamicPreloadPolicy._();

  /// 固定的「页分类窗口」：决定哪些页进 decode/download/keep 集合。**不随当前页
  /// 缓冲档位(ruleIndex)伸缩**——伸缩会让近邻页反复进出 decode 集、被清帧重解
  /// (水位档位抖动 churn 的根因)。每页「想解几帧」的深浅调节交给 FrameDepthTable
  /// 按 ruleIndex 处理即可，页集合本身保持稳定。
  ///
  /// decodeNext=2/decodePrev=1 恰好覆盖 FrameDepthTable 有非零目标的 readDist
  /// (+1/+2/-1)；更远的页只下载(downloadNext=7/downloadPrev=3 供预取)。
  static const DynamicPreloadWindow stableWindow = DynamicPreloadWindow(
    decodeNext: 2,
    decodePrev: 1,
    downloadNext: 7,
    downloadPrev: 3,
  );

  static DynamicPreloadWindow windowFor({
    required int currentBufferedFrames,
    required int preloadCount,
  }) => waterLevelRules[ruleIndexFor(
        currentBufferedFrames: currentBufferedFrames,
        preloadCount: preloadCount,
      )].window;

  static int ruleIndexFor({
    required int currentBufferedFrames,
    required int preloadCount,
  }) {
    for (var i = 0; i < waterLevelRules.length; i++) {
      final rule = waterLevelRules[i];
      if (currentBufferedFrames >= rule.minBufferedFrames &&
          preloadCount >= rule.minPreloadCount) {
        return i;
      }
    }
    return waterLevelRules.length - 1;
  }

  static DynamicPreloadWindow windowAt(int index) =>
      waterLevelRules[index.clamp(0, waterLevelRules.length - 1)].window;

  static PreloadPageClass pageClassFor({
    required int offset,
    required DynamicPreloadWindow window,
  }) {
    for (final rule in relativePageRules) {
      if (rule.matches(offset, window)) return rule.pageClass;
    }
    return PreloadPageClass.evict;
  }

  static DynamicPreloadOffsets offsetsFor({
    required int preloadCount,
    required DynamicPreloadWindow window,
    int direction = 1,
  }) {
    final decodeNext = <int>{};
    final decodePrev = <int>{};
    final downloadOnly = <int>{};
    final keep = <int>{};

    for (int offset = -preloadCount; offset <= preloadCount; offset++) {
      final logicalOffset = direction < 0 ? -offset : offset;
      switch (pageClassFor(offset: logicalOffset, window: window)) {
        case PreloadPageClass.decode:
          if (offset > 0) {
            decodeNext.add(offset);
          } else if (offset < 0) {
            decodePrev.add(offset);
          }
          break;
        case PreloadPageClass.downloadOnly:
          downloadOnly.add(offset);
          break;
        case PreloadPageClass.keep:
          keep.add(offset);
          break;
        case PreloadPageClass.current:
        case PreloadPageClass.evict:
          break;
      }
    }

    return DynamicPreloadOffsets(
      decodeNext: decodeNext,
      decodePrev: decodePrev,
      downloadOnly: downloadOnly,
      keep: keep,
    );
  }
}
