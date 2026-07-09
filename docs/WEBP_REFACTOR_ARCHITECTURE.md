# WebP Refactor Architecture

## Goal

Split the current WebP playback implementation into small, testable modules without changing behavior first. The reader workload is not video-like: users frequently switch between different WebP files, jump pages, drag the slider, return to slow pages, and resume partially downloaded files. Therefore the core runtime model remains **per-WebP session + holder-level FrameBuffer**, not a single global video-style FrameQueue.

## Non-goals for the first refactor

- Do not replace the existing pipeline with a fully native Texture renderer in the first phase.
- Do not introduce a global FrameQueue as the playback abstraction.
- Do not make GIF/APNG/AVIF generic abstractions before WebP behavior is stable.
- Do not run a large public/private API cleanup in the same step as file splitting.

## Current responsibilities that must be separated

`webp_image_provider.dart` currently mixes:

- Flutter `ImageProvider` entry point.
- `ImageStreamCompleter` animation loop.
- WebP decoder holder lifecycle.
- Streaming download attach/resume logic.
- Frame buffering and upload.
- Decode worker dispatch.
- Decoder manager and eviction.
- Static/animated WebP branching.
- Pipeline integration.

## Key architecture decision: FrameBuffer over FrameQueue

A video `FrameQueue` is optimized for one continuous stream. WebP reader playback is different:

- Multiple WebP files are active in a dynamic current/next/prev/far window.
- A page may become distant, keep downloading, then return to current.
- Animated WebP loops; frames may need replay instead of one-shot consumption.
- Partial data can produce several frames before the final bytes arrive.
- Current/near/far policies require different watermarks.

Target runtime:

```text
PipelineController
    ↓
ResourceEntry
    ↓
WebPDecodeSession / WebPStreamSession
    ↓
DecoderHolder per fullKey
    ↓
WebPFrameBuffer per holder
    ↓
WebPImageStreamCompleter consumes current holder
```

`FrameQueue` may still exist internally as a raw-frame queue between native decode and UI upload, but it is not the public playback model.

## Target module boundaries

Initial low-risk split keeps a single Dart library via `part/part of`:

```text
lib/foundation/image_provider/
  webp_image_provider.dart              # WebPImageProvider entry / part directives
  webp/
    webp_common.dart                    # shared helpers and BufferedFrame
    webp_frame_buffer.dart              # holder-owned frame/raw queues
    webp_decoder_holder.dart            # DecoderHolder lifecycle/state
    webp_decode_service.dart            # HolderDecodeService
    webp_decoder_manager.dart           # DecoderManager
    webp_provider_static.dart           # page policy/static helpers
    webp_provider_loader.dart           # bytes/static/animated branching
    webp_stream_session.dart            # visible streaming/resume
    webp_playback_controller.dart       # animation loop/reload/resume control
    webp_load_result.dart               # private load result DTOs
    webp_stream_completer.dart          # Flutter ImageStreamCompleter bridge
```

Pipeline/task scheduler is split by behavior and dependency boundary before moving directories:

```text
lib/foundation/image_provider/
  pipeline_models.dart              # Interaction/Page priority, ResourcePolicy, ResourceEntry, progress DTOs
  pipeline_resource_manager.dart    # ResourceManager and resource events
  pipeline_tasks.dart               # SchedulerTask, DownloadTask, PrecreateTask, task I/O execution
  task_scheduler.dart               # registry, migration, queue dispatch only
  pipeline_controller.dart          # window policy, rank, work submission orchestration
```

`TaskScheduler` must not depend on `WebPImageProvider`; WebP holder creation is injected into `PrecreateTask` through a holder factory. Later directory moves under `image_provider/pipeline/` should be done only after these behavior boundaries are stable.

## Renderer backend model

Native Texture rendering is a future backend, not the first refactor target:

```text
AnimatedFrameRenderer
    ├── FlutterImageRenderer        # current ui.Image / ImageStreamCompleter path
    └── NativeTextureRenderer       # future Android/iOS native texture path
```

The fully native renderer can bypass `decodeImageFromPixels`, `ImageInfo`, and `ImageStreamCompleter`, but it does not truly eliminate decoded pixel buffers: libwebp still produces pixels or a composited frame before GPU upload. It should be introduced after module boundaries are clean.

## Scheduler / pipeline decisions already made

- Running downloads are not cancelled merely because they leave the active window.
- Running out-of-window downloads receive a lower retained rank and can be preempted only under pressure.
- Rank includes page priority, direction, active download count, in-progress bonus, and nonlinear progress boost.
- Display progress should expose raw/cache/network state; it should not be cosmetically forced monotonic.

## Refactor phases

### Phase 1: no-behavior-change file split

- Add `part` files for common types, holder, decode service, manager, stream completer.
- Keep imports in `webp_image_provider.dart`.
- Keep all private names private within the same library.
- Validate with `dart analyze`.

### Phase 2: extract WebPFrameBuffer

Move buffer ownership out of `DecoderHolder`:

```text
BufferedFrame queue          # uploaded ui.Image frames
RawFrame queue               # native decoded frame addresses waiting upload
Watermark helpers
Dispose / clear / consume
Restart/replay helpers
```

### Phase 3: extract streaming session

Move progressive download and resume logic into `WebPStreamSession` / `WebPStreamLoader`:

- append chunk
- skip already appended bytes
- resume from partial cache
- publish raw progress
- mark stream active/closed/failed

### Phase 4: extract playback controller

Move timing and frame consumption out of `_WebPImageStreamCompleter`:

```text
WebPPlaybackController
    ↓
PlaybackClock
    ↓
FrameScheduler
```

### Phase 5: optional renderer backend

Introduce `FlutterImageRenderer` first, then experiment with Android-only `NativeTextureRenderer`.
