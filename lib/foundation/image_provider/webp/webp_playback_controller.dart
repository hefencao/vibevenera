part of '../webp_image_provider.dart';

class WebPPlaybackController {
  final WebPImageProvider provider;
  final bool Function() hasListeners;
  final void Function(ImageInfo) emitImage;
  bool _disposed = false;
  StreamSubscription<ImageDownloadProgress>? _progressiveSub;
  DecoderHolder? _activeHolder;

  WebPPlaybackController({
    required this.provider,
    required this.hasListeners,
    required this.emitImage,
  });

  void start(
    DecoderHolder holder, {
    StreamSubscription<ImageDownloadProgress>? progressiveSub,
  }) {
    _progressiveSub = progressiveSub;
    unawaited(_run(holder));
  }

  void dispose() {
    _disposed = true;
    _progressiveSub?.cancel();
    _progressiveSub = null;
  }

  void onAppResumed() {
    if (!_disposed) _activeHolder?.resumeFromLifecyclePause();
  }

  Future<void> _run(DecoderHolder initialHolder) async {
    var holder = initialHolder;
    _activeHolder = holder;
    final playback = WebPPlaybackState();
    while (!_disposed) {
      if (await _waitIfNotRenderable()) continue;
      if (await _pauseIfInactive(holder)) continue;

      if (holder.disposed) {
        final nh = await _replaceDisposedHolder(holder, playback);
        if (nh == null) break;
        holder = nh;
        continue;
      }

      final recovery = await _syncStreamState(holder, playback);
      holder = recovery.holder;
      if (recovery.restartLoop) continue;

      if (await _waitForStartup(holder, playback)) continue;
      final frame = holder.consumeFrame();
      if (frame == null) {
        await _waitAfterNullFrame(holder, playback);
        continue;
      }

      emitImage(ImageInfo(image: frame.image, scale: holder.scale));
      playback.markFrameShown();
      await Future.delayed(WebPPlaybackTiming.frameDelay(frame, holder));
    }
    if (_activeHolder == holder) _activeHolder = null;
  }
}
