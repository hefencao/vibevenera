# WebP Animation Architecture & Evolution

> **已过时**：本文是早期 WebP 架构演进记录。当前实现见
> [STREAMING_IMAGE_PIPELINE_ARCHITECTURE.md](STREAMING_IMAGE_PIPELINE_ARCHITECTURE.md)。

## 1. Architecture Overview & Evolution

### Layer Diagram

```
┌─ Dart UI (Widget Layer) ──────────────────────────────────────────┐
│  ComicImage (widget) ──► ImageStream (Listener)                   │
│  State: CURRENT | NEXT | LAST | PRECACHE                          │
│  FrameBuffer: Window-based refill (High: 7 / Low: 3)              │
└───────────────────────────────────────────────────────────────────┘
         │ Request Frames / Update State
         ▼
┌─ Dart Manager (DecoderManager) ───────────────────────────────────┐
│  - Generation-based task discarding                               │
│  - TTL-based deferred eviction (2s)                               │
│  - 3-tier Priority Queue (CURRENT > NEXT > BACKGROUND)            │
└───────────────────────────────────────────────────────────────────┘
         │ Dispatch Job (with Generation)
         ▼
┌─ Dart FFI & Worker Pool (Isolate.run) ────────────────────────────┐
│  - Multi-threaded decoding for CURRENT (Thread Limit: 2-3)        │
│  - Single-threaded decoding for others (Thread Limit: 1)          │
│  - Async GPU Upload (decodeImageFromPixels)                       │
└───────────────────────────────────────────────────────────────────┘
         │ FFI calls
         ▼
┌─ C Native (libwebp) ──────────────────────────────────────────────┐
│  - webp_anim_decoder_get_frame() (MODE_RGBA -> straight_to_premul) │
│  - Dynamic thread limit adjustment                                │
│  - Shared context: demux + canvas + ring output buffers           │
└───────────────────────────────────────────────────────────────────┘
```

### Memory Per Decoder (1080×1920 target)

| Component | Size |
|-----------|------|
| composite_canvas | targetW × targetH × 4 = 8MB |
| output_buf × 8 | 8 × targetW × targetH × 4 = 64MB |
| Native raw data | file size (variable) |
| **Total C heap** | **~80MB+** |
| Dart FrameBuffer | 3~7 frames × 8MB = 24MB ~ 56MB |

### Known Root Causes (Historical Context)

1.  **precacheImage permanent listener**: Flutter's `precacheImage` kept listeners alive, preventing `Completer` disposal and leaking decoders.
2.  **PageView keep-alive**: Widgets on adjacent pages stayed alive, keeping listeners and decoders active.
3.  **Use-after-free**: Disposing a C decoder while a background Isolate was still accessing it during a decode call.
4.  **Pause/Resume jank**: 1-second polling timer for `hasListeners` caused visible stutter and unnecessary CPU wakeups.
5.  **Global cap issues**: `_maxPlaying` cap caused unpredictable pauses when multiple animations were active.

---

## 2. High Efficiency Rendering Engine Spec

### 2.1 Window-Based Refill
Instead of "one frame consumed, one frame decoded", we use batch processing to improve CPU core residency and allow deeper sleep states.
- **HIGH_WATERMARK (7)**: Upper limit for the FrameBuffer.
- **LOW_WATERMARK (3)**: Trigger threshold. When the buffer drops to this level, a refill is requested.
- **BATCH_SIZE (4)**: Number of frames decoded in a single batch (High - Low).

### 2.2 Page State Machine
Decoders transition through states based on visibility and proximity in the PageView.
- **CURRENT**: Actively playing. CONTINUOUS refill enabled. Multi-threaded decoding (2-3 threads) for <15ms frame delivery.
- **NEXT**: Pre-decoding. One-time refill to 5 frames. Single-threaded (1 thread) to save CPU.
- **LAST**: Previous page. Refill disabled. Frames kept in memory for instant return.
- **PRECACHE**: Distant pages. One-time refill to 5 frames in the background queue.

### 2.3 Generational Task Discarding
To handle rapid scrolling, a global `generation` counter is incremented on every state change.
- All `DecodeJob`s carry a `generation`.
- Workers check `job.generation == currentGeneration` before and during batch decoding.
- Stale jobs are aborted immediately with zero additional compute cost.

### 2.4 Deferred TTL Eviction
Prevents thrashing (release/re-create) when users swipe back and forth.
- `lastAccessTime` is updated on every frame consumption.
- A 1s heartbeat timer checks for `now - lastAccessTime > 2s`.
- If expired and state is `LAST` or `PRECACHE`, resources are physically released.

---

## 3. C-Layer Interface Configuration

`webp_decoder.h` must support dynamic thread limits:

```c
/**
 * Adjust internal libwebp thread count.
 * @param use_threads: 0-1 for single thread, 2-3 for multi-threaded.
 */
void webp_anim_decoder_set_thread_limit(WebPAnimContext* ctx, int use_threads);
```

Internal implementation maps this to `WebPDecoderConfig.options.use_threads`.

---

## 4. Dart Architecture Blueprint (Worker Pool)

The system uses a 3-tier priority queue and `Isolate.run` to ensure smooth UI and high efficiency.

```dart
class WorkerPoolScheduler {
  // ... (Queues for CURRENT, NEXT, BACKGROUND)

  Future<void> _executeJob(DecodeJob job) async {
    // CRITICAL: Heavy decoding must happen in a separate Isolate to avoid blocking main thread.
    final List<ui.Image> batchFrames = await Isolate.run(() async {
        return _decodeInIsolate(job);
    });
    
    if (job.generation == _currentGeneration) {
      job.onComplete(batchFrames);
    } else {
      for (final img in batchFrames) img.dispose();
    }
  }
}
```

---

## 5. Methodology & Critical Rules

### Methodology: Analyze Root Cause, Don't Mask with Defensive Code

**No Defensive Programming**: Do not add timeouts, retries, or null-checks to hide crashes. Trace the source.
- **Example**: If a file read returns 0 bytes, find the race condition instead of adding a retry.

### ⚠️ CRITICAL RULE: Never dispose decoder while Isolate may access it

**Use-after-free** occurs if `webp_anim_decoder_delete()` is called while a background Isolate is running `animGetFrame` on the same context.

- **The Rule**: `decoder.dispose()` MUST only be called when the worker pool is NOT processing a job for that specific decoder.
- **Implementation**: The `DecoderHolder` manages its own disposal via the manager's heartbeat, ensuring no active `_isFetching` flag is set.
- **Generational Guard**: While the `generation` check aborts *new* work, already running native C calls cannot be interrupted. We must wait for the current native call to return before calling `dispose()`.

---

## 6. Expected Outcome

| Issue | Previous (Optimization Plan v1) | New High Efficiency Engine |
|-------|--------------------------------|----------------------------|
| CPU Wakeups | High (per-frame) | Low (batch refill) |
| Memory Usage | High (cap-based) | Controlled (TTL + State) |
| Rapid Scroll | Task buildup / Heat | Instant discard (Generational) |
| Latency | ~30ms (Single-thread) | <15ms (Multi-thread CURRENT) |
| Stability | use-after-free risk | Fetching-guarded disposal |
| Complexity | Polling/Timers/Caps | State-machine / Generation |
