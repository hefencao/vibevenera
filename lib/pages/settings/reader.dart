part of 'settings_page.dart';

class ReaderSettings extends StatefulWidget {
  const ReaderSettings({
    super.key,
    this.onChanged,
    this.comicId,
    this.comicSource,
  });

  final void Function(String key)? onChanged;
  final String? comicId;
  final String? comicSource;

  @override
  State<ReaderSettings> createState() => _ReaderSettingsState();
}

class _ReaderSettingsState extends State<ReaderSettings> {
  dynamic _settingValue(String key) {
    if (widget.comicId != null && widget.comicSource != null) {
      return appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        key,
      );
    }
    return appdata.settings.getDeviceReaderSetting(key);
  }

  String _adaptiveProfileText(Map<String, dynamic>? profile) {
    if (profile == null) return 'Waiting for content page recognition'.tl;
    final type = switch (profile['type']) {
      'vertical' => 'Vertical comic'.tl,
      'paged' => 'Paged comic'.tl,
      'animated' => 'Animated comic'.tl,
      _ => 'Mixed comic'.tl,
    };
    final confidence = ((profile['confidence'] as num) * 100).round();
    return '$type · $confidence%';
  }

  bool _isChapterCommentsAtEndSupported() {
    final readerMode = _settingValue('readerMode') as String?;
    final showChapterComments = _settingValue('showChapterComments') as bool?;

    // Must have showChapterComments enabled and be in gallery mode
    if (showChapterComments != true) return false;

    return readerMode == 'galleryLeftToRight' ||
        readerMode == 'galleryRightToLeft';
  }

  void _onShowChapterCommentsChanged() {
    // When showChapterComments is turned off, also turn off showChapterCommentsAtEnd
    bool? showChapterComments;

    if (widget.comicId != null &&
        widget.comicSource != null &&
        appdata.settings.isComicSpecificSettingsEnabled(
          widget.comicId,
          widget.comicSource,
        )) {
      showChapterComments = appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        'showChapterComments',
      );
      if (showChapterComments != true) {
        appdata.settings.setReaderSetting(
          widget.comicId!,
          widget.comicSource!,
          'showChapterCommentsAtEnd',
          false,
        );
      }
    } else {
      showChapterComments = appdata.settings['showChapterComments'] as bool?;
      if (showChapterComments != true) {
        appdata.settings['showChapterCommentsAtEnd'] = false;
      }
    }

    setState(() {});
    widget.onChanged?.call("showChapterComments");
  }

  @override
  Widget build(BuildContext context) {
    final comicId = widget.comicId;
    final sourceKey = widget.comicSource;
    final key = "$comicId@$sourceKey";

    bool isEnabledSpecificSettings =
        comicId != null &&
        appdata.settings.isComicSpecificSettingsEnabled(comicId, sourceKey);
    bool useDeviceSpecificSettings =
        !isEnabledSpecificSettings &&
        appdata.settings.isDeviceSpecificSettingsEnabled();

    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Reading".tl)),
        if (comicId != null && sourceKey != null)
          SliverMainAxisGroup(
            slivers: [
              SwitchListTile(
                title: Text("Enable comic specific settings".tl),
                value: isEnabledSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledComicSpecificSettings(
                      comicId,
                      sourceKey,
                      b,
                    );
                  });
                  widget.onChanged?.call('readerMode');
                },
              ).toSliver(),
              if (appdata.settings['adaptiveComicType'] == true)
                SwitchListTile(
                  title: Text('Use adaptive settings for this comic'.tl),
                  subtitle: Text(_adaptiveProfileText(
                    appdata.settings.adaptiveComicProfile(comicId, sourceKey),
                  )),
                  value: appdata.settings.isAdaptiveComicEnabled(
                    comicId,
                    sourceKey,
                  ),
                  onChanged: (value) {
                    setState(() {
                      appdata.settings.setAdaptiveComicEnabled(
                        comicId,
                        sourceKey,
                        value,
                      );
                    });
                    appdata.saveData(false);
                    widget.onChanged?.call('adaptiveComicType');
                  },
                ).toSliver(),
              if (isEnabledSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetComicReaderSettings(key);
                      });
                    },
                    child: Text(
                      "Clear specific reader settings for this comic".tl,
                    ),
                  ),
                ).toSliver(),
              Divider().toSliver(),
            ],
          ),
        if (comicId == null)
          SliverMainAxisGroup(
            slivers: [
              SwitchListTile(
                title: Text("Enable device specific settings".tl),
                value: useDeviceSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledDeviceSpecificSettings(b);
                  });
                  appdata.saveData();
                },
              ).toSliver(),
              if (useDeviceSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetDeviceReaderSettings();
                      });
                      appdata.saveData();
                    },
                    child: Text(
                      "Clear specific reader settings for this device".tl,
                    ),
                  ),
                ).toSliver(),
              Divider().toSliver(),
            ],
          ),
        if (comicId == null) ...[
          _SwitchSetting(
            title: 'Adaptive comic type'.tl,
            subtitle: 'Infer reading mode and gestures from content pages'.tl,
            settingKey: 'adaptiveComicType',
          ).toSliver(),
          const Divider().toSliver(),
          _SwitchSetting(
            title: 'Check for gallery updates when opening reader'.tl,
            subtitle: 'Notify only once for each new version'.tl,
            settingKey: 'checkComicVersionInReader',
          ).toSliver(),
          const _ComicVersionAutoMigrationSetting().toSliver(),
          _SwitchSetting(
            title: 'Directly reuse old-version cache'.tl,
            subtitle: 'Reuse only after unchanged pages are verified'.tl,
            settingKey: 'reuseOldVersionCache',
          ).toSliver(),
          _SwitchSetting(
            title: 'Enable additional version view'.tl,
            subtitle: 'Show both newer and older version actions'.tl,
            settingKey: 'showAdditionalComicVersions',
          ).toSliver(),
          const Divider().toSliver(),
        ],
        _SwitchSetting(
          title: 'Comic translation'.tl,
          subtitle: 'Recognize and translate text without replacing source images'.tl,
          settingKey: 'enableComicTranslation',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('comicTranslation');
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: _settingValue('enableComicTranslation') == true,
          child: SelectSetting(
            title: 'Source language'.tl,
            help: 'Automatic source language does not support Korean; select Korean to use the dedicated recognizer'.tl,
            settingKey: 'comicTranslationSourceLanguage',
            optionTranslation: {
              'auto': 'Automatic'.tl,
              'ja': 'Japanese'.tl,
              'ko': 'Korean'.tl,
              'zh': 'Chinese'.tl,
              'en': 'English'.tl,
            },
            onChanged: () => widget.onChanged?.call('comicTranslation'),
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: _settingValue('enableComicTranslation') == true,
          child: SelectSetting(
            title: 'Target language'.tl,
            settingKey: 'comicTranslationTargetLanguage',
            optionTranslation: {
              'system': 'Follow system'.tl,
              'zh-CN': 'Simplified Chinese'.tl,
              'zh-TW': 'Traditional Chinese'.tl,
              'en-US': 'English'.tl,
              'ja-JP': 'Japanese'.tl,
              'ko-KR': 'Korean'.tl,
            },
            onChanged: () => widget.onChanged?.call('comicTranslation'),
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: _settingValue('enableComicTranslation') == true,
          child: _SliderSetting(
            title: 'Translation context pages'.tl,
            settingsIndex: 'comicTranslationContextPages',
            interval: 1,
            min: 0,
            max: 4,
            onChanged: () => widget.onChanged?.call('comicTranslation'),
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: _settingValue('enableComicTranslation') == true,
          child: _SwitchSetting(
            title: 'Translate sound effects'.tl,
            subtitle: 'May erase large artwork when recognition is inaccurate'.tl,
            settingKey: 'comicTranslationSoundEffects',
            onChanged: () => widget.onChanged?.call('comicTranslation'),
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: _settingValue('enableComicTranslation') == true,
          child: _SwitchSetting(
            title: 'Use clean translation overlay'.tl,
            subtitle: 'Improves source text removal but may increase page transition raster cost'.tl,
            settingKey: 'comicTranslationCleanOverlay',
            onChanged: () => widget.onChanged?.call('comicTranslation'),
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        const Divider().toSliver(),
        if (widget.comicId == null)
          ListTile(
            leading: const Icon(Icons.translate),
            title: Text('Translation models and API'.tl),
            subtitle: Text('Configure OCR models, remote LLM and benchmark'.tl),
            trailing: const Icon(Icons.arrow_right),
            onTap: () => context.to(
              () => const ComicTranslationBackendPage(),
            ),
          ).toSliver(),
        _SwitchSetting(
          title: "Tap to turn Pages".tl,
          settingKey: "enableTapToTurnPages",
          onChanged: () {
            widget.onChanged?.call("enableTapToTurnPages");
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Reverse tap to turn Pages".tl,
          settingKey: "reverseTapToTurnPages",
          onChanged: () {
            widget.onChanged?.call("reverseTapToTurnPages");
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Page animation".tl,
          settingKey: "enablePageAnimation",
          onChanged: () {
            widget.onChanged?.call("enablePageAnimation");
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SelectSetting(
          title: "Reading mode".tl,
          settingKey: "readerMode",
          optionTranslation: {
            "galleryLeftToRight": "Gallery (Left to Right)".tl,
            "galleryRightToLeft": "Gallery (Right to Left)".tl,
            "galleryTopToBottom": "Gallery (Top to Bottom)".tl,
            "continuousLeftToRight": "Continuous (Left to Right)".tl,
            "continuousRightToLeft": "Continuous (Right to Left)".tl,
            "continuousTopToBottom": "Continuous (Top to Bottom)".tl,
          },
          onChanged: () {
            setState(() {});
            var readerMode = appdata.settings['readerMode'];
            if (readerMode?.toLowerCase().startsWith('continuous') ?? false) {
              appdata.settings['readerScreenPicNumberForLandscape'] = 1;
              widget.onChanged?.call('readerScreenPicNumberForLandscape');
              appdata.settings['readerScreenPicNumberForPortrait'] = 1;
              widget.onChanged?.call('readerScreenPicNumberForPortrait');
            }
            widget.onChanged?.call("readerMode");
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SliderSetting(
          title: "Auto page turning interval".tl,
          settingsIndex: "autoPageTurningInterval",
          interval: 1,
          min: 1,
          max: 20,
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("autoPageTurningInterval");
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: (_settingValue('readerMode') as String).startsWith('gallery'),
          child: _SliderSetting(
            title:
                "The number of pic in screen for landscape (Only Gallery Mode)"
                    .tl,
            settingsIndex: "readerScreenPicNumberForLandscape",
            interval: 1,
            min: 1,
            max: 5,
            onChanged: () {
              setState(() {});
              widget.onChanged?.call("readerScreenPicNumberForLandscape");
            },
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: (_settingValue('readerMode') as String).startsWith('gallery'),
          child: _SliderSetting(
            title:
                "The number of pic in screen for portrait (Only Gallery Mode)"
                    .tl,
            settingsIndex: "readerScreenPicNumberForPortrait",
            interval: 1,
            min: 1,
            max: 5,
            onChanged: () {
              widget.onChanged?.call("readerScreenPicNumberForPortrait");
            },
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible:
              (_settingValue('readerMode') as String).startsWith('gallery') &&
              (_settingValue('readerScreenPicNumberForLandscape') > 1 ||
                  _settingValue('readerScreenPicNumberForPortrait') > 1),
          child: _SwitchSetting(
            title: "Show single image on first page".tl,
            settingKey: "showSingleImageOnFirstPage",
            onChanged: () {
              widget.onChanged?.call("showSingleImageOnFirstPage");
            },
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: (_settingValue('readerMode') as String).startsWith('continuous'),
          child: _SliderSetting(
            title: "Mouse scroll speed".tl,
            settingsIndex: "readerScrollSpeed",
            interval: 0.1,
            min: 0.5,
            max: 3,
            onChanged: () {
              widget.onChanged?.call("readerScrollSpeed");
            },
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        _SwitchSetting(
          title: 'Double tap to zoom'.tl,
          settingKey: 'enableDoubleTapToZoom',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('enableDoubleTapToZoom');
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: 'Long press to zoom'.tl,
          settingKey: 'enableLongPressToZoom',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('enableLongPressToZoom');
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: _settingValue('enableLongPressToZoom') == true,
          child: SelectSetting(
            title: "Long press zoom position".tl,
            settingKey: "longPressZoomPosition",
            optionTranslation: {
              "press": "Press position".tl,
              "center": "Screen center".tl,
            },
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        _SwitchSetting(
          title: 'Limit image width'.tl,
          subtitle: 'When using Continuous(Top to Bottom) mode'.tl,
          settingKey: 'limitImageWidth',
          onChanged: () {
            widget.onChanged?.call('limitImageWidth');
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        if (App.isAndroid)
          _SwitchSetting(
            title: 'Turn page by volume keys'.tl,
            settingKey: 'enableTurnPageByVolumeKey',
            onChanged: () {
              widget.onChanged?.call('enableTurnPageByVolumeKey');
            },
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
        _SwitchSetting(
          title: "Display time & battery info in reader".tl,
          settingKey: "enableClockAndBatteryInfoInReader",
          onChanged: () {
            widget.onChanged?.call("enableClockAndBatteryInfoInReader");
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Show system status bar".tl,
          settingKey: "showSystemStatusBar",
          onChanged: () {
            widget.onChanged?.call("showSystemStatusBar");
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: 'Show navigation bar in reader landscape mode'.tl,
          settingKey: 'showReaderNavigationBar',
        ).toSliver(),
        SelectSetting(
          title: "Quick collect image".tl,
          settingKey: "quickCollectImage",
          optionTranslation: {
            "No": "Not enable".tl,
            "DoubleTap": "Double Tap".tl,
            "Swipe": "Swipe".tl,
          },
          onChanged: () {
            widget.onChanged?.call("quickCollectImage");
          },
          help:
              "On the image browsing page, you can quickly collect images by sliding horizontally or vertically according to your reading mode"
                  .tl,
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _CallbackSetting(
          title: "Custom Image Processing".tl,
          callback: () => context.to(() => _CustomImageProcessing()),
          actionTitle: "Edit".tl,
        ).toSliver(),
        _SliderSetting(
          title: "Number of images preloaded".tl,
          settingsIndex: "preloadImageCount",
          interval: 1,
          min: 1,
          max: 16,
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Show Page Number".tl,
          settingKey: "showPageNumberInReader",
          onChanged: () {
            widget.onChanged?.call("showPageNumberInReader");
          },
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Show Chapter Comments".tl,
          settingKey: "showChapterComments",
          onChanged: _onShowChapterCommentsChanged,
          comicId: widget.comicId,
          comicSource: widget.comicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: _isChapterCommentsAtEndSupported(),
          child: _SwitchSetting(
            title: "Show Comments at Chapter End".tl,
            settingKey: "showChapterCommentsAtEnd",
            onChanged: () {
              widget.onChanged?.call("showChapterCommentsAtEnd");
            },
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
      ],
    );
  }
}

class _ComicVersionAutoMigrationSetting extends StatefulWidget {
  const _ComicVersionAutoMigrationSetting();

  @override
  State<_ComicVersionAutoMigrationSetting> createState() =>
      _ComicVersionAutoMigrationSettingState();
}

class _ComicVersionAutoMigrationSettingState
    extends State<_ComicVersionAutoMigrationSetting> {
  List<String> get selected {
    final value = appdata.settings['comicVersionAutoMigration'];
    if (value is List) return List<String>.from(value);
    return value == 'none' ? [] : [value as String];
  }

  void toggle(String value, bool enabled) {
    final values = selected;
    enabled ? values.add(value) : values.remove(value);
    appdata.settings['comicVersionAutoMigration'] = values.toSet().toList();
    appdata.saveData();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final values = selected;
    final limit = appdata.settings['comicVersionHistoryLimit'] as int;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text('Automatic gallery version migration'.tl),
          subtitle: Text(
            'Automatic migration execution is reserved for a later version'.tl,
          ),
        ),
        CheckboxListTile(
          title: Text('Favorites'.tl),
          value: values.contains('favorites'),
          onChanged: (value) => toggle('favorites', value!),
        ),
        CheckboxListTile(
          title: Text('Recent history'.tl),
          value: values.contains('recentHistory'),
          onChanged: (value) => toggle('recentHistory', value!),
        ),
        if (values.contains('recentHistory'))
          ListTile(
            title: Text('Number of recent comics'.tl),
            trailing: Text(limit == 16 ? 'All'.tl : '$limit'),
            subtitle: Slider(
              value: limit.toDouble(),
              min: 0,
              max: 16,
              divisions: 16,
              onChanged: (value) {
                appdata.settings['comicVersionHistoryLimit'] = value.toInt();
                appdata.saveData();
                setState(() {});
              },
            ),
          ),
        CheckboxListTile(
          title: Text('When opening details'.tl),
          value: values.contains('onDetails'),
          onChanged: (value) => toggle('onDetails', value!),
        ),
      ],
    );
  }
}

class _CustomImageProcessing extends StatefulWidget {
  const _CustomImageProcessing();

  @override
  State<_CustomImageProcessing> createState() => __CustomImageProcessingState();
}

class __CustomImageProcessingState extends State<_CustomImageProcessing> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = appdata.settings['customImageProcessing'];
  }

  @override
  void dispose() {
    appdata.settings['customImageProcessing'] = current;
    appdata.saveData();
    super.dispose();
  }

  int resetKey = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Custom Image Processing".tl),
        actions: [
          TextButton(
            onPressed: () {
              current = defaultCustomImageProcessing;
              appdata.settings['customImageProcessing'] = current;
              resetKey++;
              setState(() {});
            },
            child: Text("Reset".tl),
          ),
        ],
      ),
      body: Column(
        children: [
          _SwitchSetting(
            title: "Enable".tl,
            settingKey: "enableCustomImageProcessing",
          ),
          Expanded(
            child: Container(
              margin: EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: context.colorScheme.outlineVariant),
              ),
              child: SizedBox.expand(
                child: CodeEditor(
                  key: ValueKey(resetKey),
                  initialValue: appdata.settings['customImageProcessing'],
                  onChanged: (value) {
                    current = value;
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
