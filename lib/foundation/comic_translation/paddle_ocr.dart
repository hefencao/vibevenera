import 'dart:io';

import 'package:flutter/services.dart';

import 'engine.dart';
import 'model_manager.dart';
import 'models.dart';

final class AndroidPaddleComicOcrEngine
    implements ComicOcrEngine, ComicOcrEngineDiagnostics {
  static const _channel = MethodChannel('venera/comic_translation_ocr');
  static const _analysisSide = 1600;

  final ComicTranslationModelManager models;
  ComicOcrRunMetrics? _lastRunMetrics;

  AndroidPaddleComicOcrEngine(this.models);

  @override
  ComicOcrRunMetrics? get lastRunMetrics => _lastRunMetrics;

  @override
  String get id => 'paddleocr-android';

  @override
  String get modelVersion =>
      '${ComicTranslationModelManager.bundle.version}:bubble-v11:pixel-mask-v4';

  @override
  bool get supportsAnimatedPosterFrame => false;

  @override
  Future<void> load(String sourceLanguage) => _channel.invokeMethod('load', {
    'detModelPath': models.pathOf('det.onnx'),
    'recModelPath': models.pathOf('rec.onnx'),
    'recConfigPath': models.pathOf('rec.yml'),
    'koreanRecModelPath': models.pathOf('rec-ko.onnx'),
    'koreanRecConfigPath': models.pathOf('rec-ko.yml'),
    'maxAnalysisSide': _analysisSide,
    'threads': Platform.numberOfProcessors.clamp(2, 4),
    'sourceLanguage': sourceLanguage,
  });

  @override
  Future<ComicOcrArtifact> recognize(ComicOcrInput input) async {
    final value = Map<String, dynamic>.from(
      (await _channel.invokeMapMethod<String, dynamic>('recognize', {
        'filePath': input.filePath,
        'sourceLanguage': input.sourceLanguage,
        'maxAnalysisSide': input.maxAnalysisSide,
      }))!,
    );
    final width = value['width'] as int;
    final height = value['height'] as int;
    final cleanOverlayPng = value['cleanOverlayPng'] as Uint8List?;
    _lastRunMetrics = ComicOcrRunMetrics(
      recognizer: value['recognizer'] as String,
      tileCount: value['tiles'] as int,
      detectionInputPixels: value['detInputPixels'] as int,
      detectionInputShapes: (value['detInputShapes'] as List)
          .map((shape) => (shape as List).cast<int>())
          .toList(),
      detectedCount: value['detectedCount'] as int,
      rawDecodedCount: value['rawDecodedCount'] as int,
      acceptedCount: value['acceptedCount'] as int,
      balloonCandidates: value['balloonCandidates'] as int,
      rescuedRegions: value['rescuedRegions'] as int,
      cleanOverlayBytes: value['cleanOverlayBytes'] as int,
      detectionPreprocess: Duration(milliseconds: value['detPreprocessMs'] as int),
      detectionInference: Duration(milliseconds: value['detInferenceMs'] as int),
      detectionPostprocess: Duration(milliseconds: value['detPostprocessMs'] as int),
      recognitionPreprocess: Duration(milliseconds: value['recPreprocessMs'] as int),
      recognitionInference: Duration(milliseconds: value['recInferenceMs'] as int),
      recognitionPostprocess: Duration(milliseconds: value['recPostprocessMs'] as int),
      bubbleSegmentation:
          Duration(milliseconds: value['bubbleSegmentationMs'] as int),
      balloonProposal:
          Duration(milliseconds: value['balloonProposalMs'] as int),
      cleanOverlayEncode:
          Duration(milliseconds: value['cleanOverlayEncodeMs'] as int),
    );
    final regions = (value['regions'] as List).map((raw) {
      final region = Map<String, dynamic>.from(raw as Map);
      final points = (region['points'] as List)
          .map((rawPoint) {
            final point = rawPoint as List;
            return NormalizedPoint(
              (point[0] as num).toDouble() / width,
              (point[1] as num).toDouble() / height,
            );
          })
          .toList();
      final bubblePolygon = (region['bubblePoints'] as List?)
          ?.map((rawPoint) {
            final point = rawPoint as List;
            return NormalizedPoint(
              (point[0] as num).toDouble() / width,
              (point[1] as num).toDouble() / height,
            );
          })
          .toList();
      final sourceMaskPolygons = (region['sourceMaskPolygons'] as List)
          .map((rawPolygon) => (rawPolygon as List)
              .map((rawPoint) {
                final point = rawPoint as List;
                return NormalizedPoint(
                  (point[0] as num).toDouble() / width,
                  (point[1] as num).toDouble() / height,
                );
              })
              .toList())
          .toList();
      final xs = points.map((point) => point.x);
      final ys = points.map((point) => point.y);
      final boxWidth = xs.reduce((a, b) => a > b ? a : b) -
          xs.reduce((a, b) => a < b ? a : b);
      final boxHeight = ys.reduce((a, b) => a > b ? a : b) -
          ys.reduce((a, b) => a < b ? a : b);
      final verticalRatio = input.sourceLanguage
                  .split(RegExp('[-_]'))
                  .first
                  .toLowerCase() ==
              'ja'
          ? 0.95
          : 1.05;
      return ComicOcrRegion(
        id: region['id'] as String,
        polygon: points,
        text: region['text'] as String,
        confidence: (region['confidence'] as num).toDouble(),
        orientation: boxHeight > boxWidth * verticalRatio
            ? ComicTextOrientation.vertical
            : ComicTextOrientation.horizontal,
        kind: ComicTextKind.unknown,
        readingOrder: int.parse((region['id'] as String).substring(1)),
        sourceMaskPolygons: sourceMaskPolygons,
        backgroundArgb: region['backgroundArgb'] as int,
        foregroundArgb: region['foregroundArgb'] as int?,
        bubbleGroupId: region['bubbleGroupId'] as int?,
        bubblePolygon: bubblePolygon,
      );
    }).toList();
    return ComicOcrArtifact(
      contentDigest: input.contentDigest,
      engineId: id,
      modelVersion: modelVersion,
      sourceLanguage: input.sourceLanguage,
      imageWidth: width,
      imageHeight: height,
      mediaKind: input.identity.mediaKind,
      animatedMode: input.animatedMode,
      regions: regions,
      cleanOverlayPng: cleanOverlayPng,
    );
  }

  @override
  Future<void> unload() => _channel.invokeMethod('unload');
}
