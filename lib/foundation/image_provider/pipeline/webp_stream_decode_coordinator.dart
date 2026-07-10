import 'dart:async';
import 'dart:typed_data';

import 'package:venera/foundation/image_provider/webp_image_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/trace_log.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

import 'resource_entry.dart';
import 'resource_manager.dart';

typedef WebPStreamDecodeHandle = ({
  void Function(ImageDownloadProgress event) onEvent,
  void Function() dispose,
});

class WebPStreamDecodeCoordinator {
  final void Function(String fullKey, dynamic holder) onHolderPublished;
  final Set<String> _attached = {};
  final Map<String, StreamSubscription<ImageDownloadProgress>> _subs = {};
  final Map<String, void Function()> _disposers = {};

  WebPStreamDecodeCoordinator({required this.onHolderPublished});

  bool hasAttached(String fullKey) => _attached.contains(fullKey);

  bool isDownloadLoading(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) =>
      ImageDownloader.isLoadingComicImage(imageKey, sourceKey, cid, eid);

  void markDownloadStale(ResourceEntry entry) {
    final holder = DecoderManager.instance.getHolder(entry.fullKey);
    if (holder != null) {
      _dropHolder(entry, holder, 'stale pipeline download');
    }
    detach(entry.fullKey);
  }

  WebPStreamDecodeHandle? start(
    ResourceEntry entry, {
    required ResourceManager resources,
    required int targetWidth,
    required int targetHeight,
  }) {
    if (!entry.policy.allowDecode || !entry.policy.allowGpuUpload) return null;
    if (!_attached.add(entry.fullKey)) return null;
    final existingHolder = DecoderManager.instance.getHolder(entry.fullKey);
    DecoderHolder? holder = existingHolder != null &&
            !existingHolder.disposed &&
            existingHolder.decoder.isStreaming &&
            !existingHolder.decoder.streamIsComplete
        ? existingHolder
        : null;
    webp.WebPAnimDecoder? decoder = holder?.decoder;
    var appendedUntil = holder != null && !holder.streamNeedsResume
        ? holder.streamLoadedBytes
        : 0;
    var stopped = false;
    var completed = false;
    if (holder != null) {
      if (!holder.acquireStreamOwner('pipeline')) {
        _attached.remove(entry.fullKey);
        return null;
      }
      if (holder.streamNeedsResume && decoder != null && !decoder.isDisposed) {
        decoder.resetStreamInput();
        holder.clearBufferedFrames();
        holder.resetStreamPlaybackState();
        holder.updateStreamTransfer(0, null, reset: true);
        holder.traceStreamState('RESUME-RESET pipeline');
      }
      _publishHolder(resources, entry, holder);
    }

    void dispose() {
      stopped = true;
      _attached.remove(entry.fullKey);
      _disposers.remove(entry.fullKey);
      final d = decoder;
      if (holder != null &&
          !completed &&
          d != null &&
          !d.isDisposed &&
          d.isStreaming &&
          !d.streamIsComplete) {
        _dropHolder(entry, holder!, 'pipeline stream detached');
      }
      holder?.releaseStreamOwner('pipeline');
      if (holder == null && d != null && !d.isDisposed) d.dispose();
    }
    _disposers[entry.fullKey] = dispose;

    void onEvent(ImageDownloadProgress event) {
      if (stopped) return;
      final canDecode = entry.policy.allowDecode && entry.policy.allowGpuUpload;
      if (entry.hasHolder && holder == null) {
        stopped = true;
        dispose();
        return;
      }
      if (event.reset && decoder != null && !decoder!.isDisposed) {
        decoder!.resetStreamInput();
        holder?.clearBufferedFrames();
        holder?.updateStreamTransfer(0, null, reset: true);
        holder?.resetStreamPlaybackState();
        holder?.traceStreamState('SIGNAL-RESET pipeline');
        holder?.notifyStreamInputChanged();
        appendedUntil = 0;
      }
      final chunk = event.chunkBytes;
      if (chunk != null) {
        if (!canDecode && decoder == null) return;
        decoder ??= webp.createStreamingAnimDecoder(
          targetWidth: targetWidth,
          targetHeight: targetHeight,
        );
        final d = decoder;
        if (d == null || d.isDisposed) return;
        final chunkEnd = event.currentBytes;
        final chunkStart = chunkEnd - chunk.length;
        if (chunkStart > appendedUntil) {
          final error = StateError(
            'stream chunk gap: $appendedUntil..$chunkStart',
          );
          holder?.markStreamFailed(error);
          Log.error('WebP.Stream.Pipeline', '${entry.imageKey} $error');
          stopped = true;
          dispose();
          return;
        }
        if (chunkEnd <= appendedUntil) {
          holder?.updateStreamTransfer(event.currentBytes, event.totalBytes);
          holder?.markStreamActive();
          if (canDecode) holder?.notifyStreamInputChanged();
          return;
        }
        final data = chunkStart < appendedUntil
            ? Uint8List.sublistView(chunk, appendedUntil - chunkStart)
            : chunk;
        appendedUntil = chunkEnd;
        final ready = d.appendStreamChunk(data);
        if (ready &&
            d.streamIsAnimated &&
            canDecode &&
            holder == null &&
            d.frameCount > 0 &&
            d.targetWidth > 0) {
          holder = DecoderManager.instance.getOrCreateHolder(
            entry.fullKey,
            d,
            d.targetWidth,
            d.targetHeight,
            1.0,
          );
          final h = holder!;
          if (!h.acquireStreamOwner('pipeline')) {
            stopped = true;
            dispose();
            return;
          }
          h.updateStreamTransfer(event.currentBytes, event.totalBytes);
          h.markStreamActive();
          _publishHolder(resources, entry, h);
          if (canDecode) holder?.notifyStreamInputChanged();
        } else {
          holder?.updateStreamTransfer(event.currentBytes, event.totalBytes);
          holder?.markStreamActive();
          if (canDecode) holder?.notifyStreamInputChanged();
        }
      }
      if (event.imageBytes != null) {
        completed = true;
        holder?.updateStreamTransfer(
          event.imageBytes!.length,
          event.imageBytes!.length,
        );
        holder?.traceStreamState('SIGNAL-FINAL pipeline');
        if (holder == null) {
          TraceLog.info(
            'WebP.Stream.Signal',
            'SIGNAL-FINAL pipeline no-holder ${entry.fullKey} '
                'bytes=${event.imageBytes!.length}',
          );
        }
        final d = decoder;
        if (d != null && !d.isDisposed) {
          d.appendStreamChunk(
            appendedUntil < event.imageBytes!.length
                ? Uint8List.sublistView(event.imageBytes!, appendedUntil)
                : Uint8List(0),
            isFinal: true,
          );
          if (canDecode) holder?.notifyStreamInputChanged();
          if (holder == null) d.dispose();
        }
      }
    }
    return (onEvent: onEvent, dispose: dispose);
  }

  bool attachToRunningDownload(
    ResourceEntry entry,
    String? sourceKey,
    String cid,
    String eid, {
    required ResourceManager resources,
    required int targetWidth,
    required int targetHeight,
  }) {
    if (!entry.policy.allowDecode || !entry.policy.allowGpuUpload) return false;
    if (_attached.contains(entry.fullKey)) return true;
    if (entry.hasHolder) return false;
    final stream = ImageDownloader.joinLoadingComicImage(
      entry.imageKey,
      sourceKey,
      cid,
      eid,
      debugLabel: 'pipeline-stream-attach',
    );
    if (stream == null) {
      return false;
    }
    final handle = start(
      entry,
      resources: resources,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    if (handle == null) return true;
    late StreamSubscription<ImageDownloadProgress> sub;
    sub = stream.listen(
      (event) {
        final active = entry.download.inProgress &&
            entry.policy.allowDecode &&
            entry.policy.allowGpuUpload &&
            !entry.hasBytes;
        if (!active) {
          detach(entry.fullKey);
          return;
        }
        handle.onEvent(event);
      },
      onError: (e) {
        Log.warning(
          'WebP.Stream.Pipeline',
          'ATTACH-ERROR ${entry.imageKey} $e',
        );
        detach(entry.fullKey);
      },
      onDone: () => detach(entry.fullKey),
      cancelOnError: false,
    );
    _subs[entry.fullKey] = sub;
    _disposers[entry.fullKey] = handle.dispose;
    return true;
  }

  void detach(String fullKey) {
    _subs.remove(fullKey)?.cancel();
    _disposers.remove(fullKey)?.call();
    _attached.remove(fullKey);
  }

  void detachInactive(Set<String> activeImageKeys, ResourceManager resources) {
    for (final fullKey in _subs.keys.toList()) {
      final imageKey = _baseKey(fullKey);
      final entry = resources.get(fullKey);
      final active = entry != null &&
          ((entry.download.inProgress && !entry.hasBytes) ||
              activeImageKeys.contains(imageKey));
      if (!active) detach(fullKey);
    }
  }

  void clear() {
    for (final fullKey in _subs.keys.toList()) {
      detach(fullKey);
    }
    for (final dispose in _disposers.values.toList()) {
      dispose();
    }
    _subs.clear();
    _disposers.clear();
    _attached.clear();
  }

  void _publishHolder(
    ResourceManager resources,
    ResourceEntry entry,
    DecoderHolder holder,
  ) {
    for (final peer in resources.getAllForImage(entry.imageKey)) {
      if (peer.fullKey == entry.fullKey) {
        peer.holder = holder;
        peer.decode.markSuccess();
      }
    }
    onHolderPublished(entry.fullKey, holder);
  }

  void _dropHolder(ResourceEntry entry, DecoderHolder holder, String reason) {
    holder.traceStreamState('DROP-HOLDER $reason');
    for (final peer in _resourcesForDrop(entry)) {
      peer.holder = null;
      peer.decode.reset();
    }
    DecoderManager.instance.removeHolder(holder.key);
  }

  Iterable<ResourceEntry> _resourcesForDrop(ResourceEntry entry) sync* {
    yield entry;
  }

  static String _baseKey(String fullKey) {
    final at = fullKey.lastIndexOf('@');
    if (at < 0) return fullKey;
    final suffix = fullKey.substring(at + 1);
    return RegExp(r'^\d+x\d+$').hasMatch(suffix)
        ? fullKey.substring(0, at)
        : fullKey;
  }
}
