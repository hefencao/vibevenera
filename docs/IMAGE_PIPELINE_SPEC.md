# Image Pipeline Specification

> **已过时**：这是早期资源管线规范。当前实现见
> [STREAMING_IMAGE_PIPELINE_ARCHITECTURE.md](STREAMING_IMAGE_PIPELINE_ARCHITECTURE.md)。

> Last updated: 2026-07-07

## 1. Terminology

| Term | Meaning |
|---|---|
| `current` | The page currently visible or being displayed by the active image provider. |
| `buffer level` | Number of uploaded frames available in the current page's `DecoderHolder`. |
| `decode window` | Relative pages allowed to create holders and decode/upload frames. |
| `download window` | Relative pages allowed to fetch/store raw WebP bytes only. |
| `next+` | Forward pages beyond the decode-next range; download-only. |
| `keep` | Page remains active enough to avoid immediate disposal, but must not refill frames. |

## 2. Dynamic Preload Policy

Dynamic preload policy is table-driven and lives in `preload_policy.dart`.

### 2.1 Water-Level Table

`DynamicPreloadPolicy.windowFor(currentBufferedFrames, preloadCount)` scans this table from top to bottom and returns the first matching row.

| Row | `currentBufferedFrames` | `preloadCount` | `decodeNext` | `decodePrev` | `downloadExtraNext` |
|---:|---:|---:|---:|---:|---:|
| 1 | `>= 7` | `>= 7` | 5 | 2 | 2 |
| 2 | `>= 7` | `>= 0` | 3 | 2 | 1 |
| 3 | `>= 5` | `>= 0` | 2 | 1 | 0 |
| 4 | `>= 3` | `>= 0` | 1 | 0 | 0 |
| 5 | `>= 0` | `>= 0` | 0 | 0 | 0 |

This means `c >= 7` has two modes:

- if the configured preload depth is high enough, use `next 5, next+ 2, prev 2`
- otherwise use `next 3, next+ 1, prev 2`

### 2.2 Relative Page Table

`DynamicPreloadPolicy.pageClassFor(offset, window)` maps a page offset to a class.

| Order | Page class | Rule |
|---:|---|---|
| 1 | `current` | `offset == 0` |
| 2 | `decode` | `1 <= offset <= decodeNext` |
| 3 | `decode` | `-decodePrev <= offset <= -1` |
| 4 | `downloadOnly` | `decodeNext < offset <= decodeNext + downloadExtraNext` |
| 5 | `keep` | `offset == -1` and not already matched by decode |
| 6 | `evict` | all other offsets |

The order is important. `offset == -1` becomes `decode` when `decodePrev >= 1`; otherwise it falls through to `keep`.

### 2.3 Actions By Page Class

| Page class | Download bytes | Create holder | Decode frames | GPU upload | Retain holder |
|---|---|---|---|---|---|
| `current` | yes | yes | yes | yes | yes |
| `decode` | yes | yes | yes | policy-dependent | yes |
| `downloadOnly` | yes | no | no | no | no |
| `keep` | no new work | no new work | no refill | no refill | yes if already present |
| `evict` | no | no | no | no | no |

## 3. ResourcePolicy Matrix

`ResourcePolicy.compute(interaction, priority)` is a two-dimensional matrix. It does not know page offsets. Page offsets are first mapped to `PagePriority` by `PipelineController`.

| Interaction | Priority | allowDownload | allowDecode | allowGpuUpload | downloadPriority | decodePriority |
|---|---|---|---|---|---:|---:|
| idle | current | yes | yes | yes | 100 | 100 |
| idle | near | yes | yes | yes | 50 | 50 |
| idle | far | yes | no | no | 20 | 0 |
| idle | distant | no | no | no | 0 | 0 |
| dragging | current | yes | yes | yes | 100 | 100 |
| dragging | near | yes | no | no | 30 | 0 |
| dragging | far | yes | no | no | 10 | 0 |
| dragging | distant | no | no | no | 0 | 0 |
| settling | current | yes | yes | yes | 100 | 100 |
| settling | near | yes | yes | no | 40 | 40 |
| settling | far | yes | no | no | 15 | 0 |
| settling | distant | no | no | no | 0 | 0 |
| jumping | current | yes | yes | yes | 100 | 100 |
| jumping | near | no | no | no | 0 | 0 |
| jumping | far | no | no | no | 0 | 0 |
| jumping | distant | no | no | no | 0 | 0 |

## 4. UI Interaction Rules

UI interaction must be decoupled from resource scheduling.

### 4.1 Required Behavior

- Page changes must apply the new current page immediately.
- Scrollbar drag and gesture handling must not wait for a 300ms resource state transition.
- Background decode/upload must be controlled by current buffer level, not by UI timers.
- A UI debounce may exist for visual state, but it must not block resource migration.

### 4.2 InteractionState Guidance

`InteractionState` remains useful as a policy input, but it is not the primary throttle.

| State | Usage |
|---|---|
| `idle` | Normal matrix row. Dynamic window decides how many pages are active. |
| `dragging` | Prefer no background decode. Current page decode stays enabled. |
| `settling` | Transitional row only; must not require a fixed 300ms before current work starts. |
| `jumping` | Current only; all unrelated work can be evicted/cancelled. |

## 5. Decode Target Size

### 5.1 Observed Cost

For a target of `1079 x 806`:

```
pixels = 1079 * 806 = 869,674
48 ms/frame ~= 20.8 frames/sec
```

This is plausible for animated WebP when the measured time includes native decode, scaling, isolate round trip, and GPU upload. It is borderline for smooth playback because a 24 fps animation has only about `41.7ms` per frame.

### 5.2 Size Alignment Requirements

Target sizes should avoid odd and unstable dimensions such as `1079` when possible.

Recommended target-size rules:

1. Start from physical viewport size, not logical size.
2. Preserve image aspect ratio.
3. Clamp to source dimensions to avoid unnecessary upscaling.
4. Align target width/height to a small boundary, preferably 2 or 8 pixels.
5. Use the aligned target size in cache keys and decoder holder keys.

Rationale:

- More stable cache keys across tiny viewport changes.
- Fewer odd-width rows in native scaler/upload paths.
- Lower chance of decoding at a size that does not match the real device-backed display area.

## 6. Task Lifecycle

### 6.1 DownloadTask

Purpose: fetch original bytes.

Rules:

- Keyed by bare `imageKey`.
- Can run for `current`, `decode`, and `downloadOnly` pages.
- Writes successful WebP bytes into L2 cache.
- Uses `CancelToken` when network work is cancelled.

### 6.2 PrecreateTask

Purpose: create a `DecoderHolder` when bytes already exist.

Rules:

- Keyed by `fullKey` (`imageKey@WxH`).
- Runs only when policy allows decode.
- Uses provided bytes or L2 bytes.
- Must not trigger network fetch by itself.

### 6.3 Task Migration

When the dynamic window changes:

- Active download keys are retained.
- Active decode keys are retained only if policy still allows decode.
- Queued stale tasks are cancelled.
- Running stale tasks are cancelled when cancelable.
- Priorities are updated for keys that remain active.

## 7. Frame Decode Pipeline

### 7.1 Current Page

The current page is allowed to refill up to its high watermark. The animation loop may wait for a startup watermark before playback starts. If decode cannot keep up, playback may be temporarily slowed within a bounded range.

### 7.2 Background Pages

Background pages may decode only while current buffer level allows it. They must not continue refilling frames after they leave the dynamic decode window.

### 7.3 WorkerPoolScheduler

Rules:

- `DecodePriority.current` is processed before `DecodePriority.next`.
- Stale generation jobs are rejected before queue insertion.
- Each native decoder is protected by ctx-hash affinity and `_activeDecoders`.

## 8. Performance Notes

### 8.1 48ms at 1079x806

Treat this as a warning threshold:

- acceptable if it is a rare frame or includes upload
- too slow if it is the steady-state per-frame decode cost for a 24fps animation
- definitely too slow if background jobs are running at the same time and current buffer is draining

Mitigations:

- Align target size.
- Lower target size when source is larger than display needs.
- Increase startup buffer modestly.
- Stop background decode/upload below the low water mark.
- Keep next+ as download-only.

### 8.2 Memory Pressure

Decoded frames are expensive:

```
width * height * 4 bytes
1079 * 806 * 4 ~= 3.3 MB per frame
10 frames ~= 33 MB for one current holder
```

This is why `next 5 + prev 2` must be conditional on current buffer health. It must not mean "decode and upload every nearby page at once".

## 9. Future Parameter Model

A future model can replace table lookup:

```
action = f(offset, currentBuffer, decodeMs, uploadMs, scrollVelocity, memoryPressure)
```

Possible action outputs:

- evict
- keep
- downloadOnly
- decode
- current

Do not introduce this until telemetry exists. Minimum telemetry:

- per-frame decode ms
- upload ms
- current buffer length over time
- dropped/stalled frame count
- page-change velocity
- number of active holders
- estimated decoded-frame memory

Until then, the two-table policy is preferred because it is deterministic, inspectable, and easy to tune.
