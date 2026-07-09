part of '../webp_image_provider.dart';

class WebPStreamSession {
  final WebPImageProvider provider;
  WebPStreamSession(this.provider);

  String get imageKey => provider.imageKey;
  String? get sourceKey => provider.sourceKey;
  String get cid => provider.cid;
  String get eid => provider.eid;
  int get targetWidth => provider.targetWidth;
  int get targetHeight => provider.targetHeight;
  double get scale => provider.scale;
  DecodedImageCache? get cache => provider.cache;
  String get _fullKey => provider._fullKey;
}
