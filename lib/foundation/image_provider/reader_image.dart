import 'dart:async' show Future, StreamController;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/js_engine.dart';
import 'base_image_provider.dart';
import 'image_fetch.dart';
import 'reader_image.dart' as image_provider;

class ReaderImageProvider
    extends BaseImageProvider<image_provider.ReaderImageProvider> {
  /// Image provider for normal image.
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
    final rawBytes = await _loadRawBytes(chunkEvents, checkStop);
    return _applyCustomImageProcessing(rawBytes, checkStop);
  }

  /// 加载原始字节 — 统一走 [fetchImageBytes]（带去重，file:// → 本地 → 网络）。
  Future<Uint8List> _loadRawBytes(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    return fetchImageBytes(
      imageKey,
      sourceKey,
      cid,
      eid,
      chunkEvents: chunkEvents,
    );
  }

  /// 应用用户自定义 JS 图片处理脚本。
  ///
  /// [FIX-ARCH-5] 从原来的 5 层嵌套提取为扁平的步骤序列：
  ///   1. 检查开关 → 2. 验证脚本 → 3. 执行 JS → 4. 解析返回值
  Future<Uint8List> _applyCustomImageProcessing(
    Uint8List imageBytes,
    void Function() checkStop,
  ) async {
    if (!appdata.settings['enableCustomImageProcessing']) {
      return imageBytes;
    }

    var script = appdata.settings['customImageProcessing'].toString();
    if (!script.contains('function processImage')) {
      return imageBytes;
    }

    var func = JsEngine().runCode('''
      (() => {
        $script
        return processImage;
      })()
    ''');
    if (func is! JSInvokable) {
      return imageBytes;
    }

    var autoFreeFunc = JSAutoFreeFunction(func);
    var result = autoFreeFunc([imageBytes, cid, eid, page, sourceKey]);
    return _extractImageFromResult(result, checkStop);
  }

  /// 从 JS 处理函数的返回值中提取图片字节。
  ///
  /// 支持的返回值类型：
  ///   - `Uint8List` → 直接返回
  ///   - `Future` → 等待后提取
  ///   - `Map` → 从 `image` 字段提取
  Future<Uint8List> _extractImageFromResult(
    dynamic result,
    void Function() checkStop,
  ) async {
    if (result is Uint8List) return result;

    if (result is Future) {
      var futureResult = await result;
      if (futureResult is Uint8List) return futureResult;
      if (futureResult is Map) {
        return _extractImageFromMap(futureResult, checkStop);
      }
      throw Exception(
        'Unexpected processImage result: ${futureResult.runtimeType}',
      );
    }

    if (result is Map) {
      return _extractImageFromMap(result, checkStop);
    }

    throw Exception(
      'Unexpected processImage result type: ${result.runtimeType}',
    );
  }

  /// 从 Map 结构中提取图片字节。
  ///
  /// Map 可包含：
  ///   - `image`: Uint8List 或 `Future<Uint8List>`
  ///   - `onCancel`: JSInvokable — 取消回调
  Future<Uint8List> _extractImageFromMap(
    Map result,
    void Function() checkStop,
  ) async {
    var image = result['image'];
    if (image is Uint8List) return image;

    if (image is! Future) {
      throw Exception('Invalid image field in processImage result');
    }

    JSAutoFreeFunction? onCancel;
    if (result['onCancel'] is JSInvokable) {
      onCancel = JSAutoFreeFunction(result['onCancel']);
    }

    if (onCancel == null) {
      var futureImage = await image;
      if (futureImage is Uint8List) return futureImage;
      throw Exception('Invalid image in processImage result');
    }

    // 有取消支持 → 轮询检查 stop
    dynamic futureImage;
    image.then((value) {
      futureImage = value ?? Uint8List(0);
    });

    while (futureImage == null) {
      try {
        checkStop();
      } catch (e) {
        onCancel([]);
        rethrow;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }

    if (futureImage is Uint8List) return futureImage;
    throw Exception('Invalid image in processImage result');
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "$imageKey@$sourceKey@$cid@$eid@$enableResize";
}
