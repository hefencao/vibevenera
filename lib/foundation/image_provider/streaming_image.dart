import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:venera/utils/image_pipeline_perf.dart';

import 'io/image_data_validator.dart';
import 'runtime/gif_stream_runtime.dart';
import 'pipeline/pipeline_controller.dart';
import 'pipeline/resource_entry.dart';
import 'renderer/frame_renderer.dart';
import 'renderer/webp_texture_channel.dart';
import 'renderer/webp_texture_registry.dart';
import 'session/download_session.dart';
import 'session/webp_decode_session.dart';
import 'session/webp_frame_holder.dart';
import 'session/streaming_session_coordinator.dart';

part 'runtime/streaming_playback.dart';
part 'pipeline/streaming_provider_support.dart';
part 'runtime/streaming_image_completer.dart';

class StreamingImageProvider extends ImageProvider<StreamingImageProvider> {
  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;
  final int targetWidth;
  final int targetHeight;
  final double scale;

  const StreamingImageProvider({
    required this.imageKey,
    this.sourceKey,
    required this.cid,
    required this.eid,
    this.targetWidth = 0,
    this.targetHeight = 0,
    this.scale = 1.0,
  });

  String get _fullKey {
    final identity = '$imageKey@$sourceKey@$cid@$eid';
    if (targetWidth > 0 || targetHeight > 0) {
      return '$identity@${targetWidth}x$targetHeight';
    }
    return identity;
  }

  /// native texture 侧通道的键（含目标尺寸）。ComicImage 用它监听是否有可显示的纹理。
  String get textureFullKey => _fullKey;

  static (int, int) calculateTargetSize(BuildContext context) =>
      _calculateStreamingTargetSize(context);

  static bool isLikelyStreamingAnimation(String imageKey) =>
      _isLikelyWebP(imageKey) || _isLikelyGif(imageKey);

  @override
  Future<StreamingImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<StreamingImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    StreamingImageProvider key,
    ImageDecoderCallback decode,
  ) => _StreamingImageCompleter(key);

  @override
  bool operator ==(Object other) {
    return other is StreamingImageProvider &&
        imageKey == other.imageKey &&
        sourceKey == other.sourceKey &&
        cid == other.cid &&
        eid == other.eid &&
        targetWidth == other.targetWidth &&
        targetHeight == other.targetHeight;
  }

  @override
  int get hashCode =>
      Object.hash(imageKey, sourceKey, cid, eid, targetWidth, targetHeight);

  static void clearAll() =>
      PipelineController.instance.evictUndemandedSessions();

  static void setInteractionState(InteractionState state) {
    PipelineController.instance.setInteractionState(state);
  }

  static bool get isJumpingInteraction =>
      PipelineController.instance.interactionState == InteractionState.jumping;
}
