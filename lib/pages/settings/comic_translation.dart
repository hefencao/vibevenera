part of 'settings_page.dart';

class ComicTranslationBackendPage extends StatefulWidget {
  const ComicTranslationBackendPage({super.key});

  @override
  State<ComicTranslationBackendPage> createState() =>
      _ComicTranslationBackendPageState();
}

class _ComicTranslationBackendPageState
    extends State<ComicTranslationBackendPage> {
  late String backend;
  late String activeProfileId;
  late List<ComicTranslationRemoteProfile> profiles;
  late final TextEditingController profileName;
  late final TextEditingController endpoint;
  late final TextEditingController model;
  late final TextEditingController additionalPrompt;
  final apiKey = TextEditingController();
  bool working = false;

  @override
  void initState() {
    backend = appdata.settings['comicTranslationBackend'] as String;
    profiles = (appdata.settings['comicTranslationRemoteProfiles'] as List)
        .map((value) => ComicTranslationRemoteProfile.fromJson(
              Map<String, dynamic>.from(value as Map),
            ))
        .toList();
    if (profiles.isEmpty) {
      profiles.add(ComicTranslationRemoteProfile(
        id: 'default',
        name: appdata.settings['comicTranslationRemoteModel'] as String,
        endpoint: appdata.settings['comicTranslationRemoteEndpoint'] as String,
        model: appdata.settings['comicTranslationRemoteModel'] as String,
        additionalPrompt:
            appdata.settings['comicTranslationAdditionalPrompt'] as String,
      ));
    }
    activeProfileId = appdata.settings['comicTranslationRemoteProfile'] as String;
    if (!profiles.any((profile) => profile.id == activeProfileId)) {
      activeProfileId = profiles.first.id;
    }
    final profile = _activeProfile;
    profileName = TextEditingController(text: profile.name);
    endpoint = TextEditingController(
      text: profile.endpoint,
    );
    model = TextEditingController(
      text: profile.model,
    );
    additionalPrompt = TextEditingController(
      text: profile.additionalPrompt,
    );
    super.initState();
  }

  @override
  void dispose() {
    profileName.dispose();
    endpoint.dispose();
    model.dispose();
    additionalPrompt.dispose();
    apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final models = ComicTranslationModelManager.instance;
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Translation models and API'.tl)),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: Text('Local OCR model'.tl),
                subtitle: Text(
                  models.installed
                      ? '${ComicTranslationModelManager.bundle.displayName} · ${_modelSize(ComicTranslationModelManager.bundle.bytes)}'
                      : 'Not installed'.tl,
                ),
              ),
              if (!App.isAndroid)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Local OCR is currently available on Android only.'.tl),
                )
              else
                ValueListenableBuilder<ComicTranslationModelProgress>(
                  valueListenable: models.progress,
                  builder: (context, progress, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (progress.phase != ComicTranslationModelPhase.idle) ...[
                        LinearProgressIndicator(value: progress.fraction),
                        Text(
                          progress.phase == ComicTranslationModelPhase.verifying
                              ? 'Verifying model'.tl
                              : '${'Downloading model'.tl} · ${progress.fileName}',
                          textAlign: TextAlign.center,
                          style: ts.s12,
                        ).paddingVertical(6),
                      ],
                      Align(
                        alignment: Alignment.centerRight,
                        child: models.installed
                            ? FilledButton.tonalIcon(
                                onPressed: models.installing ? null : _removeModel,
                                icon: const Icon(Icons.delete_outline),
                                label: Text('Remove'.tl),
                              )
                            : FilledButton.icon(
                                onPressed: models.installing ? null : _installModel,
                                icon: const Icon(Icons.download_outlined),
                                label: Text('Download model'.tl),
                              ),
                      ).paddingHorizontal(16),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'PP-OCRv6 small is downloaded from the official PaddlePaddle repository and verified with SHA-256. The local OCR image never leaves the device.'.tl,
                  style: ts.s12,
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => launchUrlString(
                      'https://www.paddleocr.ai/main/version3.x/inference_deployment/cross_platform/android_deployment.html',
                    ),
                    icon: const Icon(Icons.download_outlined),
                    label: Text('Model download guide'.tl),
                  ),
                  TextButton.icon(
                    onPressed: () => launchUrlString(
                      'https://www.paddleocr.ai/main/version3.x/model_list.html',
                    ),
                    icon: const Icon(Icons.list_alt),
                    label: Text('Model list'.tl),
                  ),
                  TextButton(
                    onPressed: () => launchUrlString(
                      'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx',
                    ),
                    child: const Text('PP-OCRv6 small det'),
                  ),
                  TextButton(
                    onPressed: () => launchUrlString(
                      'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx',
                    ),
                    child: const Text('PP-OCRv6 small rec'),
                  ),
                ],
              ).paddingHorizontal(8),
              const Divider(),
              ListTile(
                title: Text('Translation backend'.tl),
                trailing: DropdownButton<String>(
                  value: backend,
                  items: [
                    DropdownMenuItem(value: 'none', child: Text('Disabled'.tl)),
                    DropdownMenuItem(
                      value: 'openaiCompatible',
                      child: Text('OpenAI-compatible API'.tl),
                    ),
                  ],
                  onChanged: (value) => setState(() => backend = value!),
                ),
              ),
              if (backend == 'openaiCompatible') ...[
                ListTile(
                  title: Text('Saved remote model'.tl),
                  trailing: DropdownButton<String>(
                    value: activeProfileId,
                    items: profiles.map((profile) => DropdownMenuItem(
                      value: profile.id,
                      child: SizedBox(
                        width: 150,
                        child: Text(
                          profile.name.isNotEmpty
                              ? profile.name
                              : profile.model.isNotEmpty
                                  ? profile.model
                                  : 'Remote model'.tl,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )).toList(),
                    onChanged: working ? null : (value) => _selectProfile(value!),
                  ),
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: working ? null : _newProfile,
                      icon: const Icon(Icons.add),
                      label: Text('Save as new'.tl),
                    ),
                    TextButton.icon(
                      onPressed: working ? null : _deleteProfile,
                      icon: const Icon(Icons.delete_outline),
                      label: Text('Delete profile'.tl),
                    ),
                  ],
                ).paddingHorizontal(16),
                TextField(
                  controller: profileName,
                  decoration: InputDecoration(
                    labelText: 'Profile name'.tl,
                    border: const OutlineInputBorder(),
                  ),
                ).paddingHorizontal(16).paddingVertical(6),
                TextField(
                  controller: endpoint,
                  decoration: InputDecoration(
                    labelText: 'Chat Completions endpoint'.tl,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ).paddingHorizontal(16).paddingVertical(6),
                TextField(
                  controller: model,
                  decoration: InputDecoration(
                    labelText: 'Model'.tl,
                    border: const OutlineInputBorder(),
                  ),
                ).paddingHorizontal(16).paddingVertical(6),
                TextField(
                  controller: additionalPrompt,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: 'Additional translation instructions'.tl,
                    helperText:
                        'Appended to the built-in format rules; use it for names, terminology and style.'.tl,
                    border: const OutlineInputBorder(),
                  ),
                ).paddingHorizontal(16).paddingVertical(6),
                TextField(
                  controller: apiKey,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'API key'.tl,
                    hintText: ComicTranslationSecrets.instance
                            .hasApiKey(activeProfileId)
                        ? 'Configured; leave empty to keep it'.tl
                        : null,
                    border: const OutlineInputBorder(),
                  ),
                ).paddingHorizontal(16).paddingVertical(6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'The API key is stored only in the local app data directory and is excluded from data sync. Desktop storage is not encrypted.'.tl,
                    style: ts.s12,
                  ),
                ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  if (ComicTranslationSecrets.instance
                      .hasApiKey(activeProfileId))
                    TextButton(
                      onPressed: working ? null : _clearApiKey,
                      child: Text('Clear API key'.tl),
                    ),
                  FilledButton(
                    onPressed: working ? null : _save,
                    child: Text('Save'.tl),
                  ),
                  if (backend == 'openaiCompatible')
                    FilledButton.tonal(
                      onPressed: working ? null : _testRemote,
                      child: Text('Save and test'.tl),
                    ),
                ],
              ).paddingAll(16),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.speed),
                title: Text('Translation benchmark'.tl),
                subtitle: Text('Select a local comic page and measure model load, OCR, translation and RSS.'.tl),
                trailing: const Icon(Icons.arrow_right),
                onTap: () => context.to(
                  () => const _ComicTranslationBenchmarkPage(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  ComicTranslationRemoteProfile get _activeProfile =>
      profiles.firstWhere((profile) => profile.id == activeProfileId);

  ComicTranslationRemoteProfile _profileFromFields(String id) =>
      ComicTranslationRemoteProfile(
        id: id,
        name: profileName.text.trim().isEmpty
            ? model.text.trim()
            : profileName.text.trim(),
        endpoint: endpoint.text.trim(),
        model: model.text.trim(),
        additionalPrompt: additionalPrompt.text.trim(),
      );

  void _updateActiveProfile() {
    final index = profiles.indexWhere((profile) => profile.id == activeProfileId);
    profiles[index] = _profileFromFields(activeProfileId);
  }

  void _applyProfile(ComicTranslationRemoteProfile profile) {
    profileName.text = profile.name;
    endpoint.text = profile.endpoint;
    model.text = profile.model;
    additionalPrompt.text = profile.additionalPrompt;
    apiKey.clear();
  }

  Future<void> _selectProfile(String id) async {
    setState(() => working = true);
    final oldId = activeProfileId;
    _updateActiveProfile();
    if (apiKey.text.isNotEmpty) {
      await ComicTranslationSecrets.instance.setApiKey(oldId, apiKey.text);
    }
    activeProfileId = id;
    _applyProfile(_activeProfile);
    final profile = _activeProfile;
    appdata.settings['comicTranslationRemoteProfiles'] =
        profiles.map((profile) => profile.toJson()).toList();
    appdata.settings['comicTranslationRemoteProfile'] = activeProfileId;
    appdata.settings['comicTranslationRemoteEndpoint'] = profile.endpoint;
    appdata.settings['comicTranslationRemoteModel'] = profile.model;
    appdata.settings['comicTranslationAdditionalPrompt'] =
        profile.additionalPrompt;
    await appdata.saveData();
    ComicTranslationRuntime.instance.configure();
    if (mounted) setState(() => working = false);
  }

  Future<void> _newProfile() async {
    final error = _validate();
    if (error != null) {
      context.showMessage(message: error);
      return;
    }
    final newApiKey = apiKey.text;
    _updateActiveProfile();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final current = _profileFromFields(id);
    final profile = ComicTranslationRemoteProfile(
      id: id,
      name: current.name.isEmpty
          ? '${'Remote model'.tl} ${profiles.length + 1}'
          : '${current.name} ${profiles.length + 1}',
      endpoint: current.endpoint,
      model: current.model,
      additionalPrompt: current.additionalPrompt,
    );
    profiles.add(profile);
    activeProfileId = id;
    _applyProfile(profile);
    apiKey.text = newApiKey;
    setState(() {});
    await _save();
  }

  Future<void> _deleteProfile() async {
    final id = activeProfileId;
    profiles.removeWhere((profile) => profile.id == id);
    await ComicTranslationSecrets.instance.removeProfile(id);
    if (profiles.isEmpty) {
      profiles.add(const ComicTranslationRemoteProfile(
        id: 'default',
        name: '',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        model: '',
        additionalPrompt: '',
      ));
    }
    activeProfileId = profiles.first.id;
    _applyProfile(_activeProfile);
    appdata.settings['comicTranslationRemoteProfiles'] =
        profiles.map((profile) => profile.toJson()).toList();
    appdata.settings['comicTranslationRemoteProfile'] = activeProfileId;
    await appdata.saveData();
    ComicTranslationRuntime.instance.configure();
    if (mounted) setState(() {});
  }

  String? _validate() {
    if (backend != 'openaiCompatible') return null;
    final uri = Uri.tryParse(endpoint.text.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return 'Invalid API endpoint'.tl;
    }
    if (model.text.trim().isEmpty) return 'Model cannot be empty'.tl;
    return null;
  }

  String _modelSize(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';

  Future<void> _installModel() async {
    setState(() {});
    try {
      await ComicTranslationModelManager.instance.install();
      ComicTranslationRuntime.instance.configure();
      if (mounted) context.showMessage(message: 'OCR model installed'.tl);
    } catch (error) {
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      if (mounted) setState(() {});
    }
  }

  void _removeModel() {
    showConfirmDialog(
      context: context,
      title: 'Remove OCR model?'.tl,
      content: 'The downloaded model files will be removed.'.tl,
      confirmText: 'Remove',
      onConfirm: _removeModelNow,
    );
  }

  Future<void> _removeModelNow() async {
    await ComicTranslationModelManager.instance.remove();
    ComicTranslationRuntime.instance.configure();
    if (mounted) setState(() {});
  }

  Future<bool> _save() async {
    final error = _validate();
    if (error != null) {
      context.showMessage(message: error);
      return false;
    }
    setState(() => working = true);
    _updateActiveProfile();
    final profile = _activeProfile;
    appdata.settings['comicTranslationBackend'] = backend;
    appdata.settings['comicTranslationRemoteProfiles'] =
        profiles.map((profile) => profile.toJson()).toList();
    appdata.settings['comicTranslationRemoteProfile'] = activeProfileId;
    appdata.settings['comicTranslationRemoteEndpoint'] = profile.endpoint;
    appdata.settings['comicTranslationRemoteModel'] = profile.model;
    appdata.settings['comicTranslationAdditionalPrompt'] =
        profile.additionalPrompt;
    if (apiKey.text.isNotEmpty) {
      await ComicTranslationSecrets.instance.setApiKey(
        activeProfileId,
        apiKey.text,
      );
      apiKey.clear();
    }
    await appdata.saveData();
    ComicTranslationRuntime.instance.configure();
    if (mounted) setState(() => working = false);
    return true;
  }

  Future<void> _clearApiKey() async {
    setState(() => working = true);
    await ComicTranslationSecrets.instance.setApiKey(activeProfileId, '');
    ComicTranslationRuntime.instance.configure();
    if (mounted) setState(() => working = false);
  }

  Future<void> _testRemote() async {
    if (!await _save() || !mounted) return;
    setState(() => working = true);
    final translator = ComicTranslationEngineRegistry.instance.translationEngine!;
    final timer = Stopwatch()..start();
    try {
      final result = await translator.translate(ComicTranslationRequest(
        ocr: const ComicOcrArtifact(
          contentDigest: 'connection-test',
          engineId: 'connection-test',
          modelVersion: '1',
          sourceLanguage: 'en',
          imageWidth: 1,
          imageHeight: 1,
          mediaKind: ComicTranslationMediaKind.staticImage,
          animatedMode: AnimatedTranslationMode.posterFrame,
          regions: [
            ComicOcrRegion(
              id: 'test',
              polygon: [],
              text: 'Hello',
              confidence: 1,
              orientation: ComicTextOrientation.horizontal,
              kind: ComicTextKind.dialogue,
              readingOrder: 0,
              sourceMaskPolygons: [],
            ),
          ],
        ),
        targetLanguage: 'zh-CN',
        previousPages: const [],
      ));
      if (!mounted) return;
      final metrics = translator is ComicTextTranslationEngineDiagnostics
          ? (translator as ComicTextTranslationEngineDiagnostics).lastRunMetrics
          : null;
      context.showMessage(
        message: '${timer.elapsedMilliseconds}ms'
            '${metrics == null ? '' : ' · ${metrics.batchDurations.length} batch'}'
            ' · ${result.translations['test']}',
      );
    } catch (value) {
      if (mounted) context.showMessage(message: value.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }
}

class _ComicTranslationBenchmarkPage extends StatefulWidget {
  const _ComicTranslationBenchmarkPage();

  @override
  State<_ComicTranslationBenchmarkPage> createState() =>
      _ComicTranslationBenchmarkPageState();
}

class _ComicTranslationBenchmarkPageState
    extends State<_ComicTranslationBenchmarkPage> {
  String? imagePath;
  ComicTranslationBenchmarkResult? result;
  Object? error;
  List<String> rawResponses = const [];
  bool showRawResponses = false;
  bool running = false;
  int runs = 3;
  int analysisSide = 1600;
  String sourceLanguage = 'ja';
  String targetLanguage = 'zh-CN';

  @override
  void initState() {
    super.initState();
    imagePath = appdata.implicitData['comicTranslationBenchmarkImage'] as String?;
  }

  @override
  Widget build(BuildContext context) {
    final engines = ComicTranslationEngineRegistry.instance;
    return Scaffold(
      appBar: AppBar(title: Text('Translation benchmark'.tl)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('OCR: ${engines.ocrEngine?.id ?? 'Not installed'.tl}'),
          Text('Translation: ${engines.translationEngine?.id ?? 'Not configured'.tl}'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: running ? null : _selectImage,
            icon: const Icon(Icons.image_outlined),
            label: Text(imagePath ?? 'Select test image'.tl),
          ),
          const SizedBox(height: 8),
          ListTile(
            title: Text('Benchmark runs'.tl),
            trailing: DropdownButton<int>(
              value: runs,
              items: const [
                DropdownMenuItem(value: 1, child: Text('1')),
                DropdownMenuItem(value: 3, child: Text('3')),
                DropdownMenuItem(value: 10, child: Text('10')),
              ],
              onChanged: running ? null : (value) => setState(() => runs = value!),
            ),
          ),
          ListTile(
            title: const Text('OCR analysis side'),
            trailing: DropdownButton<int>(
              value: analysisSide,
              items: const [
                DropdownMenuItem(value: 960, child: Text('960')),
                DropdownMenuItem(value: 1280, child: Text('1280')),
                DropdownMenuItem(value: 1600, child: Text('1600')),
              ],
              onChanged: running
                  ? null
                  : (value) => setState(() {
                      analysisSide = value!;
                      result = null;
                      error = null;
                    }),
            ),
          ),
          ListTile(
            title: Text('Source language'.tl),
            subtitle: sourceLanguage == 'auto'
                ? Text('Automatic source language does not support Korean; select Korean to use the dedicated recognizer'.tl)
                : null,
            trailing: DropdownButton<String>(
              value: sourceLanguage,
              items: [
                DropdownMenuItem(value: 'auto', child: Text('Automatic'.tl)),
                DropdownMenuItem(value: 'ja', child: Text('Japanese'.tl)),
                DropdownMenuItem(value: 'ko', child: Text('Korean'.tl)),
                DropdownMenuItem(value: 'zh', child: Text('Chinese'.tl)),
                DropdownMenuItem(value: 'en', child: Text('English'.tl)),
              ],
              onChanged: running
                  ? null
                  : (value) => setState(() {
                      sourceLanguage = value!;
                      result = null;
                      error = null;
                    }),
            ),
          ),
          ListTile(
            title: Text('Target language'.tl),
            trailing: DropdownButton<String>(
              value: targetLanguage,
              items: const [
                DropdownMenuItem(value: 'zh-CN', child: Text('简体中文')),
                DropdownMenuItem(value: 'zh-TW', child: Text('繁體中文')),
                DropdownMenuItem(value: 'ko-KR', child: Text('한국어')),
                DropdownMenuItem(value: 'ja-JP', child: Text('日本語')),
                DropdownMenuItem(value: 'en-US', child: Text('English')),
              ],
              onChanged: running
                  ? null
                  : (value) => setState(() {
                      targetLanguage = value!;
                      result = null;
                      error = null;
                    }),
            ),
          ),
          FilledButton.icon(
            onPressed: running || imagePath == null || engines.ocrEngine == null
                ? null
                : _run,
            icon: const Icon(Icons.speed),
            label: Text(running ? 'Running'.tl : '${'Run'.tl} $runs×'),
          ),
          Text(
            'Model load time is a warm-load value when another Reader session already owns the model.'.tl,
            style: ts.s12,
          ).paddingVertical(8),
          if (engines.ocrEngine == null)
            Text(
              'Install an OCR model before running the benchmark.'.tl,
            ).paddingVertical(12),
          if (error != null)
            SelectableText(error.toString()).paddingVertical(12),
          if (rawResponses.isNotEmpty) ...[
            TextButton.icon(
              onPressed: () => setState(() {
                showRawResponses = !showRawResponses;
              }),
              icon: Icon(showRawResponses
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              label: Text((showRawResponses
                  ? 'Hide raw response'
                  : 'Show raw response').tl),
            ),
            if (showRawResponses)
              SelectableText(rawResponses
                  .asMap()
                  .entries
                  .map((entry) => 'Batch ${entry.key + 1}:\n${entry.value}')
                  .join('\n\n')),
          ],
          if (result != null) ...[
            const Divider(),
            Text('OCR load: ${result!.ocrLoadTime.inMilliseconds}ms'),
            if (result!.translationMeasured)
              Text('Translation load: ${result!.translationLoadTime.inMilliseconds}ms'),
            Text(
              'OCR P50/P95: ${_percentile(result!.samples.map((e) => e.ocrTime).toList(), 0.50)}ms / '
              '${_percentile(result!.samples.map((e) => e.ocrTime).toList(), 0.95)}ms',
            ),
            if (result!.translationMeasured)
              Text(
                'Translation P50/P95: ${_percentile(result!.samples.map((e) => e.translationTime).toList(), 0.50)}ms / '
                '${_percentile(result!.samples.map((e) => e.translationTime).toList(), 0.95)}ms',
              ),
            Text(
              'RSS boundary load/max/retained (whole process): '
              '${_rssDelta(result!.rssAfterLoad, result!.rssBeforeLoad)} / '
              '${_rssDelta(result!.maxObservedRss, result!.rssBeforeLoad)} / '
              '${_rssDelta(result!.rssAfterRelease, result!.rssBeforeLoad)}',
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < result!.samples.length; i++)
              _buildSample(result!.samples[i], i),
          ],
        ],
      ),
    );
  }

  Future<void> _selectImage() async {
    final selected = await selectFile(
      ext: const ['jpg', 'jpeg', 'png', 'webp', 'gif'],
    );
    if (selected != null && mounted) {
      appdata.implicitData['comicTranslationBenchmarkImage'] = selected.path;
      appdata.writeImplicitData();
      setState(() {
        imagePath = selected.path;
        result = null;
        error = null;
      });
    }
  }

  Future<void> _run() async {
    setState(() {
      running = true;
      result = null;
      error = null;
      rawResponses = const [];
      showRawResponses = false;
    });
    final uri = Uri.file(imagePath!).toString();
    final pages = List.generate(
      runs,
      (_) => ComicTranslationPageIdentity(
        imageKey: uri,
        sourceKey: 'benchmark',
        comicId: 'benchmark',
        chapterId: '0',
        pageIndex: 0,
        mediaKind: ComicTranslationMediaKind.staticImage,
      ),
    );
    try {
      final value = await ComicTranslationBenchmark().run(
        pages: pages,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        maxAnalysisSide: analysisSide,
      );
      final responses = _lastRawResponses();
      if (mounted) {
        setState(() {
          result = value;
          rawResponses = responses;
        });
      }
    } catch (value) {
      final responses = _lastRawResponses();
      if (mounted) {
        setState(() {
          error = value;
          rawResponses = responses;
        });
      }
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  List<String> _lastRawResponses() {
    final engine = ComicTranslationEngineRegistry.instance.translationEngine;
    if (engine is! ComicTextTranslationEngineDiagnostics) return const [];
    final diagnostics = engine as ComicTextTranslationEngineDiagnostics;
    return diagnostics.lastRawResponses
        .where((value) => value.isNotEmpty)
        .toList();
  }

  int _percentile(List<Duration> values, double percentile) {
    values.sort();
    return values[((values.length - 1) * percentile).round()].inMilliseconds;
  }

  String _rssDelta(int value, int baseline) =>
      '${((value - baseline) / 1048576).toStringAsFixed(1)}MB';

  Widget _buildSample(ComicTranslationBenchmarkSample sample, int index) {
    final metrics = sample.ocrMetrics;
    final translationMetrics = sample.translationMetrics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '#${index + 1} input=${sample.inputResolveTime.inMilliseconds}ms '
          'ocr=${sample.ocrTime.inMilliseconds}ms '
          '${result!.translationMeasured ? 'translation=${sample.translationTime.inMilliseconds}ms ' : ''}'
          'regions=${sample.regionCount} '
          'bubbles=${sample.bubbleCount} '
          'masks=${sample.sourceMaskCount} '
          'rssΔ=${_rssDelta(sample.rssAfter, sample.rssBefore)}',
        ),
        if (metrics != null)
          Text(
            'recognizer=${metrics.recognizer} · tiles=${metrics.tileCount} · '
            'detInput=${(metrics.detectionInputPixels / 1000000).toStringAsFixed(2)}MP '
            '[${metrics.detectionInputShapes.map((shape) => '${shape[2]}×${shape[3]}').join(' + ')}] · '
            'lines(det/decoded/accepted)=${metrics.detectedCount}/'
            '${metrics.rawDecodedCount}/${metrics.acceptedCount} · '
            'rescue=${metrics.balloonCandidates}/'
            '${metrics.rescuedRegions} '
            '(${metrics.balloonProposal.inMilliseconds}ms) · '
            'det=${metrics.detection.inMilliseconds}ms '
            '(${metrics.detectionPreprocess.inMilliseconds}/'
            '${metrics.detectionInference.inMilliseconds}/'
            '${metrics.detectionPostprocess.inMilliseconds}) · '
            'rec=${metrics.recognition.inMilliseconds}ms '
            '(${metrics.recognitionPreprocess.inMilliseconds}/'
            '${metrics.recognitionInference.inMilliseconds}/'
            '${metrics.recognitionPostprocess.inMilliseconds}) · '
            'segment=${metrics.bubbleSegmentation.inMilliseconds}ms · '
            'patch=${(metrics.cleanOverlayBytes / 1024).toStringAsFixed(1)}KiB/'
            '${metrics.cleanOverlayEncode.inMilliseconds}ms',
            style: ts.s12,
          ),
        if (translationMetrics != null)
          Text(
            'remote=${translationMetrics.elapsed.inMilliseconds}ms · '
            'batches=${translationMetrics.batchDurations.length} '
            '[${translationMetrics.batchDurations.map((value) => value.inMilliseconds).join(', ')}]ms · '
            'units=${translationMetrics.unitCount} · '
            'chars=${translationMetrics.sourceCharacters}',
            style: ts.s12,
          ),
        SelectableText(
          'OCR ($sourceLanguage):\n${sample.sourceTexts.isEmpty ? '—' : List.generate(sample.sourceTexts.length, (i) => '#${i + 1} g${sample.bubbleGroupIds[i] ?? '-'} u${sample.translationUnitIds[i] ?? '-'}:${sample.translationUnitOrders[i] ?? '-'} b${sample.translationBandIndices[i] ?? '-'} ${sample.translationUnitOrientations[i]?.name ?? '-'} [${sample.sourceConfidences[i].toStringAsFixed(2)}] ${sample.sourceTexts[i]}').join('\n')}',
          style: ts.s12,
        ),
        if (sample.splitDiagnostics.isNotEmpty)
          SelectableText(
            'Split diagnostics:\n${sample.splitDiagnostics.join('\n')}',
            style: ts.s12,
          ),
        if (sample.mergeDiagnostics.isNotEmpty)
          SelectableText(
            'Merge diagnostics:\n${sample.mergeDiagnostics.join('\n')}',
            style: ts.s12,
          ),
        SelectableText(
          '${'Translation'.tl} ($targetLanguage):\n${!result!.translationMeasured ? 'Translation backend is not configured'.tl : sample.translatedTexts.isEmpty ? '—' : List.generate(sample.translatedTexts.length, (i) => '#${i + 1} ${sample.translatedTexts[i].replaceAll(comicTranslationBreakMarker, '')}').join('\n')}',
          style: ts.s12,
        ),
      ],
    ).paddingVertical(6);
  }
}
