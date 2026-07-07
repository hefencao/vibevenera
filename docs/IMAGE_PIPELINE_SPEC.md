# Image Pipeline Specification

> Last updated: 2026-07-06

## 1. InteractionState Specification

The `InteractionState` enum drives all policy decisions. It is set by the Reader UI layer and consumed by `ResourcePolicy.compute()`.

### 1.1 States

| State | Trigger | Duration | Effect |
|---|---|---|---|
| `idle` | Default; 300ms after last scroll/jump event | Until next interaction | Full pipeline for current+near; download-only for far |
| `dragging` | `ScrollStartNotification` in ContinuousMode | Until `ScrollEndNotification` | Only current page: download+upload. No decode. No pre-download. |
| `settling` | Page change / scroll end | 300ms timer, then → idle | Current: full. Near: download+decode (no GPU upload). Far: download-only. |
| `jumping` | `jumpTo`/`toPage` for distant pages | 300ms timer, then → idle | Only target page: full pipeline. All others: evict. |

### 1.2 Transition Rules

```
idle ──(scroll start)──► dragging
idle ──(page change)──► settling
idle ──(jumpTo far)──► jumping
dragging ──(scroll end)──► settling
settling ──(300ms timeout)──► idle
jumping ──(300ms timeout)──► idle
```

### 1.3 UI Integration

**GalleryMode** (`_GalleryModeState`):
- `onPageChanged`: `setInteractionState(settling)` → 300ms → `idle`
- `animateToPage` (distant): `setInteractionState(jumping)` → 300ms → `idle`
- `toPage`: `setInteractionState(jumping)` → 300ms → `idle`

**ContinuousMode** (`_ContinuousModeState`):
- `ScrollStartNotification`: `setInteractionState(dragging)`
- `ScrollEndNotification`: `setInteractionState(settling)` → 300ms → `idle`
- `onPositionChanged` (page change): `setInteractionState(settling)` → 300ms → `idle`

## 2. PagePriority Specification

Assigned by distance from the current viewport page.

| Priority | Distance | Description |
|---|---|---|
| `current` | 0 | Visible now. Always gets highest priority. |
| `near` | ±1 to +2 | Next pages to view. Full pipeline in idle. |
| `far` | +3 to +4 | Prefetch range. Download-only in idle. |
| `distant` | > +4 or not in range | Candidate for eviction. |

## 3. ResourcePolicy Rules

`ResourcePolicy.compute(interaction, priority)` returns a policy object:

### 3.1 Policy Matrix

| Interaction | Priority | allowDownload | allowDecode | allowGpuUpload | downloadPriority | decodePriority |
|---|---|---|---|---|---|---|
| idle | current | ✓ | ✓ | ✓ | 100 | 100 |
| idle | near | ✓ | ✓ | ✓ | 50 | 50 |
| idle | far | ✓ | ✗ | ✗ | 20 | 0 |
| idle | distant | ✗ | ✗ | ✗ | 0 | 0 |
| dragging | current | ✓ | ✗ | ✓ | 100 | 0 |
| dragging | near | ✓ | ✗ | ✗ | 30 | 0 |
| dragging | far | ✓ | ✗ | ✗ | 10 | 0 |
| dragging | distant | ✗ | ✗ | ✗ | 0 | 0 |
| settling | current | ✓ | ✓ | ✓ | 100 | 100 |
| settling | near | ✓ | ✓ | ✗ | 40 | 40 |
| settling | far | ✓ | ✗ | ✗ | 15 | 0 |
| settling | distant | ✗ | ✗ | ✗ | 0 | 0 |
| jumping | current | ✓ | ✓ | ✓ | 100 | 100 |
| jumping | non-current | ✗ | ✗ | ✗ | 0 | 0 |

### 3.2 Static Constants

Policy objects are pre-allocated as `static const` instances (`_none`, `_current`, `_near`, `_far`, `_distant`) and only instantiated for mixed states.

## 4. ResourceEntry State Machine

### 4.1 States

```
none ──(download started)──► downloading
downloading ──(bytes received)──► downloaded
downloaded ──(decoder created)──► decoding
decoding ──(holder ready)──► decoded
decoded ──(evicted)──► downloaded   (holder removed, bytes kept)
any ──(error)──► error
```

### 4.2 State Transitions

| From | To | Trigger | Set By |
|---|---|---|---|
| `none` | `downloading` | DownloadTask submitted | `activePagesChanged` |
| `downloading` | `downloaded` | Bytes received from network/cache | DownloadTask completion callback |
| `none` | `downloaded` | Bytes found in L2 cache | `_ensureEntry` |
| `downloaded` | `decoding` | PrecreateTask submitted | `activePagesChanged` |
| `decoding` | `decoded` | DecoderHolder created | `getOrCreateHolder` |
| `decoded` | `downloaded` | Holder evicted (bytes kept) | `_evictDistant` |
| `decoded` | `downloaded` | Holder marked for dispose | `markPendingDispose` callback |

### 4.3 Frame Counters

`decodedFrameCount` and `uploadedFrameCount` track per-frame progress on the DecoderHolder rather than a misleading binary "gpu" state. These are maintained by `DecoderHolder` during `_scheduleDecode` and `_doUpload`.

## 5. Task Specification

### 5.1 DownloadTask

**Purpose**: Fetch raw image bytes from network or disk cache.

**Lifecycle**:
```
Created → Queued (priority order) → Executing → Completed/Failed
         ↓                                    ↓
      Merged (if same key)              Cancelled (CancelToken)
```

**Key dedup**: By `imageKey` (bare key). If a DownloadTask with the same key is already queued/running, the new task's completers are merged into the existing task.

**Policy check**: At `execute()` start, checks `DecoderManager.getEntry(fullKey)?.policy.allowDownload`. If false, self-cancels.

**CancelToken**: Created at `execute()` start. Passed through `ImageDownloader.loadComicImage()` → `_loadComicImage()` → `_executeDownload()` → `dio.request(cancelToken:)`. On `cancel()`, calls `_cancelToken?.cancel()` which aborts the HTTP request at the Dio level.

**Multi-caller**: Uses `List<Completer<Uint8List>>`. Callers call `register()` to get a Future. On completion, all completers are resolved. On failure, all are rejected.

**Cache check order**:
1. `CacheManager.findCache(cacheKey)` → disk cache
2. `ImageDownloader.loadComicImage()` → network (with CancelToken)

### 5.2 PrecreateTask

**Purpose**: Pre-create a WebP `DecoderHolder` before the image is first viewed. Eliminates first-frame latency.

**Lifecycle**:
```
Created → Queued → Executing → Completed/Failed
```

**Key dedup**: By `fullKey` (imageKey@WxH). Ensures only one holder per target resolution.

**Policy check**: At `execute()` start, checks `DecoderManager.getEntry(key)?.policy.allowDecode`. If false, self-cancels.

**Execution**: Calls `WebPImageProvider.ensureHolder(onlyIfCached: true)`. This only creates a holder if bytes are already in L2 cache or provided. If bytes need fetching, returns null (does NOT trigger network download — that's DownloadTask's job).

### 5.3 Task Priority Ranges

| Priority Range | Usage |
|---|---|
| 100 | Current page |
| 50 | Near page (idle) |
| 30-40 | Near page (settling/dragging) |
| 10-20 | Far page (pre-download) |
| 0 | Distant (no work) |

## 6. TaskScheduler Specification

### 6.1 Core API

```dart
void submit(SchedulerTask task);     // Queue or merge
void cancel(String key);             // Cancel specific task
void migrateTasks(activeKeys, newPriorities); // Priority-based migration
void clear();                        // Cancel all
```

### 6.2 Concurrency Control

- Max concurrent: 3 tasks (`_maxConcurrentTasks`)
- Queue ordered by `priority` descending
- Tasks dispatched via `scheduleMicrotask` to avoid blocking the event loop

### 6.3 Preemption Rules

When `submit()` finds an existing task with the same key:
1. If new priority > old priority: upgrade priority + re-sort queue
2. If new priority - old priority ≥ 40 (preemption threshold): cancel the running task and submit the new one
3. Merge completers (DownloadTask) — never overwrite

### 6.4 Task Migration

`migrateTasks(activeKeys, newPriorities)`:
- Tasks for keys in `activeKeys`: update priority
- Tasks for keys NOT in `activeKeys` and `cancelable`: cancel
- Running tasks for keys NOT in `activeKeys` and `cancelable`: cancel
- Re-sort queue after migration

## 7. DecoderManager Specification

### 7.1 Entry Points

| Method | Called By | Purpose |
|---|---|---|
| `activePagesChanged()` | `_updateWebPState` (reader UI) | Page range changed — full refresh |
| `setInteractionState()` | Reader UI (scroll/page events) | Interaction state changed — policy refresh |
| `getEntry()` | `_loadImageAsync`, tasks | Query resource state |
| `getOrCreateHolder()` | `ensureHolder` | Create decoder holder |
| `clearAll()` | Reader dispose | Cleanup all resources |

### 7.2 Data Structures

```
_holders:          Map<fullKey, DecoderHolder>   — active decoder holders
_entries:          Map<fullKey, ResourceEntry>   — all tracked image state
_entryKeyIndex:    Map<imageKey, fullKey>        — O(1) bare-key lookup
_currentKey:       String                        — current page key
_nextKeys:         Set<String>                   — near (+1,+2) keys
_lastKeys:          Set<String>                   — previous (-1) keys
_precacheKeys:     Set<String>                   — far (+3,+4) keys
```

### 7.3 Eviction Policy

- Timer: 1-second heartbeat via `_ensureEvictionTimer()`
- Criteria: holder not in any priority set AND `lastAccessTime > 2000ms` ago
- Action: `markPendingDispose()` on holder, update ResourceEntry state
- Timer stops when `_holders` is empty

### 7.4 markPendingDispose Protocol

To prevent use-after-free crashes (worker isolate still decoding when native memory is freed):

1. Set `_pendingDispose = true` — prevents new decode jobs
2. If in-flight decode job completes and sees `_pendingDispose`: calls `dispose()`
3. 500ms fallback timer: if no in-flight job triggers dispose, force-dispose
4. `dispose()` checks `_disposed` guard to prevent double-free

## 8. ImageDownloader Specification

### 8.1 Public API

```dart
// Deduplicated stream — multiple callers share one download
static Stream<ImageDownloadProgress> loadComicImage(
  String imageKey, String? sourceKey, String cid, String eid,
  {CancelToken? cancelToken}
);

// Independent stream — each caller gets its own download
static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
  String imageKey, String? sourceKey, String cid, String eid,
  {CancelToken? cancelToken}
);

// Cancel all in-flight downloads
static void cancelAllLoadingImages();
```

### 8.2 SharedStream Dedup

- Key: `$imageKey@$sourceKey@$cid@$eid`
- `_SharedStream` wraps the source stream as a broadcast
- First caller creates the SharedStream; subsequent callers get the existing stream
- When all listeners are gone, SharedStream self-disposes
- CancelToken is shared — canceling cancels for all

### 8.3 Download Execution

- URL resolution: `//` → `https://` prefix
- Response transformation: `config.onResponse` JS callback (decrypt/unpack)
- Image modification: `modifyImageWithScript` for custom processing
- Disk cache: `CacheManager().writeCache()` after successful download
- Retry: up to 5 times via `config.onLoadFailed` JS callback
- Progress throttling: max 1 event per 100ms

## 9. Frame Decode Pipeline (WorkerPoolScheduler)

Already well-designed; kept unchanged:

- **Ctx-hash affinity**: `decoder.address % 2` → deterministic worker assignment. Prevents concurrent access to non-thread-safe C state.
- **Generation check**: `dispatch()` rejects jobs with stale generation BEFORE queue insertion. Prevents wasted work.
- **DecodePriority**: `current` vs `next` for queue ordering.

## 10. Error Handling

### 10.1 Download Errors

- Network error → `onError` callback → `_rejectAll(error)` → TaskScheduler.onTaskFailed
- Stream closed without bytes → onDone + `!_bytesReceived` → `_rejectAll('Download completed without data')`
- Cancel → `_rejectAll('Cancelled')`

### 10.2 Decode Errors

- Invalid WebP header → `_loadImageAsync` returns `_ImageResult.error`
- Decoder creation failure → `ensureHolder` returns null
- Static decode failure → `_ImageResult.error`

### 10.3 Animation Errors

- Holder disposed during animation → `_reloadAndRestart()` in `_startAnimationLoop`
- Lifecycle pause (app background) → skip frame, wait 200ms

## 11. Performance Characteristics

| Operation | Complexity | Notes |
|---|---|---|
| Entry lookup by fullKey | O(1) | Direct HashMap access |
| Entry lookup by imageKey | O(1) | Via `_entryKeyIndex` |
| Policy apply to entry | O(1) | Via `_entryKeyIndex` |
| Task submit (new) | O(log n) | Priority queue insertion |
| Task submit (merge) | O(1) | Direct key lookup |
| Task migration | O(k) | k = number of active tasks (small) |
| Eviction heartbeat | O(h) | h = number of holders (small, ≤10) |
| L2 cache check | O(1) | HashMap |
| Disk cache check | O(1) | Via CacheManager (filesystem) |

## 12. Thread Safety

- **UI thread**: All Dart widget code, ResourceEntry state changes, TaskScheduler operations
- **Worker isolates**: Frame decode (`animGetFrames`), static WebP decode, file read (Isolate.run for >1MB files)
- **Ctx-hash affinity**: Same decoder always → same worker → sequential access to non-thread-safe C state
- **markPendingDispose**: Prevents concurrent access to decoder during disposal
