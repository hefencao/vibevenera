import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;
import 'dart:ffi';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'image_fetch.dart';
import 'pipeline_controller.dart';
import 'pipeline_models.dart';

part 'webp/webp_common.dart';
part 'webp/webp_frame_buffer.dart';
part 'webp/webp_decoder_holder.dart';
part 'webp/webp_decode_service.dart';
part 'webp/webp_decoder_manager.dart';
part 'webp/webp_provider_static.dart';
part 'webp/webp_stream_session.dart';
part 'webp/webp_provider_loader.dart';
part 'webp/webp_playback_controller.dart';
part 'webp/webp_load_result.dart';
part 'webp/webp_stream_completer.dart';

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
    if (targetWidth > 0 || targetHeight > 0) {
      return '$imageKey@${targetWidth}x$targetHeight';
    }
    return imageKey;
  }

  static (int, int) calculateTargetSize(BuildContext context) =>
      _calculateWebPTargetSize(context);


  static bool isLikelyWebP(String imageKey) => _isLikelyWebP(imageKey);

  @override
  Future<WebPImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<WebPImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    WebPImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return _WebPImageStreamCompleter(
      _loadImageAsync(chunkEvents: chunkEvents),
      key,
      chunkEvents: chunkEvents.stream,
    );
  }

  // ── Public static helpers ──────────────────────────────────

  /// Ensure a DecoderHolder exists. Used by PrecreateTask.
  /// [onlyIfCached]: if true, skip network fetch.
  static Future<DecoderHolder?> ensureHolder({
    required String imageKey,
    required String fullKey,
    DecodedImageCache? cache,
    String? sourceKey,
    required String cid,
    required String eid,
    int targetWidth = 0,
    int targetHeight = 0,
    double scale = 1.0,
    Uint8List? providedBytes,
    bool onlyIfCached = false,
  }) =>
      _ensureWebPHolder(
        imageKey: imageKey,
        fullKey: fullKey,
        cache: cache,
        sourceKey: sourceKey,
        cid: cid,
        eid: eid,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        scale: scale,
        providedBytes: providedBytes,
        onlyIfCached: onlyIfCached,
      );

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

  // ── Static entry points (called by reader UI) ──────────────

  static void onPageChanged({
    required int currentPageIndex,
    required List<String> images,
    required BuildContext context,
    required String cid,
    required String eid,
    required String? sourceKey,
    DecodedImageCache? cache,
  }) =>
      _onWebPPageChanged(
        currentPageIndex: currentPageIndex,
        images: images,
        context: context,
        cid: cid,
        eid: eid,
        sourceKey: sourceKey,
        cache: cache,
      );

  static void clearAll() => DecoderManager.instance.clearAll();

  static void setInteractionState(InteractionState state) {
    PipelineController.instance.setInteractionState(state);
    DecoderManager.instance.setInteractionState(state);
  }

  static bool get isJumpingInteraction =>
      PipelineController.instance.interactionState == InteractionState.jumping;
}

// ═══════════════════════════════════════════════════════════════
// 6. ImageStreamCompleter — simple, delegates animation to holder
// ═══════════════════════════════════════════════════════════════
