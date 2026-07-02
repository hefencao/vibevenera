# Refactor WebP High Efficiency Rendering Engine

Implement the new WebP rendering architecture focused on efficiency, stability, and reduced CPU/memory usage.

## User Review Required

- **Breaking Changes**: The existing `onPageChanged` and `precache` logic in `WebPImageProvider` will be entirely replaced by the `DecoderManager` state-machine approach.
- **Concurrent Decoding**: The `WorkerPoolScheduler` will manage background Isolates for decoding to ensure the main thread is never blocked.

## Proposed Changes

### [C Native Layer]

#### [webp_decoder.h](file:///android/app/src/main/cpp/webp_decoder.h)
- Add `webp_anim_decoder_set_thread_limit` API.

#### [webp_decoder.c](file:///android/app/src/main/cpp/webp_decoder.c)
- Implement `webp_anim_decoder_set_thread_limit`.
- Update `WebPAnimContext` to store the thread limit.
- Apply the thread limit to `WebPDecoderConfig` inside `webp_anim_decoder_get_frame` or similar decoding points.

---

### [Dart Utility Layer]

#### [webp_decoder.dart](file:///lib/utils/webp_decoder.dart)
- Add FFI binding for `webp_anim_decoder_set_thread_limit`.
- Implement `WorkerPoolScheduler` (Singleton):
    - 3-tier priority queue (CURRENT, NEXT, BACKGROUND).
    - Generational task discarding.
    - Uses `Isolate.run` for heavy decoding.
- Refactor `WebPAnimDecoder`:
    - Integrate with `WorkerPoolScheduler`.
    - Support thread limit adjustment.

---

### [Dart Image Provider Layer]

#### [webp_image_provider.dart](file:///lib/foundation/image_provider/webp_image_provider.dart)
- Implement `DecoderHolder`:
    - Manages `FrameBuffer` (3-7 frames).
    - Implements Window-Based Refill logic.
    - Tracks `lastAccessTime` for TTL eviction.
- Implement `DecoderManager` (Singleton):
    - Manages all active `DecoderHolder`s.
    - Implements Page State Machine (`activePagesChanged`).
    - Implements 1s heartbeat for TTL eviction (now - lastAccessTime > 2s).
- Refactor `WebPImageProvider`:
    - Delegate decoding and lifecycle management to `DecoderManager`.
    - Update `load` method to use `DecoderHolder`.
    - Clean up old `_precachePool` and `_maxPlaying` logic.

## Verification Plan

### Automated Tests
- No existing unit tests for FFI found. I will rely on logging and manual verification.

### Manual Verification
1.  **Logging Verification**: Add extensive logging to track:
    - Generation increments and job discarding.
    - State transitions (CURRENT, NEXT, etc.).
    - Batch refills (HIGH/LOW watermarks).
    - TTL-based evictions.
2.  **Performance Check**: Use Flutter Performance Overlay and `adb shell top` to monitor CPU and frame stability during rapid scrolling.
3.  **Memory Check**: Monitor `WebPAnimDecoder.alive_count` to ensure no leaks and that the TTL eviction works.
