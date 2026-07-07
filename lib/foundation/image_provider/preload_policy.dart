enum PreloadPageClass { current, decode, downloadOnly, keep, evict }

class DynamicPreloadOffsets {
  final Set<int> decodeNext;
  final Set<int> decodePrev;
  final Set<int> downloadOnlyNext;
  final Set<int> keep;

  const DynamicPreloadOffsets({
    required this.decodeNext,
    required this.decodePrev,
    required this.downloadOnlyNext,
    required this.keep,
  });
}

class DynamicPreloadWindow {
  final int decodeNext;
  final int decodePrev;
  final int downloadExtraNext;

  const DynamicPreloadWindow({
    required this.decodeNext,
    required this.decodePrev,
    required this.downloadExtraNext,
  });

  int get key => Object.hash(decodeNext, decodePrev, downloadExtraNext);
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
    offset > window.decodeNext &&
    offset <= window.decodeNext + window.downloadExtraNext;

bool _lastKeep(int offset, DynamicPreloadWindow _) => offset == -1;

const waterLevelRules = <WaterLevelRule>[
  WaterLevelRule(
    minBufferedFrames: 7,
    minPreloadCount: 7,
    window: DynamicPreloadWindow(
      decodeNext: 5,
      decodePrev: 2,
      downloadExtraNext: 2,
    ),
  ),
  WaterLevelRule(
    minBufferedFrames: 7,
    minPreloadCount: 0,
    window: DynamicPreloadWindow(
      decodeNext: 3,
      decodePrev: 2,
      downloadExtraNext: 1,
    ),
  ),
  WaterLevelRule(
    minBufferedFrames: 5,
    minPreloadCount: 0,
    window: DynamicPreloadWindow(
      decodeNext: 2,
      decodePrev: 1,
      downloadExtraNext: 0,
    ),
  ),
  WaterLevelRule(
    minBufferedFrames: 3,
    minPreloadCount: 0,
    window: DynamicPreloadWindow(
      decodeNext: 1,
      decodePrev: 0,
      downloadExtraNext: 0,
    ),
  ),
  WaterLevelRule(
    minBufferedFrames: 0,
    minPreloadCount: 0,
    window: DynamicPreloadWindow(
      decodeNext: 0,
      decodePrev: 0,
      downloadExtraNext: 0,
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
  RelativePageRule(pageClass: PreloadPageClass.keep, matches: _lastKeep),
];

class DynamicPreloadPolicy {
  const DynamicPreloadPolicy._();

  static DynamicPreloadWindow windowFor({
    required int currentBufferedFrames,
    required int preloadCount,
  }) {
    for (final rule in waterLevelRules) {
      if (currentBufferedFrames >= rule.minBufferedFrames &&
          preloadCount >= rule.minPreloadCount) {
        return rule.window;
      }
    }
    return waterLevelRules.last.window;
  }

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
  }) {
    final decodeNext = <int>{};
    final decodePrev = <int>{};
    final downloadOnlyNext = <int>{};
    final keep = <int>{};

    for (int offset = -preloadCount; offset <= preloadCount; offset++) {
      switch (pageClassFor(offset: offset, window: window)) {
        case PreloadPageClass.decode:
          if (offset > 0) {
            decodeNext.add(offset);
          } else if (offset < 0) {
            decodePrev.add(offset);
          }
          break;
        case PreloadPageClass.downloadOnly:
          downloadOnlyNext.add(offset);
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
      downloadOnlyNext: downloadOnlyNext,
      keep: keep,
    );
  }
}
