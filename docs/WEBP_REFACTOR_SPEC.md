# WebP Refactor Spec

## Scope

This spec defines the staged refactor of the WebP image provider and playback runtime. The first implementation step must preserve behavior and only split files using `part/part of`.

## Functional requirements

1. Current page priority must remain highest for download, decode, and playback.
2. Next/prev pages must continue to follow policy watermarks and predecode when allowed.
3. Leaving the active window must not immediately cancel a running download.
4. Running downloads outside the window may be preempted only when a higher-priority task needs a slot.
5. Download progress shown to the reader must use raw published progress, not holder-smoothed monotonic progress.
6. Partial streaming playback must continue to support replay/resume when bytes are incomplete.
7. Static WebP and animated WebP paths must both continue to work.
8. Local files and remote files must keep existing cache behavior.

## Non-functional requirements

- No behavior change in Phase 1.
- No `dart format` unless required by syntax breakage.
- Keep code compact.
- Avoid broad defensive rewrites.
- Prefer isolated, reviewable commits.
- `dart analyze` must pass after each phase.

## Phase 1 file split acceptance

`webp_image_provider.dart` should contain:

- imports
- `part` directives
- `WebPImageProvider` class for now

Current part files are organized by behavior directory:

```text
runtime/webp_common.dart
runtime/webp_frame_buffer.dart
decoder/webp_decoder_holder.dart
decoder/webp_decode_service.dart
decoder/webp_decoder_manager.dart
pipeline/webp_provider_static.dart
io/webp_provider_loader.dart
runtime/webp_stream_session.dart
runtime/webp_playback_controller.dart
io/webp_load_result.dart
runtime/webp_stream_completer.dart
```

Acceptance:

- No public API change.
- No import cycle.
- Private symbols remain accessible through one library.
- `dart analyze lib/foundation/image_provider/webp_image_provider.dart` passes.

## Phase 2 FrameBuffer extraction acceptance

Create `WebPFrameBuffer` and move these responsibilities out of `DecoderHolder`:

- uploaded frame queue
- raw native frame queue
- consume frame
- add decoded raw frames
- pump upload coordination hooks
- clear/dispose frames
- queued length / buffer length

`DecoderHolder` remains the owner of policy, decoder, stream state, and decode requests.

Acceptance:

- No change to playback watermarks.
- No frame leak: all `ui.Image` and native frame addresses are disposed/released.
- Current page first-frame wakeup still works.

## Phase 3 streaming session acceptance

Create `WebPStreamSession` or equivalent.

It must handle:

- streaming decoder creation/reuse
- append chunk
- duplicate chunk skipping using appended byte count
- final empty chunk append
- stream reset
- partial cache replay/resume
- progress publication

Acceptance:

- Current page can play before full download completes.
- Running download can continue after leaving active window.
- Re-entering a page can attach/resume without restarting when a shared download exists.

## Pipeline/task scheduler split acceptance

Split by behavior/dependency boundary, not by arbitrary line count:

```text
pipeline/resource_entry.dart
pipeline/resource_manager.dart
pipeline/tasks.dart
pipeline/task_scheduler.dart
pipeline/preload_policy.dart
pipeline/download_progress_publisher.dart
pipeline/webp_stream_decode_coordinator.dart
pipeline/pipeline_controller.dart
```

Acceptance:

- `task_scheduler.dart` contains only registry/migration/queue dispatch logic.
- Policy/resource data live outside task scheduler.
- Task execution wrappers live outside task scheduler.
- Current-page progress publication lives outside pipeline controller.
- WebP streaming decode attach/append/detach lives outside pipeline controller.
- `PrecreateTask` does not import or call `WebPImageProvider` directly; holder creation is injected.
- Direct users import data types from `pipeline/resource_entry.dart`.
- `dart analyze` passes.

## Phase 4 playback controller acceptance

Extract animation timing from `_WebPImageStreamCompleter`.

Acceptance:

- Loop count respected.
- WebP playback speed setting respected.
- Pause/resume/lifecycle wakeup preserved.
- Stale/far page WAIT loops do not consume unnecessary CPU.

## Future NativeTextureRenderer acceptance

Only after previous phases:

- Android prototype behind a feature flag.
- Flutter uses `Texture()` only for the native path.
- Native side owns decode, compose, upload, frame pacing.
- Existing Flutter renderer remains fallback.
- No regression for local files, remote streaming, or partial cache.

## Risk list

- Splitting into separate libraries too early would force private API public and increase bug risk.
- Global FrameQueue would fight dynamic page switching and replay requirements.
- Native Texture renderer increases platform lifecycle complexity and should not be mixed with file split refactor.
- Progress smoothing can hide cache/resume bugs and should not be reintroduced for UI display.
