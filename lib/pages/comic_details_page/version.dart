part of 'comic_page.dart';

mixin _ComicPageVersion on LoadingState<ComicPage, ComicDetails>, _ComicPageActions {
  List<ComicVersionLink> newVersions = const [];
  ComicVersionAssets? currentVersionAssets;
  List<ComicVersionAssets> oldVersions = const [];
  Future<void>? restoredCacheReuse;
  final Map<String, Future<Res<ComicDetails>>> _versionDetails = {};
  final Map<String, Future<bool>> _matchPreparations = {};
  final Map<String, Future<void>> _reusePreparations = {};
  Future<void>? versionCheck;
  Future<void>? assetsCheck;

  Future<void> _loadNewVersions() async {
    final stopwatch = Stopwatch()..start();
    final versionsFuture = ComicVersionMigration.findVersions(
      comic,
      force: newVersions.isNotEmpty,
    );
    await readerPreparation;
    final predecessors = await ComicVersionMigration.predecessors(comic);
    if (mounted) {
      setState(() => oldVersions = predecessors);
    }
    final versions = await versionsFuture;
    Log.info('ComicPage.Load',
        'version check ${stopwatch.elapsedMilliseconds}ms id=${comic.id}');
    if (mounted && versions.isNotEmpty) {
      setState(() => newVersions = versions);
      unawaited(_loadCurrentVersionAssets());
      _warmCacheReuse(versions);
    }
  }

  Future<void> _loadCurrentVersionAssets() => assetsCheck ??= Future<void>(() async {
    await readerPreparation;
    final assets = await ComicVersionMigration.assets(comic);
    currentVersionAssets = assets;
    if (mounted) setState(() {});
  });

  void _warmCacheReuse(List<ComicVersionLink> versions) {
    if (appdata.settings['reuseOldVersionCache'] != true || versions.isEmpty) {
      return;
    }
    unawaited(Future<void>(() async {
      for (final version in versions) {
        if (!await _matchFor(version)) await _matchFor(version);
      }
    }).then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        Log.error('ComicVersion', error, stack);
      },
    ));
  }

  Future<Res<ComicDetails>> _detailsFor(ComicVersionLink version) {
    final existing = _versionDetails[version.url];
    if (existing != null) return existing;
    late Future<Res<ComicDetails>> future;
    future = comicSource.loadComicInfo!(version.url);
    _versionDetails[version.url] = future;
    future.then((result) {
      if (result.error && identical(_versionDetails[version.url], future)) {
        _versionDetails.remove(version.url);
      }
    }, onError: (Object _, StackTrace __) {
      if (identical(_versionDetails[version.url], future)) {
        _versionDetails.remove(version.url);
      }
    });
    return future;
  }

  Future<void> _reuseFor(ComicVersionLink version) {
    final existing = _reusePreparations[version.url];
    if (existing != null) return existing;
    var prepared = false;
    late Future<void> future;
    future = Future<void>(() async {
      var matched = await _matchFor(version);
      if (!matched) matched = await _matchFor(version);
      if (matched) {
        prepared = await _prepareVersionReuse(version, registerAliases: true);
      } else {
        Log.info(
          'ComicVersion',
          'cache reuse skipped: no page match old=${comic.id} '
              'new=${version.url}',
        );
      }
    });
    _reusePreparations[version.url] = future;
    future.then((_) {
      if (!prepared && identical(_reusePreparations[version.url], future)) {
        _reusePreparations.remove(version.url);
      }
    }, onError: (Object _, StackTrace __) {
      if (identical(_reusePreparations[version.url], future)) {
        _reusePreparations.remove(version.url);
      }
    });
    return future;
  }

  Future<bool> _matchFor(ComicVersionLink version) {
    final existing = _matchPreparations[version.url];
    if (existing != null) return existing;
    late Future<bool> future;
    future = Future<bool>(() =>
        _prepareVersionReuse(version, registerAliases: false));
    _matchPreparations[version.url] = future;
    future.then((matched) {
      if (!matched && identical(_matchPreparations[version.url], future)) {
        _matchPreparations.remove(version.url);
      }
    }, onError: (Object _, StackTrace __) {
      if (identical(_matchPreparations[version.url], future)) {
        _matchPreparations.remove(version.url);
      }
    });
    return future;
  }

  Widget buildVersionUpdate() {
    if (newVersions.isEmpty && oldVersions.isEmpty) {
      return const SizedBox();
    }
    final showAdditional =
        appdata.settings['showAdditionalComicVersions'] == true;
    final hasNew = newVersions.isNotEmpty;
    final rows = <Widget>[
      _versionActionRow(
        viewText: hasNew ? 'View new version' : 'View old version',
        onView: hasNew ? _viewNewVersion : _viewOldVersion,
        showMigrate: true,
        onMigrate: hasNew
            ? currentVersionAssets?.hasValue == true
                ? _migrateNewVersion
                : null
            : oldVersions.any((version) => version.hasValue)
                ? _migrateOldVersion
                : null,
      ),
      if (hasNew && oldVersions.isNotEmpty && showAdditional)
        _versionActionRow(
          viewText: 'View old version',
          onView: _viewOldVersion,
          showMigrate: true,
          onMigrate: oldVersions.any((version) => version.hasValue)
              ? _migrateOldVersion
              : null,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12, right: 16),
      child: Column(
        children: List.generate(rows.length, (index) => Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
          child: rows[index],
        )),
      ),
    );
  }

  Widget _versionActionRow({
    required String viewText,
    required VoidCallback onView,
    bool showMigrate = false,
    VoidCallback? onMigrate,
  }) => Row(
    children: [
      Expanded(
        child: FilledButton(
          onPressed: onView,
          child: Text(viewText.tl),
        ),
      ),
      if (showMigrate) ...[
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton(
            onPressed: onMigrate,
            child: Text('Migrate'.tl),
          ),
        ),
      ],
    ],
  );

  Future<ComicVersionLink?> _chooseNewVersion({bool alwaysShow = false}) async {
    if (newVersions.isEmpty) return null;
    if (!alwaysShow && newVersions.length == 1) return newVersions.single;
    return showDialog<ComicVersionLink>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('New gallery version'.tl),
        children: newVersions.map((item) => SimpleDialogOption(
          onPressed: () => context.pop(item),
          child: ListTile(
            title: Text([
              'Successor version @version'.tlParams({
                'version': item.generation,
              }),
              if (item.date?.isNotEmpty == true) item.date!,
            ].join(' · ')),
            subtitle: Text(item.title.isEmpty ? item.url : item.title),
          ),
        )).toList(),
      ),
    );
  }

  Future<void> _viewNewVersion() async {
    final version = await _chooseNewVersion();
    if (version == null || !mounted) return;
    final details = _detailsFor(version);
    final reuseReady = appdata.settings['reuseOldVersionCache'] == true &&
            !ComicVersionMigration.isCacheReuseRestored(
              comic.sourceKey,
              version.url,
            )
        ? _reuseFor(version)
        : null;
    context.to(() => ComicPage(
      id: version.url,
      sourceKey: comic.sourceKey,
      initialComicInfo: details,
      cacheReuseReady: reuseReady,
    ));
  }

  Future<bool> _prepareVersionReuse(
    ComicVersionLink version, {
    required bool registerAliases,
  }) async {
    await readerPreparation;
    final stopwatch = Stopwatch()..start();
    final phase = registerAliases ? 'cache reuse' : 'page match preparation';
    Log.info(
      'ComicVersion',
      '$phase started old=${comic.id} new=${version.url}',
    );
    var assets = currentVersionAssets;
    if (assets == null) {
      assets = await ComicVersionMigration.assets(comic);
      currentVersionAssets = assets;
    }
    final assetsMs = stopwatch.elapsedMilliseconds;
    if (assets.cachedPages == 0) {
      Log.info('ComicVersion',
          'cache reuse skipped: no cache old=${comic.id}');
      return false;
    }
    final detailResult = await _detailsFor(version);
    final infoMs = stopwatch.elapsedMilliseconds - assetsMs;
    if (detailResult.error) {
      Log.warning('ComicVersion',
          'cache reuse info error=${detailResult.errorMessage} new=${version.url}');
      return false;
    }
    final result = registerAliases
        ? await ComicVersionMigration.prepareCacheReuse(
            oldComic: comic,
            newComic: detailResult.data,
          )
        : await ComicVersionMigration.preparePageMatch(
            oldComic: comic,
            newComic: detailResult.data,
          );
    Log.info(
      'ComicVersion',
      '$phase ${stopwatch.elapsedMilliseconds}ms assets=${assetsMs}ms '
          'info=${infoMs}ms '
          'old=${comic.id} '
          'new=${version.url} ${result.error ? 'error=${result.errorMessage}' : 'pages=${result.data}'}',
    );
    return !result.error;
  }

  Future<ComicVersionAssets?> _chooseOldVersion() async {
    final versions = oldVersions;
    if (versions.length == 1) return versions.single;
    return showDialog<ComicVersionAssets>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Old gallery version'.tl),
        children: List.generate(versions.length, (index) {
          final item = versions[index];
          return SimpleDialogOption(
            onPressed: () => context.pop(item),
            child: ListTile(
              title: Text('Predecessor version @version'.tlParams({
                'version': index + 1,
              })),
              subtitle: Text(item.id),
            ),
          );
        }),
      ),
    );
  }

  Future<void> _viewOldVersion() async {
    final version = await _chooseOldVersion();
    if (version == null || !mounted) return;
    context.to(() => ComicPage(
      id: version.id,
      sourceKey: comic.sourceKey,
    ));
  }

  Future<void> _migrateNewVersion() async {
    final version = await _chooseNewVersion(alwaysShow: true);
    if (version == null || !mounted) return;
    if (currentVersionAssets == null) {
      final loading = showLoadingDialog(
        context,
        barrierDismissible: false,
        allowCancel: false,
        message: 'Checking local data'.tl,
      );
      currentVersionAssets = await ComicVersionMigration.assets(comic);
      loading.close();
      if (!mounted) return;
    }
    await _migrateVersion(comic, version, currentVersionAssets!);
  }

  Future<void> _migrateOldVersion() async {
    final versions = oldVersions.where((version) => version.hasValue).toList();
    final oldVersion = versions.length == 1
        ? versions.single
        : await showDialog<ComicVersionAssets>(
            context: context,
            builder: (context) => SimpleDialog(
              title: Text('Old gallery version'.tl),
              children: List.generate(versions.length, (index) {
                final item = versions[index];
                return SimpleDialogOption(
                  onPressed: () => context.pop(item),
                  child: ListTile(
                    title: Text('Predecessor version @version'.tlParams({
                      'version': index + 1,
                    })),
                    subtitle: Text(item.id),
                  ),
                );
              }),
            ),
          );
    if (oldVersion == null || !mounted) return;
    final loading = showLoadingDialog(
      context,
      barrierDismissible: false,
      allowCancel: false,
      message: 'Loading old version'.tl,
    );
    final result = await comicSource.loadComicInfo!(oldVersion.id);
    loading.close();
    if (!mounted) return;
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
      return;
    }
    await _migrateVersion(
      result.data,
      ComicVersionLink(comic.title, comic.id, comic.uploadTime, 1),
      oldVersion,
    );
  }

  Future<void> _migrateVersion(
    ComicDetails oldComic,
    ComicVersionLink version,
    ComicVersionAssets assets,
  ) async {
    if (!assets.hasValue) {
      final open = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('No reusable local data'.tl),
          content: Text('Opening the new version is safer than migration'.tl),
          actions: [
            TextButton(
              onPressed: () => context.pop(false),
              child: Text('Cancel'.tl),
            ),
            FilledButton(
              onPressed: () => context.pop(true),
              child: Text('Open new version'.tl),
            ),
          ],
        ),
      );
      if (open == true && mounted) _openVersion(version);
      return;
    }
    final mode = await showDialog<ComicVersionMigrationMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Migrate to new version'.tl),
            const SizedBox(height: 4),
            Text(
              [
                'Successor version @version'.tlParams({
                  'version': version.generation,
                }),
                if (version.date?.isNotEmpty == true) version.date!,
              ].join(' · '),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
        children: [
          SimpleDialogOption(
            onPressed: () => context.pop(ComicVersionMigrationMode.incremental),
            child: ListTile(
              leading: const Icon(Icons.move_down),
              title: Text('Incremental migration'.tl),
              subtitle: Text('Reuse matched cache and downloaded pages'.tl),
            ),
          ),
          if (assets.manualDownload)
            SimpleDialogOption(
              onPressed: () => context.pop(ComicVersionMigrationMode.redownload),
              child: ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: Text('Redownload'.tl),
                subtitle: Text('Discard the old manual download'.tl),
              ),
            ),
        ],
      ),
    );
    if (mode == null || !mounted) return;
    final loading = showLoadingDialog(
      context,
      barrierDismissible: false,
      allowCancel: false,
      message: 'Migrating comic version'.tl,
    );
    late Res<ComicVersionMigrationResult> result;
    try {
      result = await ComicVersionMigration.migrate(
        oldComic: oldComic,
        newUrl: version.url,
        mode: mode,
      );
    } catch (error, stack) {
      Log.error('ComicVersion', error, stack);
      loading.close();
      if (mounted) context.showMessage(message: error.toString());
      return;
    }
    loading.close();
    if (!mounted) return;
    if (result.error &&
        mode == ComicVersionMigrationMode.incremental &&
        result.errorMessage == 'No unchanged pages could be matched' &&
        result.subData is ComicVersionMigrationPlan &&
        assets.manualDownload &&
        (result.subData as ComicVersionMigrationPlan).newPages.length >=
            (result.subData as ComicVersionMigrationPlan).oldPages.length) {
      final plan = result.subData as ComicVersionMigrationPlan;
      final delta = plan.newPages.length - plan.oldPages.length;
      final offset = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Select the position of added pages'.tl),
              const SizedBox(height: 4),
              Text(
                'Only continue if the old pages are otherwise unchanged'.tl,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          children: [
            SimpleDialogOption(
              onPressed: () => context.pop(delta),
              child: ListTile(
                title: Text('Added at the beginning'.tl),
                subtitle: Text('Old page 0 becomes page @page'.tlParams({
                  'page': delta,
                })),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => context.pop(0),
              child: ListTile(title: Text('Added at the end'.tl)),
            ),
          ],
        ),
      );
      if (offset == null || !mounted) return;
      final retryLoading = showLoadingDialog(
        context,
        barrierDismissible: false,
        allowCancel: false,
        message: 'Migrating comic version'.tl,
      );
      try {
        result = await ComicVersionMigration.migrate(
          oldComic: oldComic,
          newUrl: version.url,
          mode: mode,
          forcedOffset: offset,
          preparedPlan: plan,
        );
      } catch (error, stack) {
        Log.error('ComicVersion', error, stack);
        retryLoading.close();
        if (mounted) context.showMessage(message: error.toString());
        return;
      }
      retryLoading.close();
      if (!mounted) return;
    }
    if (result.error) {
      if (mode == ComicVersionMigrationMode.incremental &&
          !assets.manualDownload &&
          result.errorMessage == 'No unchanged pages could be matched') {
        final rebuild = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Cache migration is not reliable'.tl),
            content: Text('Rebuild is safer than guessing the page offset'.tl),
            actions: [
              TextButton(
                onPressed: () => context.pop(false),
                child: Text('Cancel'.tl),
              ),
              FilledButton(
                onPressed: () => context.pop(true),
                child: Text('Open new version'.tl),
              ),
            ],
          ),
        );
        if (rebuild == true && mounted) _openVersion(version);
        return;
      }
      context.showMessage(message: result.errorMessage!);
      return;
    }
    final migrated = result.data;
    context.showMessage(message: 'Reused @count pages'.tlParams({
      'count': migrated.reusedPages,
    }));
    context.toReplacement(() => ComicPage(
      id: migrated.comic.id,
      sourceKey: migrated.comic.sourceKey,
      cover: migrated.comic.cover,
      title: migrated.comic.title,
    ));
  }

  void _openVersion(ComicVersionLink version) {
    context.toReplacement(() => ComicPage(
      id: version.url,
      sourceKey: comic.sourceKey,
    ));
  }

}
