# Native-owned WebP Streaming Refactor Plan

## Principle

All phases implement final interfaces. No temporary Dart ByteStore, second visible stream, holder owner, or compatibility replay layer will be added. Commits remain independently analyzable, but later phases replace implementations behind stable source/session/renderer boundaries rather than redesigning those boundaries.

## Phase 1 — Native authoritative source

- Add `WebPSourceContext` with epoch, expected/committed/final lengths, one outstanding reservation and native-owned storage.
- Add reserve/commit/reset/state/delete FFI APIs.
- Copy Dart chunks directly into reserved final storage once.
- Implement monotonic RIFF/VP8X/ANIM/ANMF indexing with offset-based frame descriptors.
- Add Dart `NativeWebPSource` wrapper with strict lifecycle and no retained Dart buffer.
- Keep existing decoder path operational until Phase 3, but do not adapt it through history replay.

Acceptance: native source unit-level probes validate contiguous append, stale epoch rejection, reset, final sealing and incremental frame discovery.

## Phase 2 — Stable session registries and scheduling lanes

- Add `DownloadSessionRegistry` keyed by download identity.
- Add `WebPDecodeSessionRegistry` keyed by fullKey.
- Model display/reader/decode demand as leases; detach only removes demand.
- Add session reconciler for run/pause/retain/evict.
- Split network permits from decode worker and upload capacity.
- Split download/decode/upload policy revisions.

Acceptance: current promotion never recreates a source; changing decode policy cannot invalidate a queued/running network operation.

## Phase 3 — Native playback cursor and holder reduction

- Add `WebPPlaybackCursor` referencing `WebPSourceContext`.
- Move target dimensions, frame/loop position, composite canvas and scratch decode state into cursor.
- Make partial restart reset cursor only.
- Refactor holder into bounded frame output/demand and remove direct decoder/source/download access.
- Route decode workers through cursor handles.

Acceptance: append and partial loop can run concurrently without resetting source; final frame count becomes authoritative without reload.

## Phase 4 — Pipeline and downloader migration

- Make DownloadSession the sole consumer of network chunks.
- Replace overloaded progress/chunk events with explicit transport progress and source append offset.
- Resume Range requests from native source committed length.
- Unify partial/final artifact lifecycle and atomically promote sealed data.
- Remove coordinator attach/detach/history replay and shared execution epoch.

Acceptance: attach at any download progress requires no replay and cannot produce a chunk gap.

## Phase 5 — Visible adapter migration and old-path removal

- `WebPImageProvider` acquires a display lease and subscribes to decode-session snapshots/frames.
- Remove visible bootstrap, visible download, resume stream, owner arbitration and stream result waiter maps.
- Make reader detach release logical leases only.
- Remove holder resync/reload logic that handled broken stream ownership.

Acceptance: rapid page switches, reader/gallery transitions and lifecycle pauses do not affect source continuity.

## Phase 6 — Renderer backend

- Introduce stable `FrameRenderer`/`NativeFrameHandle` contracts.
- Move current `decodeImageFromPixels` path behind `FlutterImageRenderer`.
- Implement Android `NativeTextureRenderer` without changing source or decode-session APIs.

Acceptance: renderer backend can switch without download, demux, cursor or policy changes.

## Validation after every phase

- Run focused `dart analyze` without formatting unrelated Flutter files.
- Rebuild native `.cxx` output after C ABI changes.
- Keep tracing session-level: source id/epoch/offset, transport transition, demand transition, cursor/frame counts and eviction reason.
- Reject invariants at their source; do not add retries or broad cleanup to hide failures.
