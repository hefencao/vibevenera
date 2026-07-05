import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:venera/network/images.dart';

/// 共享的图片字节获取工具 — 三路径策略：file:// → 直接文件 → 网络下载。
/// 从 WebPImageProvider._fetchBytesStaticRaw 提取，供 CachedImageProvider、
/// ReaderImageProvider 等复用，避免 file:// 本地路径被错误当作网络 URL 下载。

/// 全局字节单飞锁：防范并发 I/O 读写同一本地文件造成的竞态。
final Map<String, Future<Uint8List>> _pendingByteLoads = {};

/// 获取图片原始字节（带去重）。
Future<Uint8List> fetchImageBytes(
  String imageKey, String? sourceKey, String cid, String eid,
) async {
  if (_pendingByteLoads.containsKey(imageKey)) {
    return _pendingByteLoads[imageKey]!;
  }
  final completer = Completer<Uint8List>();
  _pendingByteLoads[imageKey] = completer.future;
  try {
    final bytes = await fetchImageBytesRaw(imageKey, sourceKey, cid, eid);
    completer.complete(bytes);
    return bytes;
  } catch (e) {
    completer.completeError(e);
    rethrow;
  } finally {
    _pendingByteLoads.remove(imageKey);
  }
}

/// 获取图片原始字节（无去重，直接三路径）。
Future<Uint8List> fetchImageBytesRaw(
  String imageKey, String? sourceKey, String cid, String eid,
) async {
  // 1. file:// 协议 → 直接从文件系统读取
  if (imageKey.startsWith('file://')) {
    final file = File(imageKey);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) return bytes;
    }
    throw FileSystemException('Local file not found or inaccessible', imageKey);
  }

  // 2. 无协议头但本地真实存在 → 直接读文件
  final directFile = File(imageKey);
  if (await directFile.exists()) {
    final bytes = await directFile.readAsBytes();
    if (bytes.isNotEmpty) return bytes;
  }

  // 3. 网络图片 → 走到下载链路
  Uint8List? result;
  await for (final event
      in ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid)) {
    if (event.imageBytes != null) {
      result = event.imageBytes!;
      break;
    }
  }
  if (result == null) throw Exception('Load failed: $imageKey');
  return result;
}
