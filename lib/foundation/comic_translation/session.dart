import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/cache_manager.dart';

import 'engine.dart';
import 'grouping.dart';
import 'input_resolver.dart';
import 'models.dart';
import 'policy.dart';
import 'store.dart';

final class ComicTranslationSession {
  final ComicTranslationPolicy policy;
  final ComicTranslationInputResolver inputResolver;
  final ComicTranslationEngineRegistry engines;
  final String sourceLanguage;
  final String targetLanguage;

  ComicTranslationSession({
    required bool enabled,
    required this.sourceLanguage,
    required this.targetLanguage,
    this.policy = const ComicTranslationPolicy(),
    this.inputResolver = const ComicTranslationInputResolver(),
    ComicTranslationEngineRegistry? engines,
  }) : engines = engines ?? ComicTranslationEngineRegistry.instance,
       _enabled = enabled {
    _cacheSubscription = CacheManager.changes.listen(_onCacheChanged);
  }

  bool _enabled;
  bool _running = false;
  bool _disposed = false;
  bool _enginesReleased = false;
  ComicTranslationEnginePair? _enginePair;
  Timer? _submissionTimer;
  late final StreamSubscription<String> _cacheSubscription;
  ComicTranslationInteraction _interaction = ComicTranslationInteraction.idle;
  List<ComicTranslationPageIdentity> _current = const [];
  List<ComicTranslationPageIdentity> _near = const [];
  final Map<String, ValueNotifier<ComicTranslationPageState>> _states = {};
  final Map<String, ComicTranslationPageIdentity> _identities = {};
  final Map<String, _QueuedTranslation> _queue = {};
  final Map<String, Map<int, ComicTranslationArtifact>> _readyPages = {};
  final ValueNotifier<double> _fontScale = ValueNotifier(1);
  bool _fontScaleResolved = false;

  bool get enabled => _enabled;

  bool get backendReady => engines.ready;

  ValueListenable<double> get fontScaleListenable => _fontScale;

  ValueListenable<ComicTranslationPageState> listenable(
    ComicTranslationPageIdentity identity,
  ) {
    _identities[identity.key] = identity;
    return _states.putIfAbsent(
      identity.key,
      () => ValueNotifier(_enabled
          ? const ComicTranslationPageState(ComicTranslationPhase.queued)
          : ComicTranslationPageState.disabled),
    );
  }

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      _submissionTimer?.cancel();
      _queue.clear();
      for (final state in _states.values) {
        state.value = ComicTranslationPageState(
          ComicTranslationPhase.disabled,
          artifact: state.value.artifact,
          cleanOverlayPng: state.value.cleanOverlayPng,
        );
      }
      return;
    }
    reportPages(current: _current, near: _near, interaction: _interaction);
  }

  void setInteraction(ComicTranslationInteraction interaction) {
    if (_interaction == interaction) return;
    _interaction = interaction;
    if (interaction == ComicTranslationInteraction.idle ||
        interaction == ComicTranslationInteraction.jumping) {
      reportPages(current: _current, near: _near, interaction: interaction);
    }
  }

  void reportPages({
    required List<ComicTranslationPageIdentity> current,
    List<ComicTranslationPageIdentity> near = const [],
    required ComicTranslationInteraction interaction,
  }) {
    _current = current;
    _near = near;
    _interaction = interaction;
    if (!_enabled || _disposed || current.isEmpty) return;
    _submissionTimer?.cancel();
    final delay = policy.submissionDelay(interaction);
    if (delay == Duration.zero) {
      _submitVisiblePages();
    } else {
      _submissionTimer = Timer(delay, _submitVisiblePages);
    }
  }

  void imageReady(ComicTranslationPageIdentity identity) {
    final state = _states[identity.key]?.value;
    if (!_enabled || state?.phase != ComicTranslationPhase.waitingForImage) {
      return;
    }
    _enqueue(identity, 1000);
  }

  void retry(ComicTranslationPageIdentity identity) {
    if (!_enabled) return;
    _enqueue(identity, 1000);
  }

  void _submitVisiblePages() {
    if (!_enabled || _disposed) return;
    final retained = <String>{};
    for (final identity in _current) {
      retained.add(identity.key);
      _enqueue(identity, policy.priority(distance: 0, current: true));
    }
    for (var i = 0; i < _near.length && i < policy.prefetchPages; i++) {
      final identity = _near[i];
      retained.add(identity.key);
      _enqueue(identity, policy.priority(distance: i + 1, current: false));
    }
    _queue.removeWhere((key, _) => !retained.contains(key));
  }

  void _enqueue(ComicTranslationPageIdentity identity, int priority) {
    _identities[identity.key] = identity;
    final state = _states.putIfAbsent(
      identity.key,
      () => ValueNotifier(ComicTranslationPageState.disabled),
    );
    if (identity.mediaKind == ComicTranslationMediaKind.animatedImage) {
      state.value = const ComicTranslationPageState(
        ComicTranslationPhase.unsupportedMedia,
      );
      return;
    }
    if (!engines.ready) {
      state.value = const ComicTranslationPageState(
        ComicTranslationPhase.unavailable,
      );
      return;
    }
    final readyArtifact = state.value.artifact;
    if (readyArtifact != null) {
      state.value = ComicTranslationPageState(
        ComicTranslationPhase.ready,
        artifact: readyArtifact,
        cleanOverlayPng: state.value.cleanOverlayPng,
      );
      return;
    }
    if (state.value.phase == ComicTranslationPhase.ready) return;
    final queued = _queue[identity.key];
    if (queued == null || priority > queued.priority) {
      _queue[identity.key] = _QueuedTranslation(identity, priority);
    }
    state.value = const ComicTranslationPageState(
      ComicTranslationPhase.queued,
    );
    unawaited(_pump());
  }

  void _onCacheChanged(String cacheKey) {
    if (!_enabled || _disposed) return;
    for (final entry in _states.entries) {
      if (entry.value.value.phase != ComicTranslationPhase.waitingForImage) {
        continue;
      }
      final identity = _identities[entry.key]!;
      final identityCacheKey =
          '${identity.imageKey}@${identity.sourceKey}@${identity.comicId}@${identity.chapterId}';
      if (cacheKey == identityCacheKey) _enqueue(identity, 1000);
    }
  }

  Future<void> _pump() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      while (_enabled && _queue.isNotEmpty) {
        final item = _queue.values.reduce(
          (a, b) => a.priority >= b.priority ? a : b,
        );
        _queue.remove(item.identity.key);
        try {
          await _process(item.identity);
        } catch (error) {
          _setState(
            item.identity,
            ComicTranslationPageState(
              ComicTranslationPhase.failed,
              error: error,
            ),
          );
        }
      }
    } finally {
      _running = false;
      if (_disposed) unawaited(_releaseEngines());
    }
  }

  Future<void> _process(ComicTranslationPageIdentity identity) async {
    final input = await inputResolver.resolve(identity);
    if (input == null) {
      _setState(
        identity,
        const ComicTranslationPageState(
          ComicTranslationPhase.waitingForImage,
        ),
      );
      return;
    }
    if (input.mediaKind == ComicTranslationMediaKind.animatedImage) {
      _setState(
        identity,
        const ComicTranslationPageState(
          ComicTranslationPhase.unsupportedMedia,
        ),
      );
      return;
    }
    final pair = _enginePair ??= await engines.acquire();
    final ocrEngine = pair.ocr;
    final translator = pair.translator;
    var ocr = await ComicTranslationStore.instance.findOcr(
      contentDigest: input.contentDigest,
      engineId: ocrEngine.id,
      modelVersion: ocrEngine.modelVersion,
      sourceLanguage: sourceLanguage,
    );
    if (ocr == null) {
      await engines.loadOcr(pair, sourceLanguage);
      _setState(
        identity,
        const ComicTranslationPageState(
          ComicTranslationPhase.recognizing,
        ),
      );
      ocr = await ocrEngine.recognize(ComicOcrInput(
        identity: identity,
        filePath: input.file.path,
        contentDigest: input.contentDigest,
        sourceLanguage: sourceLanguage,
        maxAnalysisSide: policy.maxAnalysisSide,
        animatedMode: AnimatedTranslationMode.posterFrame,
      ));
      if (ocr.contentDigest != input.contentDigest) {
        throw StateError('OCR result content digest does not match input');
      }
      await ComicTranslationStore.instance.storeOcr(ocr);
    }
    final context = _translationContext(identity.chapterId, identity.pageIndex);
    final contextDigest = sha256
        .convert(utf8.encode(jsonEncode(context.map((entry) => [
          entry.pageIndex,
          entry.sourceTexts,
          entry.translatedTexts,
        ]).toList())))
        .toString();
    final translationModelVersion =
        'artifact-v2:${translator.modelVersion}:'
        'sfx=${policy.translateSoundEffects}';
    var translation = await ComicTranslationStore.instance.findTranslation(
      ocrDigest: ocr.digest,
      engineId: translator.id,
      modelVersion: translationModelVersion,
      targetLanguage: targetLanguage,
      contextDigest: contextDigest,
    );
    if (translation == null) {
      await engines.loadTranslator(pair);
      _setState(
        identity,
        const ComicTranslationPageState(
          ComicTranslationPhase.translating,
        ),
      );
      final request = ComicTranslationRequest(
        ocr: ocr,
        targetLanguage: targetLanguage,
        previousPages: context,
        translateSoundEffects: policy.translateSoundEffects,
      );
      final result = await translator.translate(request);
      final translatedRegions = request.expandUnitTranslations(result);
      final memberships = <String, ({
        String unitId,
        int unitOrder,
        int bandIndex,
        ComicTextOrientation orientation,
      })>{};
      for (final unit in request.units) {
        final orders = <String, int>{
          for (var i = 0; i < unit.regionIds.length; i++) unit.regionIds[i]: i,
        };
        for (var band = 0; band < unit.bandRegionIds.length; band++) {
          for (final regionId in unit.bandRegionIds[band]) {
            memberships[regionId] = (
              unitId: unit.id,
              unitOrder: orders[regionId]!,
              bandIndex: band,
              orientation: unit.orientation,
            );
          }
        }
      }
      final regions = ocr.regions.map((region) {
        final membership = memberships[region.id];
        return ComicTranslatedRegion(
          ocrRegionId: region.id,
          sourceText: region.text,
          translatedText: translatedRegions[region.id]!,
          translationUnitId: membership?.unitId,
          translationUnitOrder: membership?.unitOrder,
          translationBandIndex: membership?.bandIndex,
          translationOrientation: membership?.orientation,
          polygon: region.polygon,
          orientation: region.orientation,
          kind: region.kind,
          readingOrder: region.readingOrder,
          sourceMaskPolygons: region.sourceMaskPolygons,
          backgroundArgb: region.backgroundArgb,
          foregroundArgb: region.foregroundArgb,
          bubbleGroupId: region.bubbleGroupId,
          bubblePolygon: region.bubblePolygon,
          frameSpan: region.frameSpan,
        );
      }).toList();
      translation = ComicTranslationArtifact(
        contentDigest: input.contentDigest,
        ocrDigest: ocr.digest,
        engineId: translator.id,
        modelVersion: translationModelVersion,
        sourceLanguage: ocr.sourceLanguage,
        targetLanguage: targetLanguage,
        contextDigest: contextDigest,
        imageWidth: ocr.imageWidth,
        imageHeight: ocr.imageHeight,
        mediaKind: ocr.mediaKind,
        animatedMode: ocr.animatedMode,
        regions: regions,
      );
      await ComicTranslationStore.instance.storeTranslation(translation);
    }
    if (_disposed) return;
    _readyPages.putIfAbsent(identity.chapterId, () => {})[identity.pageIndex] =
        translation;
    _updateFontScale(translation);
    _setState(
      identity,
      ComicTranslationPageState(
        ComicTranslationPhase.ready,
        artifact: translation,
        cleanOverlayPng: policy.useCleanOverlay ? ocr.cleanOverlayPng : null,
      ),
    );
  }

  void _updateFontScale(ComicTranslationArtifact artifact) {
    if (_fontScaleResolved) return;
    final samples = artifact.regions
        .where((region) =>
            region.kind != ComicTextKind.soundEffect &&
            region.sourceText.isNotEmpty &&
            region.translatedText.isNotEmpty)
        .map((region) => math.sqrt(
              region.sourceText.runes.length /
                  region.translatedText
                      .replaceAll(comicTranslationBreakMarker, '')
                      .runes
                      .length,
            ).clamp(0.92, 1.10))
        .toList();
    _fontScale.value = samples.isEmpty
        ? 1
        : samples.reduce((sum, value) => sum + value) / samples.length;
    _fontScaleResolved = true;
  }

  List<ComicTranslationContextEntry> _translationContext(
    String chapterId,
    int pageIndex,
  ) {
    final chapter = _readyPages[chapterId] ?? const {};
    final pages = chapter.keys
        .where((page) => page < pageIndex && page >= pageIndex - policy.contextPages)
        .toList()
      ..sort();
    return pages.map((page) {
      final artifact = chapter[page]!;
      final regions = artifact.regions
          .where((region) => region.translatedText.trim().isNotEmpty)
          .toList();
      final grouping = ComicTextGrouping(
        imageWidth: artifact.imageWidth,
        imageHeight: artifact.imageHeight,
        sourceLanguage: artifact.sourceLanguage,
      );
      final ordered = grouping.resolve(regions.map((region) => ComicTextRegion(
        value: region,
        id: region.ocrRegionId,
        text: region.sourceText,
        polygon: region.polygon,
        sourceMaskPolygons: region.sourceMaskPolygons,
        orientation: region.orientation,
        backgroundArgb: region.backgroundArgb,
        bubbleGroupId: region.bubbleGroupId,
        bubblePolygon: region.bubblePolygon,
      )).toList()).expand((group) =>
          group.regions.map((region) => region.value)).toList();
      return ComicTranslationContextEntry(
        pageIndex: page,
        sourceTexts: ordered.map((region) => region.sourceText).toList(),
        translatedTexts:
            ordered.map((region) => region.translatedText).toList(),
      );
    }).toList();
  }

  void _setState(
    ComicTranslationPageIdentity identity,
    ComicTranslationPageState value,
  ) {
    if (!_enabled || _disposed) return;
    _states.putIfAbsent(
      identity.key,
      () => ValueNotifier(ComicTranslationPageState.disabled),
    ).value = value;
  }

  void dispose() {
    _disposed = true;
    _submissionTimer?.cancel();
    unawaited(_cacheSubscription.cancel());
    _queue.clear();
    for (final state in _states.values) {
      state.dispose();
    }
    _fontScale.dispose();
    if (!_running) unawaited(_releaseEngines());
  }

  Future<void> _releaseEngines() async {
    if (_enginesReleased) return;
    _enginesReleased = true;
    final pair = _enginePair;
    if (pair != null) await engines.release(pair);
  }
}

final class _QueuedTranslation {
  final ComicTranslationPageIdentity identity;
  final int priority;

  const _QueuedTranslation(this.identity, this.priority);
}
