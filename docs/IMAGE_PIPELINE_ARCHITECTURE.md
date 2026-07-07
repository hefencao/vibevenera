# Image Pipeline Architecture

> Last updated: 2026-07-06

## 1. Architecture Overview

```
┌─ Reader UI Layer ────────────────────────────────────────────────────┐
│  _GalleryModeState / _ContinuousModeState                            │
│  ─ Sets InteractionState (idle/dragging/jumping/settling)            │
│  ─ Calls _updateWebPState on page changes                            │
└──────────────────────────────────────────────────────────────────────┘
         │ setInteractionState() / onPageChanged()
         ▼
┌─ Policy Engine (DecoderManager) ─────────────────────────────────────┐
│  ResourcePolicyEngine.refresh()                                      │
│  ─ Computes ResourcePolicy for each entry                            │
│  ─ Generates work list based on policy gaps                          │
│  ─ Priority-based task migration (not generation-based)              │
└──────────────────────────────────────────────────────────────────────┘
         │ policy-driven task submission
         ▼
┌─ Resource State (ResourceEntry) ─────────────────────────────────────┐
│  Single source of truth per image:                                   │
│  state / bytes / holder / priority / policy / frame counters         │
│  ─ Replaces fragmented DecoderHolder + L2 cache + TaskScheduler state│
└──────────────────────────────────────────────────────────────────────┘
         │ DownloadTask / PrecreateTask
         ▼
┌─ Execution Layer (TaskScheduler) ─────────────────────────────────────┐
│  Pure execution: Run(Task) with concurrency control (max 3)          │
│  ─ CancelToken propagation for HTTP abort                            │
│  ─ Preemption at priority gap ≥40                                    │
│  ─ List<Completer> for multi-caller dedup                            │
└──────────────────────────────────────────────────────────────────────┘
         │
    ┌────┴──────────────────────┐
    ▼                           ▼
┌─ Download ───────────┐  ┌─ Decode (WorkerPoolScheduler) ───┐
│ ImageDownloader      │  │ Frame decode in isolate workers  │
│ ─ Dio + CancelToken  │  │ ─ Ctx-hash affinity             │
│ ─ Disk cache         │  │ ─ Generation check at dispatch  │
│ ─ SharedStream dedup │  │ ─ Priority-aware queue          │
└──────────────────────┘  └──────────────────────────────────┘
                                    │
                                    ▼
                           ┌─ GPU Upload ──────────┐
                           │ decodeImageFromPixels │
                           │ ─ Per-frame async     │
                           │ ─ As frameBuffer fill │
                           └───────────────────────┘
```

## 2. Key Design Decisions

### 2.1 ResourceEntry as Single Source of Truth

**Problem**: State was fragmented across 5+ locations (DecoderHolder._disposed, DecodedImageCache L1/L2, TaskScheduler._activeTasks, _holders, _pendingLoads). Each had its own lifecycle tracking, leading to inevitable desync.

**Solution**: `ResourceEntry` in [task_scheduler.dart](../lib/foundation/image_provider/task_scheduler.dart) holds all state for one image resource. All other components query or update this single entry rather than maintaining parallel state.

```dart
class ResourceEntry {
  final String imageKey;          // bare key
  final String fullKey;           // imageKey@WxH (dedup key)
  ResourceState state;            // none → downloading → downloaded → decoding → decoded
  Uint8List? bytes;               // raw WebP bytes
  DecoderHolder? holder;          // decoder instance (dynamic to avoid circular import)
  PagePriority priority;          // current / near / far / distant
  ResourcePolicy policy;          // allowDownload / allowDecode / allowGpuUpload
  int decodedFrameCount;          // frames decoded, not yet uploaded
  int uploadedFrameCount;         // frames on GPU
}
```

### 2.2 Policy-Driven Scheduling

**Problem**: `activePagesChanged` submitted `DownloadTask`/`PrecreateTask` directly, then called `refresh()` which only updated holder policies. `InteractionState.dragging` set `allowDecode=false` but pre-download tasks were still submitted anyway.

**Solution**: `refresh()` runs BEFORE task submission. Each task submission is gated on the entry's current policy. During dragging, only the current page gets downloads; near/far pages get nothing.

| Interaction | Current | Near (±1-3) | Far (+4-5) | Distant |
|---|---|---|---|---|
| **idle** | download+decode+upload | download+decode | download only | evict |
| **dragging** | download+upload (no decode) | — | — | — |
| **settling** | download+decode+upload | download+decode (no upload) | download only | — |
| **jumping** | download+decode+upload | — | — | evict |

### 2.3 Priority-Based Task Migration (not Generation)

**Problem**: `_generation++` on every page change canceled ALL pre-download tasks. Page 5→6 would cancel tasks for pages 7-11, which immediately re-submitted. This caused the "预下载失效" (pre-download not working) and task churn.

**Solution**: `TaskScheduler.migrateTasks()` cancels only tasks for pages that left the working set. Tasks for pages still in range get priority updates. `WorkerPoolScheduler` generation check is kept separately for frame-decode safety.

### 2.4 TaskScheduler as Pure Execution Layer

**Problem**: TaskScheduler handled priority, merge, callback management, generation cancellation, and dedup — it knew too much about why tasks run.

**Solution**: TaskScheduler now only knows `submit(Task)`, `cancel(key)`, `_dispatchNext()`, and `migrateTasks()`. All policy decisions live in `DecoderManager` / `ResourcePolicyEngine`.

### 2.5 CancelToken Propagation

**Problem**: `_sub?.cancel()` only stopped listening to the stream; the HTTP request continued, consuming bandwidth and memory.

**Solution**: `DownloadTask` creates a `CancelToken` passed through `ImageDownloader.loadComicImage()` → `_loadComicImage()` → `_executeDownload()` → `dio.request(cancelToken:)`. On cancel, the HTTP request is aborted at the Dio level.

## 3. Data Flow

### Normal Page Turn (Page 5 → Page 6)

```
1. Reader UI: setInteractionState(settling)
2. _updateWebPState(6, context)
3. DecoderManager.activePagesChanged(currentPageIndex=5)
4.   _generation++ (for WorkerPoolScheduler frame-decode safety)
5.   Compute page priorities: current=5, near={6,7}, last={4}, far={8,9}
6.   _ensureEntry() for each → populates ResourceEntry map + index
7.   refresh() → compute ResourcePolicy for all entries
8.   migrateTasks() → upgrade page 7-9 tasks, cancel tasks for page 3
9.   Submit DownloadTask for page 7-9 (if allowDownload)
10.  Submit PrecreateTask for page 6-7 (if allowDecode)
11.  300ms timer → setInteractionState(idle) → refresh() again
12.    In idle: allowDecode for near pages, PrecreateTask for 8-9
```

### Rapid Drag

```
1. ScrollStartNotification → setInteractionState(dragging)
2.   refresh() → all non-current entries: allowDownload=false, allowDecode=false
3.   Running PrecreateTasks check policy at execute() → self-cancel
4.   Running DownloadTasks continue (current page needs bytes)
5.   No new tasks submitted for near/far
6. ScrollEndNotification → setInteractionState(settling)
7.   300ms → idle → full pipeline resumes for current+near
```

### Jump to Distant Page (Page 5 → Page 100)

```
1. toPage(100) → setInteractionState(jumping)
2.   refresh() → only current page gets full pipeline; all others: evict
3.   migrateTasks() → cancel all tasks for pages 6-12
4.   Only page 100 gets DownloadTask + PrecreateTask
5.   300ms → idle → pre-download for 101-105 resumes
```

## 4. Component Inventory

| Component | File | Responsibility |
|---|---|---|
| `InteractionState` | [task_scheduler.dart](../lib/foundation/image_provider/task_scheduler.dart) | Enum: idle/dragging/jumping/settling |
| `PagePriority` | [task_scheduler.dart](../lib/foundation/image_provider/task_scheduler.dart) | Enum: current/near/far/distant |
| `ResourcePolicy` | [task_scheduler.dart](../lib/foundation/image_provider/task_scheduler.dart) | allowDownload/allowDecode/allowGpuUpload + priorities |
| `ResourceEntry` | [task_scheduler.dart](../lib/foundation/image_provider/task_scheduler.dart) | Single source of truth per image |
| `ResourceState` | [task_scheduler.dart](../lib/foundation/image_provider/task_scheduler.dart) | Lifecycle: none→downloading→downloaded→decoding→decoded |
| `DownloadTask` | [task_scheduler.dart](../lib/foundation/image_provider/task_scheduler.dart) | Network/cache byte fetch with CancelToken |
| `PrecreateTask` | [task_scheduler.dart](../lib/foundation/image_provider/task_scheduler.dart) | Pre-create WebP decoder holder |
| `TaskScheduler` | [task_scheduler.dart](../lib/foundation/image_provider/task_scheduler.dart) | Pure execution: priority queue + concurrency control |
| `DecoderManager` | [webp_image_provider.dart](../lib/foundation/image_provider/webp_image_provider.dart) | PolicyEngine + entry/holder lifecycle |
| `DecoderHolder` | [webp_image_provider.dart](../lib/foundation/image_provider/webp_image_provider.dart) | WebP decoder wrapper + frame buffer |
| `WebPImageProvider` | [webp_image_provider.dart](../lib/foundation/image_provider/webp_image_provider.dart) | Flutter ImageProvider + animation loop |
| `ImageDownloader` | [images.dart](../lib/network/images.dart) | HTTP download with SharedStream dedup + CancelToken |
| `WorkerPoolScheduler` | [webp_decoder.dart](../lib/utils/webp_decoder.dart) | Isolate-based frame decode with ctx-hash affinity |
| `DecodedImageCache` | [decoded_image_cache.dart](../lib/foundation/image_provider/decoded_image_cache.dart) | L1 (ui.Image) + L2 (bytes) + L3 (RGBA) storage |

## 5. Concurrency Model

```
TaskScheduler: max 3 concurrent tasks (I/O bound)
├── DownloadTask: Dio HTTP → disk cache
│   └── CancelToken: aborts HTTP on cancel
└── PrecreateTask: ensureHolder(onlyIfCached: true)
    └── Checks policy.allowDecode before executing

WorkerPoolScheduler: 2 persistent workers
├── DecodeJob: ctx-hash → deterministic worker assignment
├── Generation check: reject stale jobs at dispatch
└── DecodePriority: current > next (for queue ordering)
```

## 6. Key Bug Fixes Applied

| # | Bug | Fix | File |
|---|---|---|---|
| 1 | Callback overwrite on duplicate submit | `List<Completer>` instead of single callback | task_scheduler.dart |
| 2 | onDone check wrong (callback always exists) | Track `_bytesReceived` flag | task_scheduler.dart |
| 3 | Priority upgrade doesn't re-sort queue | Call `_sortQueue()` after upgrade | task_scheduler.dart |
| 4 | Running task can't be preempted | `_maybePreempt()` with 40-pt threshold | task_scheduler.dart |
| 5 | HTTP continues after stream cancel | `CancelToken` through to `dio.request()` | task_scheduler.dart, images.dart |
| 6 | `file://` URI crash | `Uri.parse().toFilePath()` | image_fetch.dart |
| 7 | Pre-download not working | Policy-driven scheduling + priority migration | webp_image_provider.dart |
| 8 | `_evictDistant` use-after-free crash | `markPendingDispose()` with 500ms fallback | webp_image_provider.dart |

## 7. Logging Convention

```
[WebP-PRE]       — Pre-download/pre-create scheduling decisions
[DownloadTask]   — Download lifecycle (START/HIT-CACHE/NETWORK/DONE/CANCEL-POLICY)
[Precreate]      — Precreate lifecycle (EXEC/DONE/FAIL/CANCEL-POLICY)
[WebP]           — Image loading (L2 cache hit/miss, byte source, timing)
[WebP-HOLDER]    — DecoderHolder creation (byte source, size)
[Resource]       — ResourceEntry state transitions
[TaskScheduler]  — Task dispatch, preemption, migration
[WebP-T]         — WorkerPoolScheduler dispatch/reject
```
