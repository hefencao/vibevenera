import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:venera/foundation/image_provider/cache/decoded_image_cache.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/webp_perf.dart';

import 'io/image_data_validator.dart';
import 'runtime/gif_stream_index.dart';
import 'pipeline/pipeline_controller.dart';
import 'pipeline/resource_entry.dart';
import 'renderer/frame_renderer.dart';
import 'renderer/webp_texture_channel.dart';
import 'renderer/webp_texture_registry.dart';
import 'session/download_session.dart';
import 'session/webp_decode_session.dart';
import 'session/webp_frame_holder.dart';
import 'session/webp_session_coordinator.dart';

part 'runtime/webp_common.dart';
part 'pipeline/webp_provider_static.dart';
part 'runtime/webp_session_completer.dart';

class WebPImageProvider extends ImageProvider<WebPImageProvider> {
  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;
  final int targetWidth;
  final int targetHeight;
  final double scale;
  final DecodedImageCache? cache;

  const WebPImageProvider({
    required this.imageKey,
    this.sourceKey,
    required this.cid,
    required this.eid,
    this.targetWidth = 0,
    this.targetHeight = 0,
    this.scale = 1.0,
    this.cache,
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
      _calculateWebPTargetSize(context);

  static bool isLikelyWebP(String imageKey) => _isLikelyWebP(imageKey);

  static bool isLikelyStreamingAnimation(String imageKey) =>
      _isLikelyWebP(imageKey) || _isLikelyGif(imageKey);

  @override
  Future<WebPImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<WebPImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    WebPImageProvider key,
    ImageDecoderCallback decode,
  ) => _WebPSessionImageStreamCompleter(key);

  @override
  bool operator ==(Object other) {
    return other is WebPImageProvider &&
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
