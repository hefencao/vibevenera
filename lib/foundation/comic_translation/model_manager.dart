import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/network/app_dio.dart' show RHttpAdapter;

final class ComicTranslationModelFile {
  final String name;
  final String url;
  final int bytes;
  final String sha256;

  const ComicTranslationModelFile({
    required this.name,
    required this.url,
    required this.bytes,
    required this.sha256,
  });
}

final class ComicTranslationModelBundle {
  final String id;
  final String version;
  final String displayName;
  final List<ComicTranslationModelFile> files;

  const ComicTranslationModelBundle({
    required this.id,
    required this.version,
    required this.displayName,
    required this.files,
  });

  int get bytes => files.fold(0, (sum, file) => sum + file.bytes);
}

const ppOcrV6SmallBundle = ComicTranslationModelBundle(
  id: 'ppocrv6-small',
  version: '2026-07-korean-pinned',
  displayName: 'PP-OCRv6 small + Korean PP-OCRv5 mobile',
  files: [
    ComicTranslationModelFile(
      name: 'det.onnx',
      url: 'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx/resolve/5994b4f1a827310b6d38f6b13716af6381847be0/inference.onnx',
      bytes: 9880512,
      sha256: 'd73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e',
    ),
    ComicTranslationModelFile(
      name: 'rec.onnx',
      url: 'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/resolve/3d2d345e6a299891174f1397a72cdd81331359c7/inference.onnx',
      bytes: 21159378,
      sha256: '5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634',
    ),
    ComicTranslationModelFile(
      name: 'rec.yml',
      url: 'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/resolve/35200ec2acf6562260fa500e3262f5ea11f33642/inference.yml',
      bytes: 150579,
      sha256: 'ab078671bb49f06228eadccd34f1bb501e157f7a047095ffb943ba81512c77d1',
    ),
    ComicTranslationModelFile(
      name: 'rec-ko.onnx',
      url: 'https://huggingface.co/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/resolve/5c6f574b8e2230adf4287b33e736d71b9fabd28e/inference.onnx',
      bytes: 13418787,
      sha256: '92f0b7785e64fc9090106a241cf4c1eb97472824558272751b88a2a4476d3a08',
    ),
    ComicTranslationModelFile(
      name: 'rec-ko.yml',
      url: 'https://huggingface.co/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/resolve/5c6f574b8e2230adf4287b33e736d71b9fabd28e/inference.yml',
      bytes: 96039,
      sha256: 'f757fa1c40e99edcf27e9cce879b93eb2a51fa46f5ef39095689b8c37dd75998',
    ),
  ],
);

enum ComicTranslationModelPhase { idle, downloading, verifying }

final class ComicTranslationModelProgress {
  final ComicTranslationModelPhase phase;
  final String? fileName;
  final int receivedBytes;
  final int totalBytes;

  const ComicTranslationModelProgress({
    this.phase = ComicTranslationModelPhase.idle,
    this.fileName,
    this.receivedBytes = 0,
    this.totalBytes = 0,
  });

  double get fraction => totalBytes == 0 ? 0 : receivedBytes / totalBytes;
}

final class ComicTranslationModelManager {
  ComicTranslationModelManager._();

  static final instance = ComicTranslationModelManager._();
  static const bundle = ppOcrV6SmallBundle;

  final progress = ValueNotifier(const ComicTranslationModelProgress());
  late final Directory _directory;
  bool _installed = false;
  Future<void>? _installing;

  bool get installed => _installed;
  bool get installing => _installing != null;
  String pathOf(String name) => '${_directory.path}${Platform.pathSeparator}$name';

  Future<void> init(String dataPath) async {
    _directory = Directory(
      '$dataPath${Platform.pathSeparator}comic_translation${Platform.pathSeparator}models${Platform.pathSeparator}${bundle.id}',
    );
    await _directory.create(recursive: true);
    _installed = await _hasCompleteInstallation();
  }

  Future<void> install() => _installing ??= _install().whenComplete(() {
    _installing = null;
    progress.value = const ComicTranslationModelProgress();
  });

  Future<void> _install() async {
    var completed = 0;
    for (final modelFile in bundle.files) {
      final target = File(pathOf(modelFile.name));
      if (await _verified(target, modelFile)) {
        completed += modelFile.bytes;
        continue;
      }
      await _download(modelFile, completed);
      final partial = File('${target.path}.part');
      progress.value = ComicTranslationModelProgress(
        phase: ComicTranslationModelPhase.verifying,
        fileName: modelFile.name,
        receivedBytes: completed + modelFile.bytes,
        totalBytes: bundle.bytes,
      );
      if (!await _verified(partial, modelFile)) {
        await partial.writeAsBytes(const []);
        throw StateError('SHA-256 mismatch: ${modelFile.name}');
      }
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      completed += modelFile.bytes;
    }
    await File('${_directory.path}${Platform.pathSeparator}installation.json')
        .writeAsString(jsonEncode({
          'id': bundle.id,
          'version': bundle.version,
          'files': {for (final file in bundle.files) file.name: file.sha256},
        }), flush: true);
    _installed = true;
  }

  Future<void> _download(ComicTranslationModelFile modelFile, int completed) async {
    final partial = File('${pathOf(modelFile.name)}.part');
    var offset = await partial.exists() ? await partial.length() : 0;
    if (offset > modelFile.bytes) {
      await partial.writeAsBytes(const []);
      offset = 0;
    }
    if (offset == modelFile.bytes) return;
    final client = Dio()..httpClientAdapter = RHttpAdapter();
    try {
      final response = await client.get<ResponseBody>(
        modelFile.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {if (offset > 0) 'Range': 'bytes=$offset-'},
        ),
      );
      final append = offset > 0 && response.statusCode == HttpStatus.partialContent;
      if (offset > 0 && !append) offset = 0;
      if (append) {
        final range = response.headers.value('content-range');
        if (range == null || !range.startsWith('bytes $offset-')) {
          throw StateError('Invalid Content-Range for ${modelFile.name}: $range');
        }
      }
      final output = await partial.open(mode: append ? FileMode.append : FileMode.write);
      var received = offset;
      final publishTimer = Stopwatch()..start();
      progress.value = ComicTranslationModelProgress(
        phase: ComicTranslationModelPhase.downloading,
        fileName: modelFile.name,
        receivedBytes: completed + received,
        totalBytes: bundle.bytes,
      );
      try {
        await for (final chunk in response.data!.stream) {
          await output.writeFrom(chunk);
          received += chunk.length;
          if (publishTimer.elapsedMilliseconds >= 500 ||
              received == modelFile.bytes) {
            publishTimer.reset();
            progress.value = ComicTranslationModelProgress(
              phase: ComicTranslationModelPhase.downloading,
              fileName: modelFile.name,
              receivedBytes: completed + received,
              totalBytes: bundle.bytes,
            );
          }
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (received != modelFile.bytes) {
        throw StateError(
          'Model length mismatch: ${modelFile.name} $received/${modelFile.bytes}',
        );
      }
    } finally {
      client.close();
    }
  }

  Future<bool> _hasCompleteInstallation() async {
    final manifest = File(
      '${_directory.path}${Platform.pathSeparator}installation.json',
    );
    if (!await manifest.exists()) return false;
    final value = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    if (value['id'] != bundle.id || value['version'] != bundle.version) return false;
    final files = Map<String, dynamic>.from(value['files'] as Map);
    for (final modelFile in bundle.files) {
      final file = File(pathOf(modelFile.name));
      if (files[modelFile.name] != modelFile.sha256 ||
          !await file.exists() ||
          await file.length() != modelFile.bytes) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _verified(
    File file,
    ComicTranslationModelFile modelFile,
  ) async {
    if (!await file.exists() || await file.length() != modelFile.bytes) return false;
    final path = file.path;
    final digest = await Isolate.run(() async =>
        (await sha256.bind(File(path).openRead()).first).toString());
    return digest == modelFile.sha256;
  }

  Future<void> remove() async {
    if (_installing != null) throw StateError('Model download is in progress');
    if (await _directory.exists()) await _directory.delete(recursive: true);
    await _directory.create(recursive: true);
    _installed = false;
    progress.value = const ComicTranslationModelProgress();
  }
}
