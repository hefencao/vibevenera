part of 'reader.dart';

/// Gallery/Continuous 共用的图片数据读取能力。
mixin _ImageViewControllerMixin implements _ImageViewController {
  BuildContext get context;

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) return File(imageKey).readAsBytes();
    return (await CacheManager().findCache(
      "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
    ))!.readAsBytes();
  }
}

Widget _buildReaderImageError(
  BuildContext context,
  Object error,
  StackTrace? _,
  VoidCallback retry,
) {
  context.findAncestorStateOfType<_ReaderImagesState>()!
      .refreshPagesForImageError();
  return NetworkError(message: error.toString(), retry: retry);
}

ImageProvider _createImageProviderFromKey(
  String imageKey,
  BuildContext context,
) {
  var reader = context.reader;

  // 普通静态图走轻量 ReaderImageProvider；明确的 GIF/WebP 动图进入流式管线。
  //
  // 判据两条：①文件名含 .webp/.gif；②registry 记得该源确认过流式动图
  // ——因为有的源图片 key 是纯数字无扩展名（如 111），只靠文件名会误判为非 webp、被
  // 打回非流式老路（转圈转完才播）。registry 是会话稳定的（只读上次持久化快照），保证
  // 同一源本会话内所有页 provider 类型一致，翻页无 provider 翻转/无 setState churn。
  final sourceKey = reader.type.comicSource?.key;
  final useStreamingProvider =
      StreamingImageProvider.isLikelyStreamingAnimation(imageKey) ||
      StreamingSourceRegistry.isStreamingSource(sourceKey);
  if (!useStreamingProvider) {
    final page = reader.images?.indexOf(imageKey) ?? 0;
    return ReaderImageProvider(
      imageKey,
      sourceKey,
      reader.cid,
      reader.eid,
      page < 0 ? 0 : page,
    );
  }

  final (targetWidth, targetHeight) =
      StreamingImageProvider.calculateTargetSize(context);
  final double dpr = MediaQuery.of(context).devicePixelRatio;

  return StreamingImageProvider(
    imageKey: imageKey,
    sourceKey: sourceKey,
    cid: reader.cid,
    eid: reader.eid,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
    scale: 1.0 / dpr,
  );
}

ImageProvider _createImageProvider(int page, BuildContext context) {
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  return _createImageProviderFromKey(imageKey, context);
}

void _attachReaderPipeline(BuildContext context) {
  if (!TickerMode.valuesOf(context).enabled) return;
  final reader = context.reader;
  final images = reader.images;
  if (images == null) return;
  final (targetWidth, targetHeight) =
      StreamingImageProvider.calculateTargetSize(context);
  PipelineController.instance.attachReaderSession(ReaderPipelineSession(
    owner: reader,
    images: images,
    cid: reader.cid,
    eid: reader.eid,
    sourceKey: reader.type.comicSource?.key,
    cache: reader._imageViewController?.streamingCache,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
    preloadCount: appdata.settings["preloadImageCount"] ?? 5,
  ));
}

void _reportReaderPage(BuildContext context, int page) =>
    PipelineController.instance.onReaderPageChanged(context.reader, page - 1);
