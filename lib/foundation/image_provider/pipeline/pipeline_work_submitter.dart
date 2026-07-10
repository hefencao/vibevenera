import 'dart:typed_data';

import 'package:venera/foundation/image_provider/cache/decoded_image_cache.dart';
import 'package:venera/foundation/image_provider/webp_image_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'download_progress_publisher.dart';
import 'prefetch_budget.dart';
import 'resource_entry.dart';
import 'resource_manager.dart';
import 'tasks.dart';
import 'task_scheduler.dart';
import 'webp_stream_decode_coordinator.dart';

class PipelineWorkSubmitter {
  final ResourceManager resources;
  final TaskScheduler scheduler;
  final WebPStreamDecodeCoordinator streamDecodes;
  final DownloadProgressPublisher progress;
  final String Function() currentKey;
  final bool Function(int session) isSessionActive;
  final void Function(String imageKey, Uint8List bytes) onBytesPublished;
  final PrefetchBudget _prefetchBudget = const PrefetchBudget();

  PipelineWorkSubmitter({
    required this.resources,
    required this.scheduler,
    required this.streamDecodes,
    required this.progress,
    required this.currentKey,
    required this.isSessionActive,
    required this.onBytesPublished,
  });

  void submit({
    required String? sourceKey,
    required String cid,
    required String eid,
    required int targetWidth,
    required int targetHeight,
    required DecodedImageCache? cache,
    required int session,
  }) {
    final entries = <ResourceEntry>[];
    resources.forEach(entries.add);
    entries.sort((a, b) => _entrySubmitRank(b).compareTo(_entrySubmitRank(a)));
    for (final entry in entries) {
      _evaluateEntry(
        entry,
        sourceKey,
        cid,
        eid,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        cache: cache,
        session: session,
      );
    }
  }

  void submitEntry(
    ResourceEntry entry, {
    required String? sourceKey,
    required String cid,
    required String eid,
    required int targetWidth,
    required int targetHeight,
    required DecodedImageCache? cache,
    required int session,
  }) {
    _evaluateEntry(
      entry,
      sourceKey,
      cid,
      eid,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      cache: cache,
      session: session,
    );
  }

  void publishBytes(String imageKey, Uint8List bytes) {
    for (final peer in resources.getAllForImage(imageKey)) {
      peer.bytes = bytes;
      peer.download.inProgress = false;
      peer.download.lastError = null;
    }
    progress.complete(imageKey, currentKey());
    onBytesPublished(imageKey, bytes);
  }

  void publishDownloadProgress(
    String imageKey,
    int current,
    int? total, {
    bool done = false,
  }) {
    for (final peer in resources.getAllForImage(imageKey)) {
      peer.download.updateProgress(current, total);
    }
    progress.update(
      imageKey,
      current,
      total,
      currentKey: currentKey(),
      done: done,
    );
  }

  void syncCurrentDownloadProgress() {
    final key = currentKey();
    progress.syncCurrent(key, resources.get(key));
  }

  int _entrySubmitRank(ResourceEntry entry) {
    final d = entry.policy.downloadPriority;
    final p = entry.policy.decodePriority;
    return d > p ? d : p;
  }

  void _evaluateEntry(
    ResourceEntry entry,
    String? sourceKey,
    String cid,
    String eid, {
    required int targetWidth,
    required int targetHeight,
    required DecodedImageCache? cache,
    required int session,
  }) {
    _submitDownload(
      entry,
      sourceKey,
      cid,
      eid,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      cache: cache,
      session: session,
    );
    _submitDecode(
      entry,
      sourceKey,
      cid,
      eid,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      cache: cache,
      session: session,
    );
    _submitEviction(entry);
  }

  void _submitDownload(
    ResourceEntry entry,
    String? sourceKey,
    String cid,
    String eid, {
    required int targetWidth,
    required int targetHeight,
    required DecodedImageCache? cache,
    required int session,
  }) {
    if (!entry.policy.allowDownload) return;
    if (entry.hasBytes) return;
    final l2Bytes = cache?.getL2(entry.imageKey);
    if (l2Bytes != null) {
      publishBytes(entry.imageKey, l2Bytes);
      return;
    }
    for (final peer in resources.getAllForImage(entry.imageKey)) {
      if (peer.bytes != null) {
        publishBytes(entry.imageKey, peer.bytes!);
        return;
      }
    }
    if (entry.download.inProgress) {
      final attached = streamDecodes.attachToRunningDownload(
        entry,
        sourceKey,
        cid,
        eid,
        resources: resources,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      if (attached ||
          scheduler.hasTask(entry.imageKey) ||
          streamDecodes.isDownloadLoading(
            entry.imageKey,
            sourceKey,
            cid,
            eid,
          )) {
        return;
      }
      Log.warning('WebP.Stream.Pipeline', 'STALE-DOWNLOAD ${entry.imageKey}');
      entry.download.inProgress = false;
      streamDecodes.markDownloadStale(entry);
    }
    if (_prefetchBudget.exceededFor(entry, resources)) return;

    entry.download.inProgress = true;
    final streamDecode = streamDecodes.start(
      entry,
      resources: resources,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final task = DownloadTask(
      key: entry.imageKey,
      imageKey: entry.imageKey,
      fullKey: entry.fullKey,
      generation: entry.generation,
      priority: entry.policy.downloadPriority,
      cancelable: true,
      sourceKey: sourceKey,
      cid: cid,
      eid: eid,
      onProgress: (current, total) {
        if (!isSessionActive(session)) return;
        for (final peer in resources.getAllForImage(entry.imageKey)) {
          peer.download.updateProgress(current, total);
        }
        publishDownloadProgress(entry.imageKey, current, total);
      },
      onEvent: streamDecode?.onEvent,
      onDispose: streamDecode?.dispose,
    );
    task
        .register()
        .then((bytes) {
          if (!isSessionActive(session)) return;
          publishBytes(entry.imageKey, bytes);
          if (cache != null && !cache.isDisposed && webp.isWebP(bytes)) {
            cache.putL2(entry.imageKey, bytes);
          }
          for (final peer in resources.getAllForImage(entry.imageKey)) {
            _submitDecode(
              peer,
              sourceKey,
              cid,
              eid,
              targetWidth: targetWidth,
              targetHeight: targetHeight,
              cache: cache,
              session: session,
            );
          }
        })
        .catchError((_) {
          if (!isSessionActive(session)) return;
          entry.download.inProgress = false;
          streamDecodes.detach(entry.fullKey);
        });
    task.setContext(ExecutionContext(entry));
    scheduler.submit(task);
  }

  void _submitDecode(
    ResourceEntry entry,
    String? sourceKey,
    String cid,
    String eid, {
    required int targetWidth,
    required int targetHeight,
    required DecodedImageCache? cache,
    required int session,
  }) {
    if (!entry.policy.allowDecode) return;
    if (entry.hasHolder) return;
    if (!entry.hasBytes) return;
    if (entry.decode.inProgress) return;
    if (entry.decode.isInBackoff) return;

    entry.decode.inProgress = true;
    final task = PrecreateTask(
      key: entry.fullKey,
      imageKey: entry.imageKey,
      generation: entry.generation,
      priority: entry.policy.decodePriority,
      cancelable: true,
      sourceKey: sourceKey,
      cid: cid,
      eid: eid,
      holderFactory: WebPImageProvider.ensureHolder,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      scale: 1.0,
      cache: cache,
      providedBytes: entry.bytes,
    );
    task
        .register()
        .then((holder) {
          if (!isSessionActive(session)) return;
          if (holder == null) {
            entry.decode.markFailure('No animated WebP holder created');
            return;
          }
          entry.holder = holder;
          entry.decode.markSuccess();
        })
        .catchError((e) {
          if (!isSessionActive(session)) return;
          entry.decode.markFailure(e);
        });
    task.setContext(ExecutionContext(entry));
    scheduler.submit(task);
  }

  void _submitEviction(ResourceEntry entry) {
    if (!entry.policy.allowEviction) return;
    if (!entry.hasBytes && !entry.hasHolder) return;
    resources.release(entry);
  }
}
