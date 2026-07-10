import 'dart:async' show Future, StreamController, scheduleMicrotask;
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui show Codec;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  static const int maxImagePixel = 2560 * 1440;

  static TargetImageSize _getTargetSize(int width, int height) {
    if (width <= 0 || height <= 0) {
      return TargetImageSize(width: width, height: height);
    }
    final imageRatio = width / height;
    if (imageRatio > 2 || imageRatio < 0.5) {
      return TargetImageSize(width: width, height: height);
    }
    if (width * height > maxImagePixel) {
      final ratio = sqrt(maxImagePixel / (width * height));
      return TargetImageSize(
        width: (width * ratio).round(),
        height: (height * ratio).round(),
      );
    }
    return TargetImageSize(width: width, height: height);
  }

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadBufferAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>(
          'Image provider: $this \n Image key: $key',
          this,
          style: DiagnosticsTreeStyle.errorProperty,
        );
      },
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    T key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      var retryTime = 1;
      var stop = false;
      chunkEvents.onCancel = () => stop = true;

      Uint8List? data;
      while (data == null && !stop) {
        try {
          data = await load(chunkEvents, () {
            if (stop) throw const _ImageLoadingStopException();
          });
        } on _ImageLoadingStopException {
          rethrow;
        } catch (error) {
          final message = error.toString();
          if (message.contains('Invalid Status Code: 404') ||
              message.contains('Invalid Status Code: 403')) {
            rethrow;
          }
          if (message.contains('handshake') && retryTime < 5) {
            retryTime = 5;
          }
          retryTime <<= 1;
          if (retryTime > (1 << 3) || stop) rethrow;
          await Future<void>.delayed(Duration(seconds: retryTime));
        }
      }

      if (stop) throw const _ImageLoadingStopException();
      if (data == null || data.isEmpty) throw Exception('Empty image data');

      try {
        final buffer = await ImmutableBuffer.fromUint8List(data);
        return decode(
          buffer,
          getTargetSize: enableResize ? _getTargetSize : null,
        );
      } catch (error) {
        await evictInvalidCache();
        if (data.length < 2 * 1024) {
          String? text;
          try {
            text = const Utf8Codec(allowMalformed: false).decode(data);
          } on FormatException {
            // Binary data; preserve the original decoder error.
          }
          if (text != null) {
            throw Exception('Expected image data, but got text: $text');
          }
        }
        rethrow;
      }
    } on _ImageLoadingStopException {
      rethrow;
    } catch (error, stackTrace) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      Log.error('Image Loading', error, stackTrace);
      rethrow;
    } finally {
      if (!chunkEvents.isClosed) await chunkEvents.close();
    }
  }

  /// Override when the provider uses a cache key different from [key], or when
  /// invalid transformed output must not evict the original network bytes.
  Future<void> evictInvalidCache() => CacheManager().delete(key);

  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  );

  String get key;

  @override
  bool operator ==(Object other) =>
      other is BaseImageProvider<T> && key == other.key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => '$runtimeType($key)';

  bool get enableResize => false;
}

typedef FileDecoderCallback = Future<ui.Codec> Function(Uint8List);

class _ImageLoadingStopException implements Exception {
  const _ImageLoadingStopException();
}
