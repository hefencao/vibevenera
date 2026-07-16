library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_memory_info/flutter_memory_info.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/custom_slider.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/adaptive_comic.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_version_migration.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/comic_translation/models.dart';
import 'package:venera/foundation/comic_translation/policy.dart';
import 'package:venera/foundation/comic_translation/session.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/animated_image_registry.dart';
import 'package:venera/foundation/image_provider/cache/decoded_image_cache.dart';
import 'package:venera/foundation/image_provider/pipeline/pipeline_controller.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/image_provider/pipeline/resource_entry.dart';
import 'package:venera/foundation/image_provider/renderer/webp_texture_registry.dart';
import 'package:venera/foundation/image_provider/streaming_image.dart';
import 'package:venera/foundation/image_provider/streaming_source_registry.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/clipboard_image.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/volume.dart';
import 'package:window_manager/window_manager.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

part 'scaffold.dart';

part 'images.dart';

part 'gallery_images.dart';

part 'continuous_images.dart';

part 'image_support.dart';

part 'gesture.dart';

part 'comic_image.dart';

part 'translation_overlay.dart';

part 'loading.dart';

part 'chapters.dart';

part 'chapter_comments.dart';

Future<T?> openReader<T>(BuildContext context, Widget Function() builder) =>
    context.to<T>(
      builder,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: const Duration(milliseconds: 300),
      allowSnapshotting: false,
      hideNavigationInLandscape:
          !appdata.settings['showReaderNavigationBar'],
    ).whenComplete(() =>
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

extension _ReaderContext on BuildContext {
  _ReaderState get reader => findAncestorStateOfType<_ReaderState>()!;

  _ReaderScaffoldState get readerScaffold =>
      findAncestorStateOfType<_ReaderScaffoldState>()!;
}

class Reader extends StatefulWidget {
  const Reader({
    super.key,
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    this.initialPage,
    this.initialChapter,
    this.initialChapterGroup,
    required this.author,
    required this.tags,
    this.prepareImages,
  });

  final ComicType type;

  final String author;

  final List<String> tags;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  /// Starts from 1, invalid values equal to 1
  final int? initialPage;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapter;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapterGroup;

  final History history;

  final Future<void>? prepareImages;

  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader>
    with _ReaderLocation, _ReaderWindow, _VolumeListener, _ImagePerPageHandler {
  @override
  void update() {
    setState(() {});
  }

  /// The maximum page number for images only (excluding chapter comments page).
  /// This is used for display purposes and history recording.
  @override
  int get maxPage {
    if (images == null) return 1;
    return !showSingleImageOnFirstPage()
        ? (images!.length / imagesPerPage).ceil()
        : 1 + ((images!.length - 1) / imagesPerPage).ceil();
  }

  /// Total pages including chapter comments page (used for internal page control).
  @override
  int get totalPages {
    var pages = maxPage;
    if (_shouldShowChapterCommentsAtEnd) pages++;
    return pages;
  }

  /// Whether the current page is the chapter comments page.
  @override
  bool get isOnChapterCommentsPage {
    return _shouldShowChapterCommentsAtEnd && _page > maxPage;
  }

  bool get _shouldShowChapterCommentsAtEnd {
    if (mode != ReaderMode.galleryLeftToRight &&
        mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (widget.chapters == null) return false;
    var source = ComicSource.find(type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  @override
  ComicType get type => widget.type;

  @override
  String get cid => widget.cid;

  String get eid => widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0';

  @override
  List<String>? images;

  @override
  late ReaderMode mode;

  @override
  bool get isPortrait =>
      MediaQuery.of(context).orientation == Orientation.portrait;

  History? history;
  AdaptiveComicClassifier? _adaptiveClassifier;
  AdaptiveComicProfile? _pendingAdaptiveProfile;
  bool _adaptiveProfileSaveScheduled = false;
  late ComicTranslationSession translationSession;
  ComicTranslationInteraction _translationInteraction =
      ComicTranslationInteraction.idle;
  final _translationLayers = <_ReaderTranslationLayerState>{};

  bool peekTranslationSourceAt(Offset globalPosition) {
    for (final layer in _translationLayers) {
      if (layer.peekSourceAt(globalPosition)) return true;
    }
    return false;
  }

  @override
  bool isLoading = false;

  var focusNode = FocusNode();

  @override
  void initState() {
    HistoryManager().cacheReaderMetadata(
      id: widget.cid,
      type: widget.type,
      title: widget.name,
      subtitle: widget.author,
      cover: widget.history.cover,
      tags: widget.tags,
      chapters: widget.chapters,
    );
    page = widget.initialPage ?? 1;
    if (page < 1) {
      page = 1;
    }
    chapter = widget.initialChapter ?? 1;
    if (chapter < 1) {
      chapter = 1;
    }
    if (widget.initialChapterGroup != null) {
      for (int i = 0; i < (widget.initialChapterGroup! - 1); i++) {
        chapter += widget.chapters!.getGroupByIndex(i).length;
      }
    }
    if (widget.initialPage != null) {
      page = widget.initialPage!;
      if (page < 1) {
        page = 1;
      }
    }
    if (appdata.settings.needsAdaptiveComicClassification(
      cid,
      type.sourceKey,
    )) {
      final source = type.comicSource;
      _adaptiveClassifier = AdaptiveComicClassifier(
        sourceKey: type.sourceKey,
        comicId: cid,
        title: widget.name,
        author: widget.author,
        tags: widget.tags,
        sourceName: source?.name ?? '',
        sourceUrl: source?.url ?? '',
        sourceType: source?.adaptiveComicType,
      );
      final classifier = _adaptiveClassifier!;
      final metadataProfile = appdata.settings.hasEvaluatedAdaptiveMetadata(
        cid,
        type.sourceKey,
        classifier.metadataFingerprint,
      ) ? null : classifier.classifyMetadata();
      if (metadataProfile != null &&
          appdata.settings.shouldStoreAdaptiveComicProfile(
            cid,
            type.sourceKey,
            metadataProfile,
          )) {
        _storeAdaptiveProfile(metadataProfile);
      }
      if (metadataProfile?.isTerminal == true) {
        _stopAdaptiveClassification();
      } else {
        AnimatedImageRegistry.revision.addListener(_observeKnownAnimations);
      }
    }
    translationSession = _createTranslationSession();
    AnimatedImageRegistry.revision.addListener(_onTranslationAnimationLearned);
    // mode = ReaderMode.fromKey(appdata.settings['readerMode']);
    mode = ReaderMode.fromKey(
      appdata.settings.getReaderSetting(cid, type.sourceKey, 'readerMode'),
    );
    history = widget.history;
    SystemChrome.setEnabledSystemUIMode(
      appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'showSystemStatusBar',
      )
          ? SystemUiMode.edgeToEdge
          : SystemUiMode.immersive,
    );
    if (appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'enableTurnPageByVolumeKey',
    )) {
      handleVolumeEvent();
    }
    setImageCacheSize();
    Future.delayed(const Duration(milliseconds: 200), () {
      LocalFavoritesManager().onRead(cid, type);
    });
    super.initState();
    if (appdata.settings['checkComicVersionInReader'] == true) {
      unawaited(_checkVersionUpdate());
    }
  }

  void observeAdaptivePage(
    String imageKey,
    int pageIndex,
    int width,
    int height,
  ) {
    final classifier = _adaptiveClassifier;
    final totalPages = images?.length;
    if (classifier == null || totalPages == null) return;
    _observeKnownAnimations();
    if (_adaptiveClassifier != classifier) return;
    final profile = classifier.observe(
      imageKey: imageKey,
      pageIndex: pageIndex,
      totalPages: totalPages,
      width: width,
      height: height,
    );
    if (profile == null) return;
    _saveAdaptiveProfile(profile);
  }

  void _observeKnownAnimations() {
    final classifier = _adaptiveClassifier;
    final pages = images;
    if (classifier == null || pages == null) return;
    for (var i = 0; i < pages.length; i++) {
      final imageKey = pages[i];
      final key = AnimatedImageRegistry.key(
        imageKey: imageKey,
        sourceKey: type.comicSource?.key,
        cid: cid,
        eid: eid,
      );
      if (!AnimatedImageRegistry.contains(key)) continue;
      final profile = classifier.observeAnimated(
        imageKey: imageKey,
        pageIndex: i,
        totalPages: pages.length,
      );
      if (profile == null) continue;
      _saveAdaptiveProfile(profile);
      return;
    }
  }

  void _saveAdaptiveProfile(AdaptiveComicProfile profile) {
    final pending = _pendingAdaptiveProfile;
    if (pending != null && pending.confidence >= profile.confidence) return;
    if (pending == null &&
        !appdata.settings.shouldStoreAdaptiveComicProfile(
          cid,
          type.sourceKey,
          profile,
        )) {
      return;
    }
    _pendingAdaptiveProfile = profile;
    if (profile.isTerminal) _stopAdaptiveClassification();
    if (_adaptiveProfileSaveScheduled) return;
    _adaptiveProfileSaveScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _adaptiveProfileSaveScheduled = false;
      final profile = _pendingAdaptiveProfile;
      _pendingAdaptiveProfile = null;
      if (profile == null ||
          !appdata.settings.shouldStoreAdaptiveComicProfile(
            cid,
            type.sourceKey,
            profile,
          )) {
        return;
      }
      if (!mounted) {
        _storeAdaptiveProfile(profile);
        return;
      }
      final previousMode = mode;
      final previousPreload = appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'preloadImageCount',
      );
      _storeAdaptiveProfile(profile);
      syncEffectiveReaderMode();
      final modeChanged = mode != previousMode;
      final preloadChanged = previousPreload !=
          appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'preloadImageCount',
          );
      if (modeChanged) update();
      if (modeChanged || preloadChanged) {
        _attachReaderPipeline(context);
        _reportReaderPage(context, page);
      }
    });
  }

  void _storeAdaptiveProfile(AdaptiveComicProfile profile) {
    Log.info(
      'AdaptiveComic',
      'recognized ${type.sourceKey}/$cid type=${profile.type.name} '
          'confidence=${profile.confidence.toStringAsFixed(3)} '
          'samples=${profile.samples} basis=${profile.basis} '
          'inference=${profile.inferenceMicros}us',
    );
    appdata.settings.setAdaptiveComicProfile(
      cid,
      type.sourceKey,
      profile.toJson(),
    );
    unawaited(appdata.saveData(false));
  }

  void _stopAdaptiveClassification() {
    _adaptiveClassifier = null;
    AnimatedImageRegistry.revision.removeListener(_observeKnownAnimations);
  }

  void syncEffectiveReaderMode() {
    mode = ReaderMode.fromKey(
      appdata.settings.getReaderSetting(cid, type.sourceKey, 'readerMode'),
    );
  }

  Future<void> _checkVersionUpdate() async {
    final version = await ComicVersionMigration.readerUpdate(type.sourceKey, cid);
    if (!mounted || version == null) return;
    context.showMessage(message: 'New gallery version available'.tl);
    ComicVersionMigration.markReaderUpdateNotified(type.sourceKey, cid, version);
  }

  bool _isInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      initImagesPerPage(widget.initialPage ?? 1);
      _isInitialized = true;
    } else {
      // For orientation changed
      _checkImagesPerPageChange();
    }
    initReaderWindow();
  }

  void setImageCacheSize() async {
    var availableRAM = await MemoryInfo.getFreePhysicalMemorySize();
    if (availableRAM == null) return;
    int maxImageCacheSize;
    if (availableRAM < 1 << 30) {
      maxImageCacheSize = 100 << 20;
    } else if (availableRAM < 2 << 30) {
      maxImageCacheSize = 200 << 20;
    } else if (availableRAM < 4 << 30) {
      maxImageCacheSize = 300 << 20;
    } else {
      maxImageCacheSize = 500 << 20;
    }
    Log.info(
      "Reader",
      "Detect available RAM: $availableRAM, set image cache size to $maxImageCacheSize",
    );
    PaintingBinding.instance.imageCache.maximumSizeBytes = maxImageCacheSize;
  }

  @override
  void dispose() {
    _stopAdaptiveClassification();
    AnimatedImageRegistry.revision.removeListener(
      _onTranslationAnimationLearned,
    );
    translationSession.dispose();
    if (isFullscreen) {
      fullscreen();
    }
    autoPageTurningTimer?.cancel();
    focusNode.dispose();
    stopVolumeEvent();
    Future.microtask(() {
      DataSync().onDataChanged();
    });
    PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20;
    disposeReaderWindow();
    super.dispose();
  }

  void _onTranslationAnimationLearned() {
    if (images != null && translationSession.enabled) {
      reportTranslationPage(page);
    }
  }

  ComicTranslationSession _createTranslationSession() {
    final targetSetting = appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'comicTranslationTargetLanguage',
    ) as String;
    final locale = App.locale;
    final targetLanguage = targetSetting == 'system'
        ? [locale.languageCode, locale.countryCode]
            .whereType<String>()
            .join('-')
        : targetSetting;
    return ComicTranslationSession(
      enabled: appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'enableComicTranslation',
      ) as bool,
      sourceLanguage: appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'comicTranslationSourceLanguage',
      ) as String,
      targetLanguage: targetLanguage,
      policy: ComicTranslationPolicy(
        contextPages: appdata.settings.getReaderSetting(
          cid,
          type.sourceKey,
          'comicTranslationContextPages',
        ) as int,
      ),
    );
  }

  ComicTranslationPageIdentity translationIdentity(int pageIndex) {
    final imageKey = images![pageIndex];
    final animatedKey = AnimatedImageRegistry.key(
      imageKey: imageKey,
      sourceKey: type.comicSource?.key,
      cid: cid,
      eid: eid,
    );
    return ComicTranslationPageIdentity(
      imageKey: imageKey,
      sourceKey: type.sourceKey,
      comicId: cid,
      chapterId: eid,
      pageIndex: pageIndex,
      mediaKind: AnimatedImageRegistry.contains(animatedKey)
          ? ComicTranslationMediaKind.animatedImage
          : ComicTranslationMediaKind.staticImage,
    );
  }

  List<ComicTranslationPageIdentity> _translationImagesForPage(
    int logicalPage,
  ) {
    final pages = images;
    if (pages == null || pages.isEmpty || logicalPage < 1) return const [];
    int start, end;
    if (mode.isContinuous) {
      start = logicalPage - 1;
      end = start + 1;
    } else if (showSingleImageOnFirstPage()) {
      if (logicalPage == 1) {
        start = 0;
        end = 1;
      } else {
        start = (logicalPage - 2) * imagesPerPage + 1;
        end = math.min(start + imagesPerPage, pages.length);
      }
    } else {
      start = (logicalPage - 1) * imagesPerPage;
      end = math.min(start + imagesPerPage, pages.length);
    }
    if (start < 0 || start >= pages.length) return const [];
    return [for (var i = start; i < end; i++) translationIdentity(i)];
  }

  void reportTranslationPage(int logicalPage) {
    final current = _translationImagesForPage(logicalPage);
    final near = <ComicTranslationPageIdentity>[];
    for (var page = logicalPage + 1;
        near.length < translationSession.policy.prefetchPages;
        page++) {
      final candidates = _translationImagesForPage(page);
      if (candidates.isEmpty) break;
      near.addAll(candidates.take(
        translationSession.policy.prefetchPages - near.length,
      ));
    }
    translationSession.reportPages(
      current: current,
      near: near,
      interaction: _translationInteraction,
    );
  }

  void setTranslationInteraction(ComicTranslationInteraction interaction) {
    _translationInteraction = interaction;
    translationSession.setInteraction(interaction);
  }

  void syncTranslationSettings() {
    translationSession.dispose();
    translationSession = _createTranslationSession();
    reportTranslationPage(page);
    update();
  }

  @override
  Widget build(BuildContext context) {
    _checkImagesPerPageChange();
    return KeyboardListener(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: onKeyEvent,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) {
              return _ReaderScaffold(
                child: _ReaderGestureDetector(
                  child: _ReaderImages(key: Key(chapter.toString())),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void onKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.f12 && event is KeyUpEvent) {
      fullscreen();
    }
    _imageViewController?.handleKeyEvent(event);
  }

  @override
  int get maxChapter => widget.chapters?.length ?? 1;

  @override
  void onPageChanged() {
    updateHistory();
  }

  /// Prevent multiple history updates in a short time.
  /// `HistoryManager().addHistoryAsync` is a high-cost operation because it creates a new isolate.
  Timer? _updateHistoryTimer;

  void updateHistory() {
    if (history != null) {
      // page >= maxPage handles both last image page and chapter comments page
      if (page >= maxPage) {
        /// Record the last image of chapter
        history!.page = images?.length ?? 1;
      } else {
        /// Record the first image of the page
        if (!showSingleImageOnFirstPage() || imagesPerPage == 1) {
          history!.page = (page - 1) * imagesPerPage + 1;
        } else {
          if (page == 1) {
            history!.page = 1;
          } else {
            history!.page = (page - 2) * imagesPerPage + 2;
          }
        }
      }
      history!.maxPage = images?.length ?? 1;
      if (widget.chapters?.isGrouped ?? false) {
        int g = 0;
        int c = chapter;
        while (c > widget.chapters!.getGroupByIndex(g).length) {
          c -= widget.chapters!.getGroupByIndex(g).length;
          g++;
        }
        history!.readEpisode.add('${g + 1}-$c');
        history!.ep = c;
        history!.group = g + 1;
      } else {
        history!.readEpisode.add(chapter.toString());
        history!.ep = chapter;
      }
      history!.time = DateTime.now();
      _updateHistoryTimer?.cancel();
      _updateHistoryTimer = Timer(const Duration(seconds: 1), () {
        HistoryManager().addHistoryAsync(history!);
        _updateHistoryTimer = null;
      });
    }
  }

  bool get isFirstChapterOfGroup {
    if (widget.chapters?.isGrouped ?? false) {
      int c = chapter - 1;
      int g = 1;
      while (c > 0) {
        c -= widget.chapters!.getGroupByIndex(g - 1).length;
        g++;
      }
      if (c == 0) {
        return true;
      } else {
        return false;
      }
    }
    return chapter == 1;
  }

  bool get isLastChapterOfGroup {
    if (widget.chapters?.isGrouped ?? false) {
      int c = chapter;
      int g = 1;
      while (c > 0) {
        c -= widget.chapters!.getGroupByIndex(g - 1).length;
        g++;
      }
      if (c == 0) {
        return true;
      } else {
        return false;
      }
    }
    return chapter == maxChapter;
  }

  /// Get the size of the reader.
  /// The size is not always the same as the size of the screen.
  Size get size {
    var renderBox = context.findRenderObject() as RenderBox;
    return renderBox.size;
  }
}

abstract mixin class _ImagePerPageHandler {
  late int _lastImagesPerPage;

  late bool _lastOrientation;
  
  /// Track if we were on the chapter comments page before orientation change
  bool _wasOnCommentsPage = false;

  bool get isPortrait;

  int get page;

  set page(int value);

  ReaderMode get mode;

  String get cid;

  ComicType get type;
  
  /// Whether the current page is the chapter comments page
  bool get isOnChapterCommentsPage;
  
  /// Get the max page (excluding comments page)
  int get maxPage;
  
  /// Get images list for calculating maxPage
  List<String>? get images;

  void initImagesPerPage(int initialPage) {
    _lastImagesPerPage = imagesPerPage;
    _lastOrientation = isPortrait;
    _wasOnCommentsPage = false;
    if (imagesPerPage != 1) {
      if (showSingleImageOnFirstPage()) {
        page = ((initialPage - 1) / imagesPerPage).ceil() + 1;
      } else {
        page = (initialPage / imagesPerPage).ceil();
      }
    }
  }

  bool showSingleImageOnFirstPage() => appdata.settings.getReaderSetting(
    cid,
    type.sourceKey,
    'showSingleImageOnFirstPage',
  );

  /// The number of images displayed on one screen
  int get imagesPerPage {
    if (mode.isContinuous) return 1;
    if (isPortrait) {
      return appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerScreenPicNumberForPortrait',
          ) ??
          1;
    } else {
      return appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerScreenPicNumberForLandscape',
          ) ??
          1;
    }
  }
  
  /// Calculate maxPage with a specific imagesPerPage value
  int _calcMaxPage(int imagesPerPageValue) {
    if (images == null) return 1;
    return !showSingleImageOnFirstPage()
        ? (images!.length / imagesPerPageValue).ceil()
        : 1 + ((images!.length - 1) / imagesPerPageValue).ceil();
  }

  /// Check if the number of images per page has changed
  void _checkImagesPerPageChange() {
    int currentImagesPerPage = imagesPerPage;
    bool currentOrientation = isPortrait;

    if (_lastImagesPerPage != currentImagesPerPage ||
        _lastOrientation != currentOrientation) {
      // Calculate old maxPage using old imagesPerPage to correctly determine
      // if we were on the comments page before the orientation change
      int oldMaxPage = _calcMaxPage(_lastImagesPerPage);
      _wasOnCommentsPage = page > oldMaxPage;
      
      _adjustPageForImagesPerPageChange(
        _lastImagesPerPage,
        currentImagesPerPage,
      );
      _lastImagesPerPage = currentImagesPerPage;
      _lastOrientation = currentOrientation;
    }
  }

  /// Adjust the page number when the number of images per page changes
  void _adjustPageForImagesPerPageChange(
    int oldImagesPerPage,
    int newImagesPerPage,
  ) {
    int previousImageIndex = 1;
    if (!showSingleImageOnFirstPage() || oldImagesPerPage == 1) {
      previousImageIndex = (page - 1) * oldImagesPerPage + 1;
    } else {
      if (page == 1) {
        previousImageIndex = 1;
      } else {
        previousImageIndex = (page - 2) * oldImagesPerPage + 2;
      }
    }

    int newPage;
    if (newImagesPerPage != 1) {
      if (showSingleImageOnFirstPage()) {
        newPage = ((previousImageIndex - 1) / newImagesPerPage).ceil() + 1;
      } else {
        newPage = (previousImageIndex / newImagesPerPage).ceil();
      }
    } else {
      newPage = previousImageIndex;
    }

    // Clamp to valid range (1 to maxPage)
    newPage = newPage.clamp(1, maxPage);
    
    // If we were on the comments page, stay on the comments page
    if (_wasOnCommentsPage) {
      page = maxPage + 1;
    } else {
      page = newPage;
    }
  }
}

abstract mixin class _VolumeListener {
  bool toNextPage();

  bool toPrevPage();

  bool toNextChapter();

  bool toPrevChapter({bool toLastPage = false});

  VolumeListener? volumeListener;

  void onDown() {
    if (!toNextPage()) {
      toNextChapter();
    }
  }

  void onUp() {
    if (!toPrevPage()) {
      toPrevChapter(toLastPage: true);
    }
  }

  void handleVolumeEvent() {
    if (!App.isAndroid) {
      // Currently only support Android
      return;
    }
    if (volumeListener != null) {
      volumeListener?.cancel();
    }
    volumeListener = VolumeListener(onDown: onDown, onUp: onUp)..listen();
  }

  void stopVolumeEvent() {
    if (volumeListener != null) {
      volumeListener?.cancel();
      volumeListener = null;
    }
  }
}

abstract mixin class _ReaderLocation {
  int _page = 1;
  int? _pendingPage;

  /// Flag to indicate that the page should jump to the last page after images are loaded.
  bool _jumpToLastPageOnLoad = false;

  int get page => _page;

  set page(int value) {
    _page = value;
    onPageChanged();
  }

  int chapter = 1;

  int get maxPage;

  /// Total pages including chapter comments page (for internal page control).
  int get totalPages;

  int get maxChapter;

  bool get isLoading;

  String get cid;

  ComicType get type;

  void update();

  bool enablePageAnimation(String cid, ComicType type) => appdata.settings
      .getReaderSetting(cid, type.sourceKey, 'enablePageAnimation');

  _ImageViewController? _imageViewController;

  void onPageChanged();

  void setPage(int page) {
    // Prevent page change during animation
    if (_animationCount > 0 && _pendingPage != null && page != _pendingPage) {
      return;
    }
    this.page = page;
  }

  bool _validatePage(int page) {
    return page >= 1 && page <= totalPages;
  }

  /// Returns true if the page is changed
  bool toNextPage() {
    return toPage(page + 1);
  }

  /// Returns true if the page is changed
  bool toPrevPage() {
    return toPage(page - 1);
  }

  int _animationCount = 0;

  bool toPage(int page) {
    if (_validatePage(page)) {
      if (page == this.page && page != 1 && page != totalPages) {
        return false;
      }
      final hasAnimation = enablePageAnimation(cid, type);
      if (hasAnimation && (page - this.page).abs() <= 1) {
        _pendingPage = page;
        _animationCount++;
        update();
        _imageViewController!.animateToPage(page).then((_) {
          _animationCount--;
          if (_pendingPage == page) {
            _pendingPage = null;
          }
          update();
        });
      } else {
        this.page = page;
        update();
        _imageViewController!.toPage(page);
      }
      return true;
    }
    return false;
  }

  bool get isPageAnimating => _animationCount > 0;

  bool _validateChapter(int chapter) {
    return chapter >= 1 && chapter <= maxChapter;
  }

  /// Returns true if the chapter is changed
  bool toNextChapter() {
    return toChapter(chapter + 1);
  }

  /// Returns true if the chapter is changed
  /// If [toLastPage] is true, the page will be set to the last page of the previous chapter.
  bool toPrevChapter({bool toLastPage = false}) {
    return toChapter(chapter - 1, toLastPage: toLastPage);
  }

  bool toChapter(int c, {bool toLastPage = false}) {
    if (_validateChapter(c) && !isLoading) {
      chapter = c;
      page = 1;
      _jumpToLastPageOnLoad = toLastPage;
      update();
      return true;
    }
    return false;
  }

  Timer? autoPageTurningTimer;

  void autoPageTurning(String cid, ComicType type) {
    if (autoPageTurningTimer != null) {
      autoPageTurningTimer!.cancel();
      autoPageTurningTimer = null;
    } else {
      int interval = appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'autoPageTurningInterval',
      );
      autoPageTurningTimer = Timer.periodic(Duration(seconds: interval), (_) {
        if (page == maxPage) {
          autoPageTurningTimer!.cancel();
        }
        toNextPage();
      });
    }
  }
}

mixin class _ReaderWindow {
  bool isFullscreen = false;

  late WindowFrameController windowFrame;

  bool _isInit = false;

  void initReaderWindow() {
    if (!App.isDesktop || _isInit) return;
    windowFrame = WindowFrame.of(App.rootContext);
    windowFrame.addCloseListener(onWindowClose);
    _isInit = true;
  }

  void fullscreen() async {
    if (!App.isDesktop) return;
    await windowManager.hide();
    await windowManager.setFullScreen(!isFullscreen);
    await windowManager.show();
    isFullscreen = !isFullscreen;
    WindowFrame.of(App.rootContext).setWindowFrame(!isFullscreen);
  }

  bool onWindowClose() {
    if (Navigator.of(App.rootContext).canPop()) {
      Navigator.of(App.rootContext).pop();
      return false;
    } else {
      return true;
    }
  }

  void disposeReaderWindow() {
    if (!App.isDesktop) return;
    windowFrame.removeCloseListener(onWindowClose);
  }
}

enum ReaderMode {
  galleryLeftToRight('galleryLeftToRight'),
  galleryRightToLeft('galleryRightToLeft'),
  galleryTopToBottom('galleryTopToBottom'),
  continuousTopToBottom('continuousTopToBottom'),
  continuousLeftToRight('continuousLeftToRight'),
  continuousRightToLeft('continuousRightToLeft');

  final String key;

  bool get isGallery => key.startsWith('gallery');

  bool get isContinuous => key.startsWith('continuous');

  const ReaderMode(this.key);

  static ReaderMode fromKey(String key) {
    for (var mode in values) {
      if (mode.key == key) {
        return mode;
      }
    }
    return galleryLeftToRight;
  }
}

abstract interface class _ImageViewController {
  void toPage(int page);

  Future<void> animateToPage(int page);

  bool turnViewport(bool forward);

  void handleDoubleTap(Offset location);

  void handleLongPressDown(Offset location);

  void handleLongPressUp(Offset location);

  void handleKeyEvent(KeyEvent event);

  /// Returns true if the event is handled.
  bool handleOnTap(Offset location);

  Future<Uint8List?> getImageByOffset(Offset offset);

  String? getImageKeyByOffset(Offset offset);

  /// WebP 三级缓存（生命周期绑定到具体的视图模式 State）。
  /// [FIX-ARCH-2] 提升到接口，消除 `is _GalleryModeState` / `is _ContinuousModeState` 类型检查。
  DecodedImageCache get streamingCache;
}
