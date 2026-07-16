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
  late final TextEditingController endpoint;
  late final TextEditingController model;
  final apiKey = TextEditingController();
  bool working = false;

  @override
  void initState() {
    backend = appdata.settings['comicTranslationBackend'] as String;
    endpoint = TextEditingController(
      text: appdata.settings['comicTranslationRemoteEndpoint'] as String,
    );
    model = TextEditingController(
      text: appdata.settings['comicTranslationRemoteModel'] as String,
    );
    super.initState();
  }

  @override
  void dispose() {
    endpoint.dispose();
    model.dispose();
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
                  controller: apiKey,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'API key'.tl,
                    hintText: ComicTranslationSecrets.instance.hasApiKey
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
                  if (ComicTranslationSecrets.instance.hasApiKey)
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
    appdata.settings['comicTranslationBackend'] = backend;
    appdata.settings['comicTranslationRemoteEndpoint'] = endpoint.text.trim();
    appdata.settings['comicTranslationRemoteModel'] = model.text.trim();
    if (apiKey.text.isNotEmpty) {
      await ComicTranslationSecrets.instance.setApiKey(apiKey.text);
      apiKey.clear();
    }
    await appdata.saveData();
    ComicTranslationRuntime.instance.configure();
    if (mounted) setState(() => working = false);
    return true;
  }

  Future<void> _clearApiKey() async {
    setState(() => working = true);
    await ComicTranslationSecrets.instance.setApiKey('');
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
            ),
          ],
        ),
        targetLanguage: 'zh-CN',
        previousPages: const [],
      ));
      if (!mounted) return;
      context.showMessage(
        message: '${timer.elapsedMilliseconds}ms · ${result.translations['test']}',
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
  bool running = false;
  int runs = 3;
  String sourceLanguage = 'ja';
  String targetLanguage = 'zh-CN';

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
                DropdownMenuItem(value: 3, child: Text('3')),
                DropdownMenuItem(value: 10, child: Text('10')),
              ],
              onChanged: running ? null : (value) => setState(() => runs = value!),
            ),
          ),
          ListTile(
            title: Text('Source language'.tl),
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
                  : (value) => setState(() => sourceLanguage = value!),
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
                  : (value) => setState(() => targetLanguage = value!),
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
              'RSS load/observed max/retained: '
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
      );
      if (mounted) setState(() => result = value);
    } catch (value) {
      if (mounted) setState(() => error = value);
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  int _percentile(List<Duration> values, double percentile) {
    values.sort();
    return values[((values.length - 1) * percentile).round()].inMilliseconds;
  }

  String _rssDelta(int value, int baseline) =>
      '${((value - baseline) / 1048576).toStringAsFixed(1)}MB';

  Widget _buildSample(ComicTranslationBenchmarkSample sample, int index) {
    final metrics = sample.ocrMetrics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '#${index + 1} input=${sample.inputResolveTime.inMilliseconds}ms '
          'ocr=${sample.ocrTime.inMilliseconds}ms '
          '${result!.translationMeasured ? 'translation=${sample.translationTime.inMilliseconds}ms ' : ''}'
          'regions=${sample.regionCount} '
          'rssΔ=${_rssDelta(sample.rssAfter, sample.rssBefore)}',
        ),
        if (metrics != null)
          Text(
            'det=${metrics.detection.inMilliseconds}ms '
            '(${metrics.detectionPreprocess.inMilliseconds}/'
            '${metrics.detectionInference.inMilliseconds}/'
            '${metrics.detectionPostprocess.inMilliseconds}) · '
            'rec=${metrics.recognition.inMilliseconds}ms '
            '(${metrics.recognitionPreprocess.inMilliseconds}/'
            '${metrics.recognitionInference.inMilliseconds}/'
            '${metrics.recognitionPostprocess.inMilliseconds})',
            style: ts.s12,
          ),
        if (sample.sourceTexts.isNotEmpty)
          SelectableText('OCR: ${sample.sourceTexts.join(' | ')}', style: ts.s12),
        if (result!.translationMeasured && sample.translatedTexts.isNotEmpty)
          SelectableText(
            '${'Translation'.tl}: ${sample.translatedTexts.join(' | ')}',
            style: ts.s12,
          ),
      ],
    ).paddingVertical(6);
  }
}
