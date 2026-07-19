import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const comicTranslationBreakMarker = '\u241e';

enum ComicTranslationMediaKind { staticImage, animatedImage }

/// Animated translation is part of the artifact contract. The first runtime
/// does not submit animated pages yet.
enum AnimatedTranslationMode { posterFrame, keyframes }

enum ComicTextOrientation { horizontal, vertical }

enum ComicTextKind { dialogue, narration, soundEffect, unknown }

enum ComicTranslationPhase {
  disabled,
  waitingForImage,
  queued,
  recognizing,
  translating,
  ready,
  unsupportedMedia,
  unavailable,
  failed,
}

final class NormalizedPoint {
  final double x;
  final double y;

  const NormalizedPoint(this.x, this.y);

  factory NormalizedPoint.fromJson(List<dynamic> json) =>
      NormalizedPoint((json[0] as num).toDouble(), (json[1] as num).toDouble());

  List<double> toJson() => [x, y];
}

final class AnimatedFrameSpan {
  final int startMilliseconds;
  final int endMilliseconds;

  const AnimatedFrameSpan(this.startMilliseconds, this.endMilliseconds);

  factory AnimatedFrameSpan.fromJson(Map<String, dynamic> json) =>
      AnimatedFrameSpan(json['start'] as int, json['end'] as int);

  Map<String, dynamic> toJson() => {
    'start': startMilliseconds,
    'end': endMilliseconds,
  };
}

final class ComicTranslationPageIdentity {
  final String imageKey;
  final String sourceKey;
  final String comicId;
  final String chapterId;
  final int pageIndex;
  final ComicTranslationMediaKind mediaKind;

  const ComicTranslationPageIdentity({
    required this.imageKey,
    required this.sourceKey,
    required this.comicId,
    required this.chapterId,
    required this.pageIndex,
    required this.mediaKind,
  });

  String get key => jsonEncode([
    imageKey,
    sourceKey,
    comicId,
    chapterId,
    pageIndex,
  ]);
}

final class ComicOcrRegion {
  final String id;
  final List<NormalizedPoint> polygon;
  final String text;
  final double confidence;
  final ComicTextOrientation orientation;
  final ComicTextKind kind;
  final int readingOrder;
  final int? backgroundArgb;
  final int? foregroundArgb;
  final int? bubbleGroupId;
  final List<NormalizedPoint>? bubblePolygon;
  final List<NormalizedPoint>? bubbleCandidatePolygon;
  final List<List<NormalizedPoint>> sourceMaskPolygons;
  final AnimatedFrameSpan? frameSpan;

  const ComicOcrRegion({
    required this.id,
    required this.polygon,
    required this.text,
    required this.confidence,
    required this.orientation,
    required this.kind,
    required this.readingOrder,
    required this.sourceMaskPolygons,
    this.backgroundArgb,
    this.foregroundArgb,
    this.bubbleGroupId,
    this.bubblePolygon,
    this.bubbleCandidatePolygon,
    this.frameSpan,
  });

  factory ComicOcrRegion.fromJson(Map<String, dynamic> json) => ComicOcrRegion(
    id: json['id'] as String,
    polygon: (json['polygon'] as List)
        .map((point) => NormalizedPoint.fromJson(point as List))
        .toList(),
    text: json['text'] as String,
    confidence: (json['confidence'] as num).toDouble(),
    orientation: ComicTextOrientation.values.byName(
      json['orientation'] as String,
    ),
    kind: ComicTextKind.values.byName(json['kind'] as String),
    readingOrder: json['readingOrder'] as int,
    backgroundArgb: json['backgroundArgb'] as int?,
    foregroundArgb: json['foregroundArgb'] as int?,
    bubbleGroupId: json['bubbleGroupId'] as int?,
    bubblePolygon: (json['bubblePolygon'] as List?)
        ?.map((point) => NormalizedPoint.fromJson(point as List))
        .toList(),
    bubbleCandidatePolygon: (json['bubbleCandidatePolygon'] as List?)
        ?.map((point) => NormalizedPoint.fromJson(point as List))
        .toList(),
    sourceMaskPolygons: (json['sourceMaskPolygons'] as List? ?? const [])
        .map((polygon) => (polygon as List)
            .map((point) => NormalizedPoint.fromJson(point as List))
            .toList())
        .toList(),
    frameSpan: json['frameSpan'] == null
        ? null
        : AnimatedFrameSpan.fromJson(
            Map<String, dynamic>.from(json['frameSpan'] as Map),
          ),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'polygon': polygon.map((point) => point.toJson()).toList(),
    'text': text,
    'confidence': confidence,
    'orientation': orientation.name,
    'kind': kind.name,
    'readingOrder': readingOrder,
    if (backgroundArgb != null) 'backgroundArgb': backgroundArgb,
    if (foregroundArgb != null) 'foregroundArgb': foregroundArgb,
    if (bubbleGroupId != null) 'bubbleGroupId': bubbleGroupId,
    if (bubblePolygon != null)
      'bubblePolygon': bubblePolygon!.map((point) => point.toJson()).toList(),
    if (bubbleCandidatePolygon != null)
      'bubbleCandidatePolygon': bubbleCandidatePolygon!
          .map((point) => point.toJson()).toList(),
    'sourceMaskPolygons': sourceMaskPolygons
        .map((polygon) => polygon.map((point) => point.toJson()).toList())
        .toList(),
    if (frameSpan != null) 'frameSpan': frameSpan!.toJson(),
  };
}

final class ComicOcrArtifact {
  final String contentDigest;
  final String engineId;
  final String modelVersion;
  final String sourceLanguage;
  final int imageWidth;
  final int imageHeight;
  final ComicTranslationMediaKind mediaKind;
  final AnimatedTranslationMode animatedMode;
  final List<ComicOcrRegion> regions;
  final Uint8List? cleanOverlayPng;

  const ComicOcrArtifact({
    required this.contentDigest,
    required this.engineId,
    required this.modelVersion,
    required this.sourceLanguage,
    required this.imageWidth,
    required this.imageHeight,
    required this.mediaKind,
    required this.animatedMode,
    required this.regions,
    this.cleanOverlayPng,
  });

  String get digest => sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();

  factory ComicOcrArtifact.fromJson(Map<String, dynamic> json) =>
      ComicOcrArtifact(
        contentDigest: json['contentDigest'] as String,
        engineId: json['engineId'] as String,
        modelVersion: json['modelVersion'] as String,
        sourceLanguage: json['sourceLanguage'] as String,
        imageWidth: json['imageWidth'] as int,
        imageHeight: json['imageHeight'] as int,
        mediaKind: ComicTranslationMediaKind.values.byName(
          json['mediaKind'] as String,
        ),
        animatedMode: AnimatedTranslationMode.values.byName(
          json['animatedMode'] as String,
        ),
        regions: (json['regions'] as List)
            .map((region) => ComicOcrRegion.fromJson(
                  Map<String, dynamic>.from(region as Map),
                ))
            .toList(),
        cleanOverlayPng: json['cleanOverlayPng'] == null
            ? null
            : base64Decode(json['cleanOverlayPng'] as String),
      );

  Map<String, dynamic> toJson() => {
    'contentDigest': contentDigest,
    'engineId': engineId,
    'modelVersion': modelVersion,
    'sourceLanguage': sourceLanguage,
    'imageWidth': imageWidth,
    'imageHeight': imageHeight,
    'mediaKind': mediaKind.name,
    'animatedMode': animatedMode.name,
    'regions': regions.map((region) => region.toJson()).toList(),
    if (cleanOverlayPng != null)
      'cleanOverlayPng': base64Encode(cleanOverlayPng!),
  };
}

final class ComicTranslatedRegion {
  final String ocrRegionId;
  final String sourceText;
  final String translatedText;
  final List<NormalizedPoint> polygon;
  final ComicTextOrientation orientation;
  final ComicTextKind kind;
  final int readingOrder;
  final int? backgroundArgb;
  final int? foregroundArgb;
  final int? bubbleGroupId;
  final List<NormalizedPoint>? bubblePolygon;
  final List<NormalizedPoint>? bubbleCandidatePolygon;
  final List<List<NormalizedPoint>> sourceMaskPolygons;
  final AnimatedFrameSpan? frameSpan;

  const ComicTranslatedRegion({
    required this.ocrRegionId,
    required this.sourceText,
    required this.translatedText,
    required this.polygon,
    required this.orientation,
    required this.kind,
    required this.readingOrder,
    required this.sourceMaskPolygons,
    this.backgroundArgb,
    this.foregroundArgb,
    this.bubbleGroupId,
    this.bubblePolygon,
    this.bubbleCandidatePolygon,
    this.frameSpan,
  });

  factory ComicTranslatedRegion.fromJson(Map<String, dynamic> json) =>
      ComicTranslatedRegion(
        ocrRegionId: json['ocrRegionId'] as String,
        sourceText: json['sourceText'] as String,
        translatedText: json['translatedText'] as String,
        polygon: (json['polygon'] as List)
            .map((point) => NormalizedPoint.fromJson(point as List))
            .toList(),
        orientation: ComicTextOrientation.values.byName(
          json['orientation'] as String,
        ),
        kind: ComicTextKind.values.byName(json['kind'] as String),
        readingOrder: json['readingOrder'] as int,
        backgroundArgb: json['backgroundArgb'] as int?,
        foregroundArgb: json['foregroundArgb'] as int?,
        bubbleGroupId: json['bubbleGroupId'] as int?,
        bubblePolygon: (json['bubblePolygon'] as List?)
            ?.map((point) => NormalizedPoint.fromJson(point as List))
            .toList(),
        bubbleCandidatePolygon: (json['bubbleCandidatePolygon'] as List?)
            ?.map((point) => NormalizedPoint.fromJson(point as List))
            .toList(),
        sourceMaskPolygons: (json['sourceMaskPolygons'] as List? ?? const [])
            .map((polygon) => (polygon as List)
                .map((point) => NormalizedPoint.fromJson(point as List))
                .toList())
            .toList(),
        frameSpan: json['frameSpan'] == null
            ? null
            : AnimatedFrameSpan.fromJson(
                Map<String, dynamic>.from(json['frameSpan'] as Map),
              ),
      );

  Map<String, dynamic> toJson() => {
    'ocrRegionId': ocrRegionId,
    'sourceText': sourceText,
    'translatedText': translatedText,
    'polygon': polygon.map((point) => point.toJson()).toList(),
    'orientation': orientation.name,
    'kind': kind.name,
    'readingOrder': readingOrder,
    if (backgroundArgb != null) 'backgroundArgb': backgroundArgb,
    if (foregroundArgb != null) 'foregroundArgb': foregroundArgb,
    if (bubbleGroupId != null) 'bubbleGroupId': bubbleGroupId,
    if (bubblePolygon != null)
      'bubblePolygon': bubblePolygon!.map((point) => point.toJson()).toList(),
    if (bubbleCandidatePolygon != null)
      'bubbleCandidatePolygon': bubbleCandidatePolygon!
          .map((point) => point.toJson()).toList(),
    'sourceMaskPolygons': sourceMaskPolygons
        .map((polygon) => polygon.map((point) => point.toJson()).toList())
        .toList(),
    if (frameSpan != null) 'frameSpan': frameSpan!.toJson(),
  };
}

final class ComicTranslationArtifact {
  final String contentDigest;
  final String ocrDigest;
  final String engineId;
  final String modelVersion;
  final String sourceLanguage;
  final String targetLanguage;
  final String contextDigest;
  final int imageWidth;
  final int imageHeight;
  final ComicTranslationMediaKind mediaKind;
  final AnimatedTranslationMode animatedMode;
  final List<ComicTranslatedRegion> regions;

  const ComicTranslationArtifact({
    required this.contentDigest,
    required this.ocrDigest,
    required this.engineId,
    required this.modelVersion,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.contextDigest,
    required this.imageWidth,
    required this.imageHeight,
    required this.mediaKind,
    required this.animatedMode,
    required this.regions,
  });

  factory ComicTranslationArtifact.fromJson(Map<String, dynamic> json) =>
      ComicTranslationArtifact(
        contentDigest: json['contentDigest'] as String,
        ocrDigest: json['ocrDigest'] as String,
        engineId: json['engineId'] as String,
        modelVersion: json['modelVersion'] as String,
        sourceLanguage: json['sourceLanguage'] as String? ?? 'auto',
        targetLanguage: json['targetLanguage'] as String,
        contextDigest: json['contextDigest'] as String,
        imageWidth: json['imageWidth'] as int,
        imageHeight: json['imageHeight'] as int,
        mediaKind: ComicTranslationMediaKind.values.byName(
          json['mediaKind'] as String,
        ),
        animatedMode: AnimatedTranslationMode.values.byName(
          json['animatedMode'] as String,
        ),
        regions: (json['regions'] as List)
            .map((region) => ComicTranslatedRegion.fromJson(
                  Map<String, dynamic>.from(region as Map),
                ))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'contentDigest': contentDigest,
    'ocrDigest': ocrDigest,
    'engineId': engineId,
    'modelVersion': modelVersion,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'contextDigest': contextDigest,
    'imageWidth': imageWidth,
    'imageHeight': imageHeight,
    'mediaKind': mediaKind.name,
    'animatedMode': animatedMode.name,
    'regions': regions.map((region) => region.toJson()).toList(),
  };
}

final class ComicTranslationPageState {
  final ComicTranslationPhase phase;
  final ComicTranslationArtifact? artifact;
  final Uint8List? cleanOverlayPng;
  final Object? error;

  const ComicTranslationPageState(
    this.phase, {
    this.artifact,
    this.cleanOverlayPng,
    this.error,
  });

  static const disabled = ComicTranslationPageState(
    ComicTranslationPhase.disabled,
  );
}
