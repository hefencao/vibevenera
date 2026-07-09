# Image Pipeline Architecture

> Last updated: 2026-07-07

## 1. Goals

The image pipeline has two separate jobs:

1. Keep the visible page responsive.
2. Prepare nearby pages without stealing decode/upload time from the visible page.

UI interaction must not be blocked by resource policy timers. A 300ms UI debounce is acceptable for visual gestures, but it must not be the gate that decides when background decode resumes. Resource scheduling is driven by current-page buffer water level instead.

## 2. High-Level Architecture

```
Reader UI
  - reports page changes
  - creates ImageProviders
  - does not own decode policy
        |
        v
PipelineController
  - owns ResourceEntry map
  - computes dynamic preload window from current-page buffer level
  - maps relative page offsets to current / decode / downloadOnly / keep / evict
  - submits DownloadTask and PrecreateTask through TaskScheduler
        |
        +--> DecodedImageCache
        |     - L1: ui.Image
        |     - L2: original bytes
        |     - L3: optional RGBA
        |
        +--> DecoderManager
        |     - owns active DecoderHolder instances
        |     - applies holder page state and resource policy
        |
        v
TaskScheduler
  - priority queue
  - download/decode task dedup
  - task migration when the active window changes
        |
        +--> DownloadExecution
        |     - disk cache / network bytes
        |
        +--> PrecreateTask
              - creates WebP decoder holder when bytes are available

DecoderHolder
  - owns native animated WebP decoder
  - keeps frame buffer
  - reports current-page buffer level back to PipelineController
  - requests frame decode through WorkerPoolScheduler
        |
        v
WorkerPoolScheduler
  - isolate workers
  - current queue before next queue
  - generation check for stale decode jobs
  - ctx-hash affinity for native decoder safety
```

## 3. Design Decisions

### 3.1 UI and Resource Scheduling Are Decoupled

The reader UI should not wait for a 300ms "settling" timeout before it can drag a scrollbar or react to a page gesture. The UI layer reports page changes immediately. The resource layer independently decides how much background work is allowed.

The previous model coupled user interaction to resource state:

```
page change -> settling -> 300ms timer -> idle -> background work resumes
```

That made scrollbar dragging feel sticky and made fast page changes repeatedly churn the background queue.

The current model:

```
page change -> current page gets priority immediately
current buffer level changes -> dynamic window expands/shrinks
```

The 300ms concept, if used by UI code, is only a UI debounce. It must not be the authority for decode/upload scheduling.

### 3.2 Dynamic Window Is Table-Driven

Dynamic preload policy lives in `preload_policy.dart` and is split into two tables:

1. Water-level table: `currentBufferedFrames + preloadCount -> DynamicPreloadWindow`
2. Relative-page table: `offset + DynamicPreloadWindow -> PreloadPageClass`

This keeps the policy explainable and easy to tune. It also avoids growing chains of `if/else` in the pipeline controller.

Water-level table:

| Current buffered frames | Additional condition | Decode next | Decode prev | Download-only next+ |
|---:|---|---:|---:|---:|
| `< 3` | any | 0 | 0 | 0 |
| `>= 3` | any | 1 | 0 | 0 |
| `>= 5` | any | 2 | 1 | 0 |
| `>= 7` | `preloadCount < 7` | 3 | 2 | 1 |
| `>= 7` | `preloadCount >= 7` | 5 | 2 | 2 |

Relative-page table:

| Page class | Offset rule | Pipeline stage |
|---|---|---|
| `current` | `offset == 0` | download + decode + GPU upload |
| `decode` | `1 <= offset <= decodeNext` | download + decode + GPU upload if policy allows |
| `decode` | `-decodePrev <= offset <= -1` | download + decode + GPU upload if policy allows |
| `downloadOnly` | `decodeNext < offset <= decodeNext + downloadExtraNext` | download only |
| `keep` | `offset == -1` and not already decode | keep holder/bytes, do not refill frames |
| `evict` | otherwise | cancel/evict when allowed |

### 3.3 ResourcePolicy Is Also a Matrix

`ResourcePolicy.compute(interaction, priority)` is a matrix lookup:

```
InteractionState x PagePriority -> ResourcePolicy
```

This keeps interaction policy orthogonal to the dynamic window. The window decides which relative pages are current/near/far/keep; the policy matrix decides what each class may do.

### 3.4 Current Page Is the Only Hard Realtime Consumer

Background work is allowed only while current-page buffer health permits it. When the current page drops below the low water mark, non-current decode/upload should stop refilling. Download-only work may continue because it does not touch the native decoder or GPU upload path.

Current page priority exists at three levels:

- Task priority: current download/decode uses highest priority.
- Worker queue: current frame jobs go before next jobs.
- Dynamic window: low current buffer shrinks near/far work to zero.

### 3.5 Pre-download Means Bytes, Not Frames

Pre-download writes WebP bytes into L2 cache. It should not imply frame decode or GPU upload. This distinction matters because bytes are cheap and reusable; decoded/uploaded frames are expensive and can quickly saturate memory and the UI thread.

## 4. Decode Size and Pixel Alignment

Animated WebP frames are decoded at the target display size. This avoids decoding full-resolution frames that will only be downscaled later, but target size must be chosen carefully.

Example observation:

```
1079 x 806 = 869,674 pixels
48 ms / frame ~= 20.8 decoded frames per second
```

This is plausible on mobile when native WebP decode, scaling, isolate handoff, and `decodeImageFromPixels` upload are all included. It is not enough for a stable 24 fps animation if every frame must be decoded just-in-time.

The width `1079` is suspicious because it is not aligned to common GPU/CPU-friendly boundaries. It usually comes from:

```
logical viewport width * devicePixelRatio -> round()
```

For decode targets, prefer an aligned physical size:

- Use physical viewport size as the base.
- Preserve source aspect ratio.
- Round width/height to a small alignment boundary, for example even pixels or 8-pixel blocks.
- Clamp to the actual source size to avoid upscaling.
- Keep the same aligned target for cache keys, decoder holder keys, and L1/L2/L3 lookup.

The goal is not visual exactness at one physical pixel. The goal is stable cache keys, less scaler edge work, and fewer odd-sized uploads.

## 5. Main Data Flow

### Page Change

```
1. Reader calls WebPImageProvider.onPageChanged()
2. Decoder generation is incremented for stale frame safety.
3. Reader calls PipelineController.onPageRangeChanged()
4. PipelineController starts with currentBufferedFrames = 0.
5. DynamicPreloadPolicy selects the smallest window: current only.
6. Current page download/decode/upload starts first.
7. As current frames are uploaded, DecoderHolder reports buffer length.
8. PipelineController expands the window by table lookup.
9. TaskScheduler migrates queued/running tasks to match the new active keys.
```

### Current Buffer Drops

```
1. Animation consumes frames.
2. DecoderHolder reports the new buffer length.
3. PipelineController recomputes the dynamic window.
4. If the bucket changed, non-current decode keys leave the active decode set.
5. Running/queued background decode tasks are cancelled when possible.
6. Download-only tasks may remain if still in the active download window.
```

### Rapid Scroll or Drag

```
1. UI remains responsive; no resource timer blocks dragging.
2. New current page is applied immediately.
3. Background decode/upload is naturally suppressed because current buffer starts low.
4. Once current buffer recovers, the window expands.
```

## 6. Component Inventory

| Component | File | Responsibility |
|---|---|---|
| `DynamicPreloadPolicy` | [preload_policy.dart](../lib/foundation/image_provider/pipeline/preload_policy.dart) | Water-level and relative-page policy tables |
| `PipelineController` | [pipeline_controller.dart](../lib/foundation/image_provider/pipeline/pipeline_controller.dart) | Resource state, dynamic window application, task submission |
| `PipelineWindowPlanner` | [pipeline_window.dart](../lib/foundation/image_provider/pipeline/pipeline_window.dart) | Dynamic page window and relative offset calculation |
| `PipelinePolicyApplier` | [pipeline_policy_applier.dart](../lib/foundation/image_provider/pipeline/pipeline_policy_applier.dart) | Apply priorities and ResourcePolicy to entries |
| `ResourcePolicy` | [resource_entry.dart](../lib/foundation/image_provider/pipeline/resource_entry.dart) | Interaction x priority policy matrix |
| `ResourceEntry` | [resource_entry.dart](../lib/foundation/image_provider/pipeline/resource_entry.dart) | Single resource state: bytes, holder, policy, sub-states |
| `DownloadProgressPublisher` | [download_progress_publisher.dart](../lib/foundation/image_provider/pipeline/download_progress_publisher.dart) | Current page progress state and speed sampling |
| `DownloadRanker` | [download_ranker.dart](../lib/foundation/image_provider/pipeline/download_ranker.dart) | Download priority score: page, direction, progress, pressure |
| `PrefetchBudget` | [prefetch_budget.dart](../lib/foundation/image_provider/pipeline/prefetch_budget.dart) | Platform-aware far-page byte budget |
| `WebPStreamDecodeCoordinator` | [webp_stream_decode_coordinator.dart](../lib/foundation/image_provider/pipeline/webp_stream_decode_coordinator.dart) | Streaming WebP decode attach, append, detach |
| `TaskScheduler` | [task_scheduler.dart](../lib/foundation/image_provider/pipeline/task_scheduler.dart) | Priority queue, dedup, migration, cancellation |
| `DownloadTask` | [tasks.dart](../lib/foundation/image_provider/pipeline/tasks.dart) | Raw byte fetch |
| `PrecreateTask` | [tasks.dart](../lib/foundation/image_provider/pipeline/tasks.dart) | Decoder holder creation |
| `DecoderManager` | [webp_image_provider.dart](../lib/foundation/image_provider/webp_image_provider.dart) | Active holder lifecycle and holder page state |
| `DecoderHolder` | [webp_image_provider.dart](../lib/foundation/image_provider/webp_image_provider.dart) | Native decoder, frame buffer, buffer-level reporting |
| `WorkerPoolScheduler` | [webp_decoder.dart](../lib/utils/webp_decoder.dart) | Isolate frame decode with priority queues |
| `DecodedImageCache` | [decoded_image_cache.dart](../lib/foundation/image_provider/cache/decoded_image_cache.dart) | L1 decoded images, L2 bytes, L3 RGBA |

## 7. Why Not a Parameter Model Yet?

A learned or formula-based model could eventually replace the policy tables:

```
score(offset, buffer, decodeMs, uploadMs, velocity, memoryPressure) -> action
```

However, this requires telemetry and a clear objective function. Without that, a parameter model is harder to debug than a table and can oscillate under fast page changes.

The table-driven design is the right intermediate step:

- deterministic
- easy to inspect in logs
- easy to tune
- can be replaced by a model later behind the same `DynamicPreloadPolicy` API
