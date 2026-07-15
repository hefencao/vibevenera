# WebP Streaming Architecture

> **已过时（2026-07-15）**：本文是 WebP session 重构阶段的设计记录。其核心的
> lease/session/epoch 约束仍有效，但下载与显示层已经扩展为 WebP/GIF 共用的流媒体
> 图片管线。当前实现以
> [STREAMING_IMAGE_PIPELINE_ARCHITECTURE.md](STREAMING_IMAGE_PIPELINE_ARCHITECTURE.md)
> 为准。

## Goal

Build a high-performance streaming WebP pipeline with one authoritative byte source, stable sessions, independent scheduling stages, and no visible/pipeline ownership races. The architecture must support slow downloads, partial looping, range resume, source switching, reader detach/re-entry, rapid page changes, and future native texture rendering without replacing its public session interfaces.

## Core decisions

### Detach is logical

`detach` only removes a lease or demand from a session. It must not directly cancel a request, delete partial data, drop a decoder/holder, clear a cache, or reset native input.

```text
detachDisplay(lease)       -> remove display demand
detachReader(sessionId)    -> remove reader policy demand
detachDecode(lease)        -> remove decode demand
```

After demand changes, the session reconciler chooses `run`, `pause`, `retain`, or `evict` from the complete session state. Physical cleanup is an eviction result, never detach behavior.

### One authoritative byte source

Each download identity `(imageKey, sourceKey, cid, eid)` has one `NativeWebPSource`. All progress, resume, decode and finalization derive from it. Broadcast event history is not a byte source.

Every append is explicit and contiguous:

```text
append(epoch, offset, bytes)
offset == committedLength
```

Source changes increment `epoch`. Old-epoch writes are rejected. `seal` finalizes exactly the committed length.

### Holder is output-only

The holder exposes buffered frames and demand. It does not own the network stream, partial state, native input, playback owner, or resume behavior. Background task implementation is transparent to it.

### Per-WebP FrameBuffer remains

The reader is not a single video stream. Each `fullKey` keeps its own frame buffer and playback cursor. There is no global playback FrameQueue. Internal raw-frame and upload queues remain bounded.

## Target data flow

```text
Dart NetworkTransport
        │ one ingress copy
        ▼
NativeWebPSource                         keyed by download identity
  ├─ native-owned input storage
  ├─ epoch / committed / expected / final
  ├─ incremental RIFF/ANMF index
  └─ partial/final persistence boundary
        │ shared immutable source/index
        ▼
WebPDecodeSession                        keyed by fullKey/target size
  ├─ NativePlaybackCursor
  ├─ decode demand and scheduling
  ├─ compositing state
  └─ FrameHolder / FrameBuffer
        │
        ▼
FrameRenderer
  ├─ FlutterImageRenderer
  └─ NativeTextureRenderer
        │
        ▼
WebPImageProvider adapter / reader
```

## Native source

The first implementation uses the final native-owned storage model. A temporary Dart segmented byte cache is not introduced.

```c
WebPSource* webp_source_new(size_t expected_size, uint64_t epoch);
uint8_t* webp_source_reserve(WebPSource*, uint64_t epoch,
                             size_t offset, size_t length);
int webp_source_commit(WebPSource*, uint64_t epoch,
                       size_t offset, size_t length);
int webp_source_seal(WebPSource*, uint64_t epoch);
int webp_source_get_state(WebPSource*, WebPSourceState* out);
void webp_source_reset(WebPSource*, size_t expected_size, uint64_t new_epoch);
void webp_source_delete(WebPSource*);
```

Dio-owned Dart memory cannot safely be retained by native code. The transport copies each chunk once into the final reserved native region and immediately commits it. No temporary native input buffer or second decoder copy is allowed.

For untransformed network responses, the Session transport uses a stream-only downloader mode: original response chunks are forwarded without Dart concatenation, legacy partial-memory/history storage is disabled, and completion is an explicit final-length signal rather than a complete `Uint8List`. The Session artifact is the only partial persistence path. Responses requiring `onResponse`/`modifyImage` remain an explicit full-body compatibility path because transformation itself requires authoritative complete output.

The source stores offsets rather than long-lived pointers so storage growth cannot invalidate decode metadata. Expected length from HTTP or the RIFF header should allocate final capacity once. Unknown lengths use controlled growth under the source lock.

## Incremental container index

Repeated `WebPDemuxPartial` scans over a growing complete buffer are not the target implementation. `NativeWebPSource` incrementally parses RIFF chunks and records complete animation frames:

```text
RIFF/WEBP -> VP8X -> ANIM -> ANMF descriptors
```

Each descriptor contains frame payload offset/length, dimensions, offsets, duration, blend/dispose and alpha flags. Parsing advances monotonically from `parsedOffset`; incomplete trailing chunks remain pending until more bytes arrive.

## Decode and playback cursor

Input/index state and playback state are separate native objects:

```text
WebPSource
  bytes, metadata, frame descriptors, final state

WebPPlaybackCursor
  target size, frame index, loop index, composite canvas, scratch buffer
```

Appending only changes `WebPSource`. Partial looping only resets `WebPPlaybackCursor`. A source can serve multiple target-size cursors without duplicating compressed input.

## Session ownership

### DownloadSession

- One per download identity, provided by `DownloadSessionRegistry.getOrCreate`.
- Owns transport state and `NativeWebPSource`.
- Network preemption changes `receiving -> paused`; it does not destroy the source.
- Same-source range resume appends at `committedLength` in the same epoch.
- Source switching resets the source with a new epoch.
- Existing playback cursors rebind to the new source epoch after in-flight native work exits; playback restart alone never changes source identity.
- Completion validates and seals the source, then promotes partial storage atomically.

### WebPDecodeSession

- One per `fullKey`, provided by `DecodeSessionRegistry.getOrCreate`.
- References one `NativeWebPSource` and owns one playback cursor.
- Translates page policy into decode/upload demand.
- Survives visible detach and temporary page-priority changes.
- Display leases follow active ImageStream listeners, not ImageCache residency, and never create transport demand.
- Publishes an immediate state snapshot followed by ordered frame/status events.

### Cross-version cache reuse

An unchanged page alias canonicalizes only `DownloadIdentity`, so both versions
read the same compressed source and source epoch. `fullKey` keeps the logical
gallery/page identity: every version owns an independent `WebPDecodeSession`,
playback cursor and frame holder. A holder queue is single-consumer playback
state and must not be shared by two visible completers.

### Display lease

Visible UI obtains a display lease from the decode session. It does not start or join a download, append bytes, create a second decoder, or resume a stream. Releasing the lease is a logical detach.

## Scheduling

Scheduling stages are independent:

```text
NetworkScheduler  -> transport permits and download ranking
DecodeScheduler   -> native worker pool and frame demand
UploadScheduler   -> bounded Flutter/native renderer uploads
```

Current download cannot be delayed by decode/precreate tasks occupying a shared concurrency pool. Download, decode and upload permissions have independent revisions; changing decode policy cannot invalidate a network task.

Existing current/near/far window and frame watermarks remain. Current and near may stream-decode; far may download-only. Running downloads can continue outside the active window and may be paused under pressure without losing source state.

## Stable renderer boundary

Decode output is a native frame handle, not a hard-coded `ui.Image`:

```dart
abstract interface class FrameRenderer {
  Future<RenderedFrame> submit(NativeFrameHandle frame);
}
```

`FlutterImageRenderer` is the compatibility backend. `NativeTextureRenderer` can later replace it without changing download/source/decode session interfaces.

## Removed architecture

The completed refactor removes:

- holder stream owner and visible/pipeline ownership arbitration;
- visible download/bootstrap/resume streams;
- `_SharedStream` history as decoder input;
- inferred `currentBytes - chunk.length` offsets;
- coordinator attach/detach/replay;
- global holder waiters for stream results;
- download/decode shared execution epochs and concurrency slots;
- holder-managed download completion, resync and native input reset;
- detach-triggered cancellation, holder dropping and cache clearing.
