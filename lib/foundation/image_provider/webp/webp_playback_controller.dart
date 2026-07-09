part of '../webp_image_provider.dart';

class WebPPlaybackState {
  bool hasShownFirstFrame = false;
  int nullFrameWaits = 0;
  int resumeStartedAt = 0;

  void resetStartup() {
    hasShownFirstFrame = false;
    nullFrameWaits = 0;
  }

  void markResumeStarted() => resumeStartedAt = _nowMs();
  void markNullFrame() => nullFrameWaits++;
  void markFrameShown() {
    hasShownFirstFrame = true;
    nullFrameWaits = 0;
  }

  bool get resumeWaitElapsed => _nowMs() - resumeStartedAt > 1500;
}

class WebPPlaybackTiming {
  static const listenerPoll = Duration(milliseconds: 200);
  static const inactivePoll = Duration(milliseconds: 200);
  static const firstFramePoll = Duration(milliseconds: 200);

  static int startupWatermark(WebPPlaybackState state) =>
      state.hasShownFirstFrame ? 0 : DecoderHolder._firstFrameWatermark;

  static Duration emptyFrameWait(bool currentHolder) =>
      Duration(milliseconds: currentHolder ? 200 : 800);

  static Duration frameDelay(BufferedFrame frame, DecoderHolder holder) {
    final rawDelay = frame.durationMs <= 0 ? 100 : frame.durationMs;
    final delay = rawDelay.clamp(16, 200);
    return Duration(
      milliseconds: (delay * bufferPressureDelay(holder) / webpPlaybackSpeed)
          .round(),
    );
  }

  static double bufferPressureDelay(DecoderHolder holder) {
    if (holder.state != PageState.current) return 1.0;
    final remaining = holder.bufferLength;
    if (remaining <= 1) return 1.3;
    if (remaining <= 3) return 1.2;
    if (remaining <= 5) return 1.1;
    return 1.0;
  }
}
