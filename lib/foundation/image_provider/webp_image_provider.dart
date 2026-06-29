import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:venera/foundation/image_provider/decoded_image_cache.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

/// 基于 FFI libwebp 的 WebP 图像提供器。
///
/// 支持静态和动画 WebP，集成三级缓存。
class WebPImageProvider extends ImageProvider<WebPImageProvider> {
  WebPImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.cache,
    this.targetWidth = 1080,
    this.targetHeight = 1920,
  });

  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;
  final int page;
  final DecodedImageCache? cache;
  final int targetWidth;
  final int targetHeight;

  @override
  Future<WebPImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<WebPImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
      WebPImageProvider key, ImageDecoderCallback decode) {
    return _WebPImageStreamCompleter(_loadImageAsync(), key);
  }

  Future<_ImageResult> _loadImageAsync() async {
    // ── 1. 获取原始字节 ──
    Uint8List rawBytes;

    // 检查 L2 缓存
    if (cache != null && cache!.hasL2(imageKey)) {
      rawBytes = cache!.getL2(imageKey)!;
    } else {
      rawBytes = await _fetchBytes();

      // 存入 L2
      if (cache != null && webp.isWebP(rawBytes)) {
        cache!.putL2(imageKey, rawBytes);
      }
    }

    // ── 2. 检查 L1 缓存 ──
    if (cache != null) {
      final cached = cache!.getL1(imageKey);
      if (cached != null) {
        return _ImageResult.static(ImageInfo(image: cached));
      }
    }

    // ── 3. 格式校验 ──
    if (!webp.isWebP(rawBytes)) {
      // 不是 WebP，走 Flutter 内置解码
      return _ImageResult.fallback(rawBytes);
    }

    // ── 4. 检测类型并解码 ──
    final info = webp.getInfo(rawBytes);
    if (info == null) {
      return _ImageResult.error('Failed to parse WebP header');
    }

    if (info.isAnimated) {
      return _decodeAnimated(rawBytes);
    } else {
      return _decodeStatic(rawBytes);
    }
  }

  Future<_ImageResult> _decodeStatic(Uint8List rawBytes) {
    final frame = webp.decodeStatic(rawBytes,
        targetWidth: targetWidth, targetHeight: targetHeight);
    if (frame == null) {
      return Future.value(_ImageResult.error('Failed to decode static WebP'));
    }

    final completer = Completer<_ImageResult>();
    try {
      ui.decodeImageFromPixels(
        frame.rgba,
        frame.width,
        frame.height,
        ui.PixelFormat.rgba8888,
        (image) {
          // 存入 L1
          if (cache != null) {
            cache!.putL1(imageKey, image);
          }
          completer.complete(_ImageResult.static(ImageInfo(image: image)));
        },
      );
    } catch (e) {
      completer.complete(_ImageResult.error('Failed to create ui.Image: $e'));
    }
    return completer.future;
  }

  Future<_ImageResult> _decodeAnimated(Uint8List rawBytes) async {
    // 使用 FFI libwebp 解码
    final sw = Stopwatch()..start();
    final decoder = webp.createAnimDecoder(rawBytes,
        targetWidth: targetWidth, targetHeight: targetHeight);
    if (decoder == null) return _ImageResult.error('Failed to create anim decoder');
    debugPrint('[WebP] createAnimDecoder: ${sw.elapsedMilliseconds}ms, ${decoder.frameCount}frames, canvas=${decoder.canvasWidth}x${decoder.canvasHeight}, target=${decoder.targetWidth}x${decoder.targetHeight}');
    return _ImageResult.animated(decoder);
  }

  // ─── 内部方法 ───

  Future<Uint8List> _fetchBytes() async {
    if (imageKey.startsWith('file://')) {
      final file = File(imageKey.substring(7));
      return await file.readAsBytes();
    }

    Uint8List? result;
    await for (final event
        in ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid)) {
      if (event.imageBytes != null) {
        result = event.imageBytes!;
        break;
      }
    }
    if (result == null) {
      throw Exception('Failed to load image: $imageKey');
    }
    return result;
  }

  String get key => 'webp:$imageKey@$sourceKey@$cid@$eid@$page';

  @override
  bool operator ==(Object other) {
    return other is WebPImageProvider && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'WebPImageProvider($key)';
}

// ═══════════════════════════════════════════════════════════════
// Isolate 预解码函数（必须为顶级函数）
// ═══════════════════════════════════════════════════════════════

/// 在 Isolate 中同步解码所有帧，返回 [rgba, durationMs] 列表。
@pragma('vm:entry-point')
List<Map<String, dynamic>>? _decodeAllFramesSync(
    Uint8List bytes, int targetW, int targetH) {
  final decoder = webp.createAnimDecoder(bytes,
      targetWidth: targetW, targetHeight: targetH);
  if (decoder == null) return null;

  final frames = <Map<String, dynamic>>[];
  while (decoder.hasMoreFrames) {
    final frame = decoder.getNextFrame();
    if (frame == null) break;
    frames.add({
      'rgba': frame.rgba,
      'durationMs': frame.durationMs,
    });
  }
  // 所有帧同尺寸，加在第一条
  if (frames.isNotEmpty) {
    frames[0]['w'] = decoder.targetWidth;
    frames[0]['h'] = decoder.targetHeight;
  }
  decoder.dispose();
  return frames;
}

// ═══════════════════════════════════════════════════════════════
// Stream Completer
// ═══════════════════════════════════════════════════════════════

class _WebPImageStreamCompleter extends ImageStreamCompleter {
  final WebPImageProvider _provider;
  bool _disposed = false;

  _WebPImageStreamCompleter(Future<_ImageResult> future, this._provider) {
    future.then(_onResult, onError: _onError);
  }

  void _onResult(_ImageResult result) {
    if (_disposed) return;
    switch (result.type) {
      case _ResultType.static:
        setImage(result.imageInfo!);
        break;
      case _ResultType.animated:
        _startAnimation(result.decoder!);
        break;
      case _ResultType.fallback:
        _fallbackDecode(result.rawBytes!);
        break;
      case _ResultType.predecoded:
        _playPredecoded(result.frames!);
        break;
      case _ResultType.error:
        reportError(
          context: ErrorDescription('WebPImageProvider(${_provider.key})'),
          exception: result.error ?? 'Unknown error',
        );
        break;
    }
  }

  void _onError(Object error, StackTrace? stack) {
    if (_disposed) return;
    reportError(
      context: ErrorDescription('WebPImageProvider(${_provider.key})'),
      exception: error,
      stack: stack,
    );
  }

  void _fallbackDecode(Uint8List bytes) {
    ui.instantiateImageCodec(bytes).then((codec) {
      codec.getNextFrame().then((frameInfo) {
        if (!_disposed) {
          setImage(ImageInfo(image: frameInfo.image));
        }
      });
    }).catchError((error) {
      if (!_disposed) {
        reportError(
          context: ErrorDescription('Fallback decode failed'),
          exception: error,
        );
      }
    });
  }

  /// 从 Flutter Codec 播放动画（首次循环），同时缓存 RGBA 供后续
  void _playFromCodec(ui.Codec codec) {
    final frames = <_AnimFrame>[];
    void playNext() async {
      if (_disposed) { codec.dispose(); return; }

      // 如果已缓存所有帧，用缓存播放
      if (frames.length >= codec.frameCount) {
        _playPredecoded(frames);
        codec.dispose();
        return;
      }

      try {
        final frameInfo = await codec.getNextFrame();
        if (_disposed) { frameInfo.image.dispose(); codec.dispose(); return; }

        final durMs = frameInfo.duration.inMilliseconds;

        // 先读回 RGBA 再 setImage（setImage 会 dispose 上一帧）
        final data = await frameInfo.image
            .toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        final rgba = data?.buffer.asUint8List();

        if (_disposed) { frameInfo.image.dispose(); codec.dispose(); return; }

        setImage(ImageInfo(image: frameInfo.image));
        if (rgba != null) {
          frames.add(_AnimFrame(
            rgba: rgba,
            durationMs: durMs,
            w: frameInfo.image.width,
            h: frameInfo.image.height,
          ));
        }

        Future.delayed(Duration(milliseconds: durMs), playNext);
      } catch (e) {
        debugPrint('[WebP] Codec play error: $e');
        codec.dispose();
      }
    }

    playNext();
  }

  /// 播放预解码帧（Isolate 解码完成后直接播放）
  void _playPredecoded(List<_AnimFrame> frames) {
    if (_disposed || frames.isEmpty) return;
    var i = 0;

    void playFrame() {
      if (_disposed || i >= frames.length) {
        // 循环
        i = 0;
        if (frames.isEmpty) return;
      }

      final frame = frames[i++];
      final uploadSw = Stopwatch()..start();
      ui.decodeImageFromPixels(
        frame.rgba,
        frame.w,
        frame.h,
        ui.PixelFormat.rgba8888,
        (image) {
          if (_disposed) {
            image.dispose();
            return;
          }
          final elapsed = uploadSw.elapsedMilliseconds;
          setImage(ImageInfo(image: image));
          final delay = (frame.durationMs - elapsed).clamp(0, frame.durationMs);
          Future.delayed(Duration(milliseconds: delay), playFrame);
        },
      );
    }

    playFrame();
  }

  void _startAnimation(webp.WebPAnimDecoder decoder) {
    var isActive = true;
    webp.WebPAnimFrameAddress? pendingFrame;
    bool fetching = false;
    int consecutiveNullFrames = 0;

    void releaseDecoder() {
      if (!isActive) return;
      isActive = false;
      decoder.dispose();
    }

    /// 预取下一帧到 [pendingFrame]（非阻塞，pipeline 方式）
    Future<void> fetchNext() async {
      if (fetching || pendingFrame != null || !isActive || _disposed) return;
      fetching = true;
      try {
        if (!decoder.hasMoreFrames) {
          decoder.reset();
        }
        final result = await decoder.getNextFrameAsync();
        if (result != null) {
          pendingFrame = result;
          consecutiveNullFrames = 0;
        } else {
          consecutiveNullFrames++;
          if (consecutiveNullFrames > 3) {
            debugPrint('[WebP] Too many consecutive decode failures, stopping animation');
            releaseDecoder();
          }
        }
      } catch (e) {
        debugPrint('[WebP] fetchNext error: $e');
        consecutiveNullFrames++;
      } finally {
        fetching = false;
      }
    }

    /// 播放一帧：等待 pending frame → 上传 GPU → 预取下一帧 → 定时回调
    Future<void> playNext() async {
      if (!isActive || _disposed) {
        releaseDecoder();
        return;
      }

      // 等待 pending frame 就绪
      while (pendingFrame == null && isActive && !_disposed) {
        if (!fetching) {
          await fetchNext();
        }
        if (pendingFrame == null) {
          await Future.delayed(const Duration(milliseconds: 2));
        }
      }
      if (!isActive || _disposed) {
        releaseDecoder();
        return;
      }

      final frame = pendingFrame!;
      pendingFrame = null;

      final int duration = frame.durationMs <= 10 ? 33 : frame.durationMs;
      final int length = decoder.targetWidth * decoder.targetHeight * 4;

      // 零拷贝视图访问原生内存（output ring buffer）
      final rgba = Pointer<Uint8>.fromAddress(frame.address).asTypedList(length);
      final int t0 = DateTime.now().millisecondsSinceEpoch;

      ui.decodeImageFromPixels(
        rgba,
        decoder.targetWidth,
        decoder.targetHeight,
        ui.PixelFormat.rgba8888,
        (image) {
          if (!isActive || _disposed) {
            image.dispose();
            releaseDecoder();
            return;
          }

          setImage(ImageInfo(image: image));

          // 在当前帧展示期间预取下一帧（pipeline，无额外延迟）
          fetchNext();

          // 精确帧计时：duration - GPU 上传耗时，clamp [8, duration]
          final int elapsed = DateTime.now().millisecondsSinceEpoch - t0;
          final int delay = (duration - elapsed).clamp(8, duration);

          Future.delayed(Duration(milliseconds: delay), playNext);
        },
      );
    }

    // 启动：预取第一帧后开始播放
    fetchNext().then((_) => playNext());
  }

  @override
  void onDisposed() {
    _disposed = true;
    super.onDisposed();
  }
}

// ═══════════════════════════════════════════════════════════════
// 内部类型
// ═══════════════════════════════════════════════════════════════

enum _ResultType { static, animated, fallback, error, predecoded }

class _ImageResult {
  final _ResultType type;
  final ImageInfo? imageInfo;
  final webp.WebPAnimDecoder? decoder;
  final Uint8List? rawBytes;
  final Object? error;
  final List<_AnimFrame>? frames;
  final ui.Codec? codec;

  _ImageResult._({
    required this.type,
    this.imageInfo,
    this.decoder,
    this.rawBytes,
    this.error,
    this.frames,
    this.codec,
  });

  factory _ImageResult.static(ImageInfo info) =>
      _ImageResult._(type: _ResultType.static, imageInfo: info);

  factory _ImageResult.animated(webp.WebPAnimDecoder decoder) =>
      _ImageResult._(type: _ResultType.animated, decoder: decoder);

  factory _ImageResult.fallback(Uint8List bytes) =>
      _ImageResult._(type: _ResultType.fallback, rawBytes: bytes);

  factory _ImageResult.error(Object e) =>
      _ImageResult._(type: _ResultType.error, error: e);

  factory _ImageResult.isolateFrames(List<_AnimFrame> frames) =>
      _ImageResult._(type: _ResultType.predecoded, frames: frames);
}

class _AnimFrame {
  final Uint8List rgba;
  final int durationMs;
  final int w;
  final int h;

  _AnimFrame({required this.rgba, required this.durationMs, this.w = 0, this.h = 0});
}
