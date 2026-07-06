import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/images.dart';

/// 统一的图片字节加载器 — 消除 4 处重复的三路径逻辑。
///
/// 加载顺序：
///   1. 无协议但本地文件存在 → 直接读取
///   2. `file://` 协议 → 直接文件读取
///   3. 磁盘缓存 → 直接返回
///   4. 网络图片 → [ImageDownloader] 下载
///
/// 所有路径都通过 [fetchImageBytes] 入口，自动进行 per-key 去重。
/// 如需独立流（如下载管理器），使用 [fetchImageBytesRaw]。

/// 尝试从本地文件系统加载字节（不触发网络请求）。
///
/// 处理 `file://` 协议路径和直接文件路径两种情况。
/// 直接委托 `File()` — Android 上 `_IOOverrides.createFile` 会透明处理
/// SAF 路径（如 `file://android://primary:...` → strip `file://` → `AndroidFile`）。
///
/// 返回 null 表示不是本地文件，需要走网络加载。
Future<Uint8List?> tryLoadLocalFile(String imageKey) async {
  // 1. 网络 URL（https://、http:// 等）→ 跳过本地检测
  if (imageKey.contains('://') && !imageKey.startsWith('file://')) {
    return null;
  }

  // 2. 直接走 File() — IOOverrides 透明处理 Android SAF
  try {
    final file = File(imageKey);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) return bytes;
    }
  } on FileSystemException {
    if (imageKey.startsWith('file://')) rethrow;
  } catch (_) {
    if (imageKey.startsWith('file://')) {
      throw FileSystemException('Local file not accessible', imageKey);
    }
  }

  // 3. file:// 路径但文件不存在 → 报错（不跌落网络）
  if (imageKey.startsWith('file://')) {
    throw FileSystemException('Local file not found or inaccessible', imageKey);
  }

  return null;
}

/// 全局 per-key 单飞锁：防止并发 I/O 读写同一文件造成竞态。
final Map<String, Future<Uint8List>> _pendingByteLoads = {};

/// 获取图片原始字节（带去重）。
///
/// 多次并发调用同一 [imageKey] 只会触发一次实际 I/O。
Future<Uint8List> fetchImageBytes(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  void Function(int currentBytes, int? totalBytes)? onProgress,
  void Function()? checkStop,
}) async {
  final pending = _pendingByteLoads[imageKey];
  if (pending != null) {
    return pending;
  }

  final completer = Completer<Uint8List>();
  _pendingByteLoads[imageKey] = completer.future;

  try {
    final bytes = await fetchImageBytesRaw(
      imageKey,
      sourceKey,
      cid,
      eid,
      onProgress: onProgress,
      checkStop: checkStop,
    );
    completer.complete(bytes);
    return bytes;
  } catch (e) {
    completer.completeError(e);
    rethrow;
  } finally {
    _pendingByteLoads.remove(imageKey);
  }
}

/// 获取图片原始字节（无去重，本地 → 磁盘缓存 → 网络）。
Future<Uint8List> fetchImageBytesRaw(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  void Function(int currentBytes, int? totalBytes)? onProgress,
  void Function()? checkStop,
}) async {
  // 1. 本地文件（file:// 或直接路径）
  try {
    final local = await tryLoadLocalFile(imageKey);
    if (local != null) return local;
  } on FileSystemException {
    // file:// 路径无法读取 → 不跌落网络，直接传播错误
    if (imageKey.startsWith('file://')) rethrow;
    // 其他 FileSystemException → 继续尝试磁盘缓存和网络
  }

  // 2. 磁盘缓存（在发起网络请求前检查）
  final cacheKey = '$imageKey@$sourceKey@$cid@$eid';
  try {
    final cacheFile = await CacheManager().findCache(cacheKey);
    if (cacheFile != null && await cacheFile.exists()) {
      final bytes = await cacheFile.readAsBytes();
      if (bytes.isNotEmpty) return bytes;
    }
  } catch (_) {}

  // 3. 网络下载
  Uint8List? result;
  await for (final event
      in ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid)) {
    checkStop?.call();
    onProgress?.call(event.currentBytes, event.totalBytes);
    if (event.imageBytes != null) {
      result = event.imageBytes!;
      break;
    }
  }
  if (result == null) throw Exception('Load failed: $imageKey');
  return result;
}

/// 尝试从磁盘缓存读取字节（不触发网络请求）。
///
/// 先检查本地文件，再检查磁盘缓存。返回 null 表示未命中。
Future<Uint8List?> tryReadFromCache(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid,
) async {
  final local = await tryLoadLocalFile(imageKey);
  if (local != null) return local;

  final cacheKey = '$imageKey@$sourceKey@$cid@$eid';
  try {
    final cacheFile = await CacheManager().findCache(cacheKey);
    if (cacheFile != null && await cacheFile.exists()) {
      final bytes = await cacheFile.readAsBytes();
      if (bytes.isNotEmpty) return bytes;
    }
  } catch (e) {
    Log.error('Disk cache check failed for $imageKey', e);
  }
  return null;
}
