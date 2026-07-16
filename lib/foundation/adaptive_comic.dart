import 'dart:math' as math;

enum AdaptiveComicType { paged, vertical, animated, mixed }

final class AdaptiveComicProfile {
  static const modelVersion = 4;
  static const applyConfidence = 0.60;
  static const stopConfidence = 0.80;

  final AdaptiveComicType type;
  final double confidence;
  final int samples;
  final int inferenceMicros;
  final String basis;
  final int metadataFingerprint;
  final String? sourceLanguage;
  final bool autoTranslate;

  bool get isTerminal => confidence >= stopConfidence;

  const AdaptiveComicProfile({
    required this.type,
    required this.confidence,
    required this.samples,
    required this.inferenceMicros,
    required this.basis,
    required this.metadataFingerprint,
    this.sourceLanguage,
    this.autoTranslate = false,
  });

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'confidence': confidence,
    'samples': samples,
    'inferenceMicros': inferenceMicros,
    'basis': basis,
    'metadataFingerprint': metadataFingerprint,
    if (sourceLanguage != null) 'sourceLanguage': sourceLanguage,
    'autoTranslate': autoTranslate,
    'modelVersion': modelVersion,
    'updatedAt': DateTime.now().millisecondsSinceEpoch,
  };
}

/// 极轻量漫画布局分类器。当前模型只消费页面几何和元数据，不复制完整像素；后续的
/// INT8 图像编码器可以把 logits 直接合并进 [_scores]，无需改变设置和持久化层。
final class AdaptiveComicClassifier {
  final String title;
  final List<String> tags;
  final String sourceIdentity;
  final String? sourceType;
  late final String? sourceLanguage;
  late final bool autoTranslate;
  late final int metadataFingerprint;
  final Map<String, ({int width, int height})> _samples = {};
  final Set<String> _animatedSamples = {};

  AdaptiveComicClassifier({
    required String sourceKey,
    required String comicId,
    required String title,
    required String author,
    required List<String> tags,
    String sourceName = '',
    String sourceUrl = '',
    this.sourceType,
  }) : title = title.toLowerCase(),
       tags = tags.map((tag) => tag.toLowerCase()).toList(),
       sourceIdentity = '$sourceKey $sourceName $sourceUrl'.toLowerCase() {
    this.tags.sort();
    sourceLanguage = _metadataLanguage();
    autoTranslate = sourceLanguage != null && _hasRawTag();
    metadataFingerprint = _fingerprint(
      '${this.title}\u0000${this.tags.join('\u0000')}\u0000'
      '$sourceIdentity\u0000${sourceType?.toLowerCase() ?? ''}',
    );
  }

  AdaptiveComicProfile? classifyMetadata() {
    final stopwatch = Stopwatch()..start();
    var animatedTag = _match(tags, const [
      'webp动图', 'webp 動圖', 'webp動畫', 'webp 動畫', '动态webp', '動態webp',
      'animated webp', 'animated', '动图', '動圖', '动态图', '動態圖',
    ]);
    if (animatedTag == null) {
      for (final tag in tags) {
        if (tag == 'gif' || tag.endsWith(':gif')) {
          animatedTag = tag;
          break;
        }
      }
    }
    if (animatedTag != null) {
      return _profile(
        AdaptiveComicType.animated,
        0.995,
        'tag:$animatedTag',
        stopwatch,
      );
    }
    final animatedTitle = _match([title], const [
      'webp动图', 'webp 動圖', 'webp動畫', 'webp 動畫', '动态webp', '動態webp',
      'animated webp', '[animated]', '【动图】', '【動圖】', '[动图]', '[動圖]',
    ]);
    if (animatedTitle != null) {
      return _profile(
        AdaptiveComicType.animated,
        0.98,
        'title:$animatedTitle',
        stopwatch,
      );
    }

    final verticalTag = _match(tags, const [
      'webtoon', 'manhwa', '韩漫', '韓漫', '条漫', '條漫', '长条漫', '長條漫',
    ]);
    final pagedTag = _match(tags, const [
      '日漫', '日本漫画', '日本漫畫', 'japanese manga',
    ]);
    if (verticalTag != null && pagedTag == null) {
      return _profile(
        AdaptiveComicType.vertical,
        0.97,
        'tag:$verticalTag',
        stopwatch,
      );
    }
    if (pagedTag != null && verticalTag == null) {
      return _profile(
        AdaptiveComicType.paged,
        0.97,
        'tag:$pagedTag',
        stopwatch,
      );
    }

    final hinted = _sourceType(sourceType);
    if (hinted != null) {
      return _profile(hinted, 0.99, 'source:configured', stopwatch);
    }
    final verticalTitle = _match([title], const [
      'webtoon', 'manhwa', '韩漫', '韓漫', '条漫', '條漫',
    ]);
    if (verticalTitle != null) {
      return _profile(
        AdaptiveComicType.vertical,
        0.94,
        'title:$verticalTitle',
        stopwatch,
      );
    }
    final pagedTitle = _match([title], const ['日漫', '日本漫画', '日本漫畫']);
    if (pagedTitle != null) {
      return _profile(
        AdaptiveComicType.paged,
        0.94,
        'title:$pagedTitle',
        stopwatch,
      );
    }
    final verticalSource = _match([sourceIdentity], const [
      'webtoons.com', 'webtoon', 'lezhin', 'bomtoon', 'toomics', 'toptoon',
    ]);
    if (verticalSource != null) {
      return _profile(
        AdaptiveComicType.vertical,
        0.95,
        'source:$verticalSource',
        stopwatch,
      );
    }
    final pagedSource = _match([sourceIdentity], const ['nhentai']);
    if (pagedSource != null) {
      return _profile(
        AdaptiveComicType.paged,
        0.95,
        'source:$pagedSource',
        stopwatch,
      );
    }
    final category = _category();
    if (category == 'manga') {
      return _profile(
        AdaptiveComicType.vertical,
        0.72,
        'category:manga',
        stopwatch,
      );
    }
    if (const {
      'comic', 'doujinshi', 'doujin', 'artist cg', 'game cg', 'cg',
      'misc', 'image set',
    }.contains(category)) {
      return _profile(
        AdaptiveComicType.paged,
        category == 'comic' || category == 'doujinshi' ? 0.76 : 0.68,
        'category:$category',
        stopwatch,
      );
    }
    final originalWork = _tagNamespace(const {
      '原作', '原作名', 'parody', 'original work',
    });
    if (originalWork != null) {
      return _profile(
        AdaptiveComicType.paged,
        0.70,
        'tag-namespace:$originalWork',
        stopwatch,
      );
    }
    if (sourceLanguage == 'ko') {
      return _profile(AdaptiveComicType.vertical, 0.86,
          'language:korean', stopwatch);
    }
    if (sourceLanguage == 'ja') {
      return _profile(AdaptiveComicType.paged, 0.86,
          'language:japanese', stopwatch);
    }
    return null;
  }

  AdaptiveComicProfile? observe({
    required String imageKey,
    required int pageIndex,
    required int totalPages,
    required int width,
    required int height,
  }) {
    if (totalPages > 2 && pageIndex == 0) return null;
    final previous = _samples[imageKey];
    if (previous?.width == width && previous?.height == height) return null;
    _samples[imageKey] = (width: width, height: height);
    if (_samples.length < 2) return null;

    final stopwatch = Stopwatch()..start();
    final scores = _scores();
    final ordered = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final best = ordered.first;
    final confidence = _softmaxConfidence(scores, best.value);
    if (confidence < AdaptiveComicProfile.applyConfidence) return null;
    return AdaptiveComicProfile(
      type: best.key,
      confidence: confidence,
      samples: _samples.length,
      inferenceMicros: stopwatch.elapsedMicroseconds,
      basis: 'page-geometry',
      metadataFingerprint: metadataFingerprint,
      sourceLanguage: sourceLanguage,
      autoTranslate: autoTranslate,
    );
  }

  AdaptiveComicProfile? observeAnimated({
    required String imageKey,
    required int pageIndex,
    required int totalPages,
  }) {
    if (totalPages > 2 && pageIndex == 0) return null;
    _animatedSamples.add(imageKey);
    if (_animatedSamples.length < 2) return null;
    return AdaptiveComicProfile(
      type: AdaptiveComicType.animated,
      confidence: 1,
      samples: _animatedSamples.length,
      inferenceMicros: 0,
      basis: 'decoded-animation',
      metadataFingerprint: metadataFingerprint,
      sourceLanguage: sourceLanguage,
      autoTranslate: autoTranslate,
    );
  }

  Map<AdaptiveComicType, double> _scores() {
    var vertical = 0.0, paged = 0.0;
    for (final sample in _samples.values) {
      final ratio = sample.height / sample.width;
      if (ratio >= 3) {
        vertical += 4;
      } else if (ratio >= 2) {
        vertical += 2.4;
      } else if (ratio >= 1.55) {
        vertical += 0.6;
        paged += 0.7;
      } else {
        paged += 1.5;
      }
    }
    vertical += _tagWeight(const [
      'webtoon', 'manhwa', 'korean', '韩漫', '韓漫', '条漫', '條漫', '长条', '長條',
      'category:manga', 'type:manga', '分类:manga', '分類:manga',
    ], 1.8);
    paged += _tagWeight(const [
      'comic', 'doujin', 'doujinshi', '日漫', '同人', 'tankoubon', '原作:',
      'parody:', 'artist cg', 'game cg', 'misc', 'image set',
    ], 1.2);
    return {
      AdaptiveComicType.vertical: vertical,
      AdaptiveComicType.paged: paged,
      AdaptiveComicType.mixed: math.min(vertical, paged) + 0.4,
    };
  }

  double _tagWeight(List<String> tokens, double weight) {
    var matches = 0;
    for (final token in tokens) {
      if (tags.any((tag) => tag.contains(token))) matches++;
    }
    return math.min(matches, 2) * weight;
  }

  String? _category() {
    const namespaces = {
      'category', 'categories', 'type', '分类', '分類', '类型', '類型',
    };
    const values = {
      'manga', 'comic', 'doujinshi', 'doujin', 'artist cg', 'game cg', 'cg',
      'misc', 'image set',
    };
    for (final tag in tags) {
      final separator = tag.indexOf(':');
      if (separator > 0 && namespaces.contains(tag.substring(0, separator))) {
        final value = tag.substring(separator + 1).trim();
        if (values.contains(value)) return value;
      }
      if (values.contains(tag)) return tag;
    }
    return null;
  }

  String? _tagNamespace(Set<String> namespaces) {
    for (final tag in tags) {
      final separator = tag.indexOf(':');
      if (separator > 0 && namespaces.contains(tag.substring(0, separator))) {
        return tag.substring(0, separator);
      }
    }
    return null;
  }

  static AdaptiveComicType? _sourceType(String? value) {
    switch (value?.toLowerCase()) {
      case 'animated':
        return AdaptiveComicType.animated;
      case 'vertical':
      case 'webtoon':
      case 'manhwa':
      case 'korean':
        return AdaptiveComicType.vertical;
      case 'paged':
      case 'manga':
      case 'japanese':
        return AdaptiveComicType.paged;
    }
    return null;
  }

  String? _metadataLanguage() {
    if (_match(tags, const [
      'language:korean', '语言:韩语', '語言:韓語', '韩语', '韓語', '한국어',
      'korean', '韩漫', '韓漫', 'manhwa',
    ]) != null) {
      return 'ko';
    }
    if (_match(tags, const [
      'language:japanese', '语言:日语', '語言:日語', '日语', '日語', '日本語',
      'japanese', '日漫',
    ]) != null) {
      return 'ja';
    }
    if (!_hasRawTag()) return null;
    if (_match(tags, const ['webtoon', 'manhwa', '韩漫', '韓漫']) != null ||
        _match([sourceIdentity], const [
          'webtoons.com', 'lezhin', 'bomtoon', 'toomics', 'toptoon',
        ]) != null) {
      return 'ko';
    }
    if (_match(tags, const [
          'manga', 'comic', 'doujinshi', '同人', '日漫',
        ]) != null ||
        _match([sourceIdentity], const ['ehentai', 'e-hentai', 'nhentai']) !=
            null) {
      return 'ja';
    }
    return null;
  }

  bool _hasRawTag() => tags.any((tag) {
    final value = tag.contains(':') ? tag.substring(tag.indexOf(':') + 1) : tag;
    return value == 'raw' || value == 'untranslated' ||
        tag.contains('生肉') || tag.contains('未翻译') || tag.contains('未翻譯');
  });

  static String? _match(List<String> values, List<String> tokens) {
    for (final value in values) {
      for (final token in tokens) {
        if (value.contains(token)) return token;
      }
    }
    return null;
  }

  AdaptiveComicProfile _profile(
    AdaptiveComicType type,
    double confidence,
    String basis,
    Stopwatch stopwatch,
  ) => AdaptiveComicProfile(
    type: type,
    confidence: confidence,
    samples: 0,
    inferenceMicros: stopwatch.elapsedMicroseconds,
    basis: basis,
    metadataFingerprint: metadataFingerprint,
    sourceLanguage: sourceLanguage,
    autoTranslate: autoTranslate,
  );

  static int _fingerprint(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash = ((hash ^ codeUnit) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  static double _softmaxConfidence(
    Map<AdaptiveComicType, double> scores,
    double maxScore,
  ) {
    var total = 0.0;
    for (final score in scores.values) {
      total += math.exp(score - maxScore);
    }
    return 1 / total;
  }
}
