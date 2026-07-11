import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 低层 native texture 通道（仅 Android 有实现）。
///
/// 负责 create / update / dispose 一个平台 SurfaceProducer 纹理。上层播放驱动
/// 把已解码的 Premultiplied RGBA8888 帧字节推给 [update]，纹理 id 保持不变，
/// 因此每帧不在 Dart 侧分配 ui.Image，也不触发 setState。
class WebPTextureChannel {
  WebPTextureChannel._();

  static final WebPTextureChannel instance = WebPTextureChannel._();

  static const MethodChannel _channel = MethodChannel('venera/webp_texture');

  /// 仅 Android 提供 native texture 通路。其它平台返回 false，调用方回退到
  /// Flutter ui.Image 渲染。
  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  /// 创建一个纹理，返回 textureId；失败返回 null。
  Future<int?> create() async {
    if (!isSupported) return null;
    return _channel.invokeMethod<int>('create');
  }

  /// 用一帧 Premultiplied RGBA8888 像素更新纹理内容。
  Future<void> update(
    int textureId,
    int width,
    int height,
    Uint8List pixels,
  ) {
    if (!isSupported) return Future<void>.value();
    return _channel.invokeMethod<void>('update', <String, dynamic>{
      'textureId': textureId,
      'width': width,
      'height': height,
      'pixels': pixels,
    });
  }

  Future<void> dispose(int textureId) {
    if (!isSupported) return Future<void>.value();
    return _channel.invokeMethod<void>('dispose', <String, dynamic>{
      'textureId': textureId,
    });
  }
}
