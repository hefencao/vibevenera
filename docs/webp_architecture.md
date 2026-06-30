# WebP Animation Architecture & Optimization Plan

## Current Architecture

### Layer Diagram

```
┌─ Dart UI ─────────────────────────────────────────────────────────┐
│  ComicImage (widget) ──► _resolveImage() ──► ImageStream          │
│  _createImageProviderFromKey() ──► WebPImageProvider               │
│  _precacheImage() ──► Flutter precacheImage() ← PERMANENT LISTENER│
└───────────────────────────────────────────────────────────────────┘
         │ resolve                  │ loadImage
         ▼                          ▼
┌─ Dart Completer ──────────────────────────────────────────────────┐
│  _WebPImageStreamCompleter                                        │
│  _startAnimation() → fetchNext() → playNext() → setImage()        │
│  _maxPlaying=6 cap → pause/resume with hasListeners polling       │
└───────────────────────────────────────────────────────────────────┘
         │ FFI                     │ FFI
         ▼                         ▼
┌─ Dart FFI Bindings ───────────────────────────────────────────────┐
│  WebPAnimDecoder                                                  │
│  getNextFrameAsync() → Isolate.run → C animGetFrame               │
│  getNextFrame() → sync FFI → C animGetFrame (main thread)         │
└───────────────────────────────────────────────────────────────────┘
         │ Isolate / Main thread
         ▼
┌─ C Native ────────────────────────────────────────────────────────┐
│  webp_anim_decoder_get_frame() → MODE_RGBA → straight_to_premul  │
│  composite_region() → copy_premul_to_straight → output_buf[8]     │
│  Per context: composite_canvas + 8×output_buf + frame_buf + demux │
└───────────────────────────────────────────────────────────────────┘
```

### Memory Per Decoder (1080×1920 target)

| Component | Size |
|-----------|------|
| composite_canvas | targetW × targetH × 4 = 8MB |
| output_buf × 8 | 8 × targetW × targetH × 4 = 64MB |
| frame_buf (max) | ~8MB |
| Native raw data | file size (variable) |
| **Total C heap** | **~80MB+** |
| Dart frame cache | ≤20 frames × 8MB = 160MB (rare) |

### Known Root Causes

1. **precacheImage permanent listener** → Completer never disposed → Decoder never freed
2. **PageView keeps old pages alive** → Widgets not removed → Listeners stay → Completers accumulate
3. **Dart WebPAnimDecoder lifecycle tied to Completer lifecycle** → If completer leaks, decoder leaks
4. **Pause/Resume jank** → 1-second polling timer for hasListeners → visible stutter on resume
5. **Global cap causes premature pause** → Visible animations paused when cap exceeded

---

## Optimization Plan

### Principles
- **尊重性能**: No main-thread blocking. Isolate for C calls. Pipeline GPU uploads.
- **重视浏览体验**: No loading spinners. No frame resets on revisit. Smooth transitions.

### Phase 1: Remove Problematic Mechanisms

**Remove pause/resume entirely.**
- `_doPause`, `_doStop`, `resumeTimer`, `isPaused`, `hasListeners` polling — all gone.
- When page scrolls away → completer disposed → decoder freed.
- When page scrolls back → new decoder created → animation starts cleanly.

**Remove global playing cap.**
- `_maxPlaying`, `_playing`, `_markPlaying`, `_markStopped` — all gone.
- Let Flutter's `ImageCache` handle eviction naturally.
- Decoder creation is fast (10ms) — acceptable for revisit.

**Reason**: pause/resume was a workaround for precacheImage's permanent listener. Fix the root cause instead (Phase 2).

### Phase 2: Precache with GPU Upload — Frame-Level Precaching

**Strategy**: Pre-decode + pre-upload frames to GPU during precaching, so display is truly instant.

```
_precacheImage (async, non-blocking)
  │
  ├─ 前一张 (prev): 前4帧 → decode(Isolate) → upload(GPU)
  ├─ 后一张 (next): 前5帧 → decode(Isolate) → upload(GPU)
  └─ 后二张 (next+1):前4帧 → decode(Isolate) → upload(GPU)

Page becomes visible → _decodeAnimated()
  └─► takePrecached() → PrecacheEntry:
        ├─ decoder (C iterator advanced past pre-decoded frames)
        ├─ List<ImageInfo> (already on GPU)
        └─ List<int> durations

_startAnimation(decoder, preUploaded: [...], durations: [...])
  ├─ Frame 0..N-1: setImage(preUploaded[i]) → INSTANT (already on GPU)
  └─ Frame N+: fetchNext() → Isolate → upload → setImage (normal pipeline)
```

**PrecacheEntry** (stored in static pool):
```dart
class _PrecacheEntry {
  final webp.WebPAnimDecoder decoder;   // C state at position N
  final List<ImageInfo> gpuFrames;     // pre-uploaded ui.Image on GPU
  final List<int> durations;           // ms per frame
}
```

**Pool design:**
- `static Map<String, _PrecacheEntry> _precachePool` — keyed by `imageKey@WxH`
- `static List<String> _poolOrder` — FIFO eviction
- `_maxPoolSize = 5` — covers 3 pages × entries + margin
- `_poolCreating` set — prevents concurrent creation
- All precache work runs async (via `async`/`await`, Isolate for C calls)
- GPU upload via `decodeImageFromPixels` (async callback)
- Eviction: dispose all `gpuFrames[i].image.dispose()` + `decoder.dispose()`

**Frame count per page:**
| Page | Frames | Rationale |
|------|--------|-----------|
| Prev | 4 | User may swipe back; enough to cover transition |
| Next | 5 | Most likely next; 1 extra for animation lead-in |
| Next+1 | 4 | Less likely; covers swipe-through |

**Why this eliminates loading animation:**
- Frame 0 is already on GPU → `setImage()` is synchronous → NO loading spinner
- Frames 1..N are also on GPU → instant display, no decode/upload delay
- Pipeline seamlessly transitions from pre-uploaded to live-decode at frame N

### Phase 3: Keep Proven Fixes

**Keep these fixes** (they address real bugs):
1. **MODE_RGBA + straight_to_premul** (color artifact fix)
2. **Frame iterator advance ordering** (state consistency fix)
3. **Floor-based scaling** (seamless tile fix)
4. **DPR + scale=1/dpr** (physical resolution fix)
5. **Output ring buffer** (tearing prevention, keep at 4-8)
6. **fetchNext before decodeImageFromPixels** (pipeline optimization)
7. **pendingDispose guard** (use-after-free prevention)

### Phase 4: Clean Up Dead Code (DONE)

**Removed:**
- `_ImageResult.isolateFrames` factory + `_playPredecoded` method
- `_ImageResult.codec` field + `_playFromCodec` method
- `_ResultType.predecoded` enum value
- `_AnimFrame` class
- `_MarkPlaying`/`_markStopped`/`_doPause`/`_doStop`
- `_maxPlaying=6` cap + `_playing` list
- Pause/resume timer + `hasListeners` polling
- `isPaused`/`resumeTimer`/`doResume`/`firstFrameDisplayed`/`noListenerCount`

**Kept (proven fixes):**
- MODE_RGBA + straight_to_premul
- State ordering (total_frames_decoded before decode)
- DPR + scale=1/dpr
- fetchNext before decodeImageFromPixels (pipeline)
- pendingDispose guard
- Output ring buffer (8)

**Simplified `_startAnimation`:**
```dart
void _startAnimation(WebPAnimDecoder decoder) {
  var isActive = true;
  WebPAnimFrameAddress? pendingFrame;
  bool fetching = false;
  bool pendingDispose = false;

  Future<void> fetchNext() async { /* getNextFrameAsync */ }
  Future<void> playNext() async { /* pipeline + setImage */ }

  fetchNext().then((_) => playNext());
}
```

## Methodology: Analyze Root Cause, Don't Mask with Defensive Code

**Anti-pattern**: When a symptom appears (crash, pause), add a timeout/retry/null-check without identifying WHY the symptom occurs. This buries the root cause under defensive layers, and the original bug persists.

**Example from this project**:
- Symptom: "first frame pause + crash on re-entry"
- Wrong fix: Added 5s Isolate timeout, removed loadingBuilder, enabled gaplessPlayback
- Root cause: `onDisposed` → `_disposeDecoder()` → `doDispose()` → `decoder.dispose()` WITHOUT checking `fetching`. When Isolate was still running (first frame hadn't completed), `decoder.dispose()` freed C memory, causing use-after-free.
- Correct fix: `_disposeDecoder = stopAnimation` (which checks `fetching` before disposing)

**Methodology rule**: When two symptoms co-occur (first-frame pause AND crash), they share a root cause. Trace the execution path from symptom to crash — don't treat them as independent bugs.

## ⚠️ CRITICAL RULE: Never dispose decoder while Isolate may access it

**Problem**: `decoder.dispose()` → `webp_anim_decoder_delete()` frees C heap memory (`composite_canvas`, `output_buf[]`, `demux`). If a background Isolate is concurrently running `animGetFrame` on the same C context, this is a **use-after-free** → native crash (SIGSEGV).

**The rule**:
- `_disposed = true` is SAFE to set from anywhere (Dart bool, no C access)
- `decoder.dispose()` MUST only be called when `fetching == false` (no Isolate running)
- The `pendingDispose` pattern handles this within a single completer
- For cross-completer eviction (global cap): ONLY set `_disposed = true`, NEVER call dispose directly
- The animation loop checks `_disposed` at each checkpoint; when true, it calls `doDispose()` which checks `fetching` before disposing

**Where this was violated** (causing crashes):
- Global cap calling `old._disposeDecoder?.call()` → directly disposed decoder during Isolate
- Pause/resume calling `releaseDecoder()` from outside the animation loop
- `_disposeAnimation()` calling `_releaseDecoderCallback?.call()` during eviction

**Correct pattern for cross-completer eviction**:
```dart
// SAFE: just mark disposed, loop handles cleanup
old._disposed = true;

// UNSAFE: may dispose during Isolate
old._disposeDecoder?.call(); // NEVER DO THIS
```

### Expected Outcome

| Issue | Before | After |
|-------|--------|-------|
| Memory per 10 pages | 20 decoders × 80MB | ≤3 pool decoders + 1 active |
| First frame delay | varies (depends on precache) | pool hit: ~50ms; miss: ~60ms |
| Loading animation on switch | Present (if _preDownloadImage) | None (pool decoder ready) |
| Revisit page | Pause/resume jank (1s) | New decoder from pool ~50ms |
| Crash on fast scroll | Use-after-free | pendingDispose guard |
| Image quality | 427×318 logical | 1080×806 physical (DPR fix) |
| Code complexity | pause/resume/cap/timers | Simple start/stop + pool |
