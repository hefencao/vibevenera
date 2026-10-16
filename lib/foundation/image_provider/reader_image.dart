import 'dart:async' show Future;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/js_engine.dart';

import 'base_image.dart';
import 'io/image_loader.dart';

class ReaderImageProvider extends BaseImageProvider<ReaderImageProvider> {
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.enableResize = false,
  });

  final String imageKey;
  final String? sourceKey;
  final String cid;
  final String eid;
  final int page;

  @override
  final bool enableResize;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    final rawBytes = await fetchImageBytes(
      imageKey,
      sourceKey,
      cid,
      eid,
      chunkEvents: chunkEvents,
      debugLabel: 'reader-page:$page',
    );
    return _applyCustomImageProcessing(rawBytes, checkStop);
  }

  Future<Uint8List> _applyCustomImageProcessing(
    Uint8List imageBytes,
    void Function() checkStop,
  ) async {
    if (!appdata.settings['enableCustomImageProcessing']) return imageBytes;

    final script = appdata.settings['customImageProcessing'].toString();
    if (!script.contains('function processImage')) return imageBytes;

    final function = JsEngine().runCode('''
      (() => {
        $script
        return processImage;
      })()
    ''');
    if (function is! JSInvokable) return imageBytes;

    final autoFreeFunction = JSAutoFreeFunction(function);
    final result = autoFreeFunction([imageBytes, cid, eid, page, sourceKey]);
    return _extractImageFromResult(result, checkStop);
  }

  Future<Uint8List> _extractImageFromResult(
    dynamic result,
    void Function() checkStop,
  ) async {
    if (result is Uint8List) return result;

    if (result is Future) {
      final futureResult = await result;
      if (futureResult is Uint8List) return futureResult;
      if (futureResult is Map) {
        return _extractImageFromMap(futureResult, checkStop);
      }
      throw Exception(
        'Unexpected processImage result: ${futureResult.runtimeType}',
      );
    }

    if (result is Map) return _extractImageFromMap(result, checkStop);
    throw Exception(
      'Unexpected processImage result type: ${result.runtimeType}',
    );
  }

  Future<Uint8List> _extractImageFromMap(
    Map result,
    void Function() checkStop,
  ) async {
    final image = result['image'];
    if (image is Uint8List) return image;
    if (image is! Future) {
      throw Exception('Invalid image field in processImage result');
    }

    JSAutoFreeFunction? onCancel;
    if (result['onCancel'] is JSInvokable) {
      onCancel = JSAutoFreeFunction(result['onCancel']);
    }

    if (onCancel == null) {
      final futureImage = await image;
      if (futureImage is Uint8List) return futureImage;
      throw Exception('Invalid image in processImage result');
    }

    dynamic futureImage;
    Object? futureError;
    StackTrace? futureStack;
    image.then(
      (value) => futureImage = value ?? Uint8List(0),
      onError: (Object error, StackTrace stack) {
        futureError = error;
        futureStack = stack;
      },
    );

    while (futureImage == null && futureError == null) {
      try {
        checkStop();
      } catch (_) {
        onCancel([]);
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    if (futureError != null) {
      Error.throwWithStackTrace(
        futureError!,
        futureStack ?? StackTrace.current,
      );
    }
    if (futureImage is Uint8List) return futureImage as Uint8List;
    throw Exception('Invalid image in processImage result');
  }

  /// When custom processing returns invalid bytes, keep the original validated
  /// network cache; deleting it would only force a redundant redownload.
  @override
  Future<void> evictInvalidCache() async {
    if (!appdata.settings['enableCustomImageProcessing']) {
      await evictImageDiskCache(imageKey, sourceKey, cid, eid);
    }
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => '$imageKey@$sourceKey@$cid@$eid@$enableResize';
}
