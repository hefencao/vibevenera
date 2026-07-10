# WebP Streaming Refactor Spec

## Required behavior

1. Current page has highest network, decode, upload and playback priority.
2. Current and near pages can play before download completion.
3. Partial available frames can loop while additional bytes continue appending.
4. Far pages retain existing download-window behavior; entry-count and frame watermarks remain unchanged.
5. A network pause/preemption preserves committed bytes, source epoch, partial data and decode session state.
6. Re-entering reader/gallery or revisiting a page reuses the same retained session when its identity and epoch are valid.
7. Source switching invalidates old writes atomically and starts a new epoch.
8. Final completion seals exactly the committed byte range and cannot repair a discontinuous source by reloading into an existing decoder.
9. Static WebP, animated WebP, local files and non-WebP fallback continue to work.
10. `detachReaderSession` and visible detach do not call global WebP clearing.

## State and identity

### Download identity

```text
(imageKey, sourceKey, cid, eid)
```

This identity maps to exactly one active or retained `DownloadSession` and `NativeWebPSource`.

### Decode identity

```text
fullKey = imageKey@targetWidthxtargetHeight
```

This identity maps to at most one live `WebPDecodeSession` and playback cursor.

### Source state

```text
idle -> receiving <-> paused -> sealed
                         └----> failed
reset creates a new epoch and returns to idle/receiving
```

`committedLength` is monotonic within an epoch. `finalLength == committedLength` when sealed.

### Logical detach

- Detach removes a lease/demand only.
- Detach contains no direct `cancel`, `dispose`, `dropHolder`, `clear`, `delete`, `resetInput` or cache mutation.
- A reconciler performs physical actions after evaluating all remaining demand, task rank, retention and memory policy.

## Native source contract

1. `reserve(epoch, offset, length)` succeeds only for the current epoch and `offset == committedLength`.
2. At most one reservation may be outstanding per source.
3. The reservation points to final native-owned input storage and is valid only until matching `commit` or reset/delete.
4. `commit` advances length only for the exact outstanding reservation.
5. `seal(epoch)` validates RIFF declared length against committed length and seals the source.
6. Frame descriptors use source-relative offsets, not pointers.
7. Append, index publication and cursor reads are synchronized without retaining Dart memory.
8. Invalid epoch, overlap, gap or final length is a source failure, not a retry condition inside holder/playback.

## Incremental index contract

- Parsing starts at the previous `parsedOffset`; already indexed chunks are not rescanned.
- Incomplete RIFF chunks do not advance past their header.
- A frame becomes available only after its complete ANMF payload is committed.
- Frame count is monotonic during partial input and authoritative after seal.
- Parser errors include source epoch and byte offset.

## Session contract

### DownloadSession

- Owns transport and source writes.
- Publishes transport states separately from byte availability.
- Range resume begins at source `committedLength`.
- Transport cancellation caused by scheduler pressure becomes `paused`, not failed.
- Partial/final persistence is managed through one artifact lifecycle and promoted atomically.
- Plain streaming responses publish ordered chunks plus an explicit completion length; they do not retain legacy Dart history/partial storage or assemble final bytes.
- Full-body output remains permitted only when response transformation requires it.

### WebPDecodeSession

- Owns native playback cursor and frame production.
- Does not own network transport.
- Receives source/index availability through ordered native/source notification.
- Page policy changes update demand without skipping source bytes or resetting cursor.
- Visible attachment does not change source or transport state.
- A display lease exists only while the completer has listeners; ImageCache residency alone creates no decode/upload demand.

### FrameHolder

- Owns only bounded raw/uploaded frame queues, frame waiters and demand snapshot.
- Does not expose native source/decoder, download offsets, partial state or stream owner.
- Disposing a rendered frame releases exactly one native/UI resource lease.

## Scheduling contract

- Network, decode and upload use independent capacity controls.
- Download ranking and preemption only operate on transport permits.
- Decode priority only operates on decode jobs.
- Upload demand only controls raw-frame consumption and renderer submission.
- No shared policy epoch may invalidate tasks from another stage.

## Performance requirements

- One Dart/network chunk copy into final native input storage; no temporary native append copy.
- No full history replay when a page becomes current.
- No complete `Uint8List` assembly solely to finalize an already complete native source.
- No Dart chunk concatenation or second partial artifact in the plain Session transport path.
- No repeated full-buffer demux scan for each append threshold.
- No decode/precreate task may occupy a network concurrency permit.
- No per-frame state log in production tracing.
- Frame watermarks remain entry-based rather than byte-budget based.

## Compatibility interfaces

- `WebPImageProvider` remains the Flutter adapter during migration.
- Source, decode session and renderer interfaces are final boundaries and cannot depend on `ui.Image` or current coordinator implementation.
- `FlutterImageRenderer` and future `NativeTextureRenderer` implement the same renderer contract.

## Acceptance tests

1. Slow download: first available frame plays and partial loop continues until new frames arrive.
2. Page current -> near/far -> current while downloading: no source recreation, gap, holder drop or network restart.
3. Download preemption: session pauses, resumes from exact committed offset and preserves partial playback.
4. Attach at nonzero progress: decode cursor reads source from offset zero without broadcast replay.
5. Source switch: old epoch chunks are rejected; new source starts cleanly.
6. Download final during partial loop: frame index reaches authoritative final count and playback continues without reload.
7. Exit reader to gallery and return: retained session is reused; logical detach does not clear resources.
8. Rapid slider jumps: current network starts without waiting for decode slots; stale display leases release safely.
9. 4K animation: fixed watermarks remain effective and upload queue stays bounded.
10. Native leak check: source, cursor and frame-handle counts return to retained/evicted expectations.

## Forbidden recovery paths

- `clearAll` on reader detach;
- visible-owned download or stream append;
- inferred/missing chunk repair;
- reload-final-bytes into a discontinuous streaming context;
- `RESYNC`, polling or retry used to mask an invalid session transition;
- dropping holder merely because page policy or transport permit changed.
