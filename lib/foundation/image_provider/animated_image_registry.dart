import 'package:flutter/foundation.dart';

/// 由解码器在确认第二帧后发布。它记录具体图片，不把整个漫画源误判为动图源。
final class AnimatedImageRegistry {
  AnimatedImageRegistry._();

  static final revision = ValueNotifier<int>(0);
  static final Set<String> _keys = {};

  static String key({
    required String imageKey,
    required String? sourceKey,
    required String cid,
    required String eid,
  }) => '$imageKey@$sourceKey@$cid@$eid';

  static bool contains(String key) => _keys.contains(key);

  static void mark(String key) {
    if (!_keys.add(key)) return;
    if (_keys.length > 512) _keys.remove(_keys.first);
    revision.value++;
  }
}
