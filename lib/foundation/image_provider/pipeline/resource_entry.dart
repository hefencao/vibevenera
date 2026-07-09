import 'dart:typed_data';

import 'package:venera/foundation/log.dart';

// ───────────────────────────────────────────────────────────────
// 1. Enums
// ───────────────────────────────────────────────────────────────

enum InteractionState { idle, dragging, jumping, settling }

enum PagePriority { current, near, far, keep, distant }

/// Explicit task lifecycle state.
/// [FIX-7] Replaces implicit state spread across Registry + Queue + bool flags.
enum TaskState { queued, running, completed, cancelled, failed }

class ReaderDownloadProgress {
  final String imageKey;
  final bool active;
  final int currentBytes;
  final int? totalBytes;
  final double speedBytesPerSecond;

  const ReaderDownloadProgress({
    required this.imageKey,
    required this.active,
    required this.currentBytes,
    required this.totalBytes,
    required this.speedBytesPerSecond,
  });

  const ReaderDownloadProgress.idle()
    : imageKey = '',
      active = false,
      currentBytes = 0,
      totalBytes = null,
      speedBytesPerSecond = 0;

  double get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return 0;
    return (currentBytes / total).clamp(0.0, 1.0);
  }
}


// ───────────────────────────────────────────────────────────────
// 2. ResourcePolicy
// ───────────────────────────────────────────────────────────────

class ResourcePolicy {
  final bool allowDownload;
  final bool allowDecode;
  final bool allowGpuUpload;
  final bool allowEviction;
  final int downloadPriority;
  final int decodePriority;

  const ResourcePolicy({
    this.allowDownload = false,
    this.allowDecode = false,
    this.allowGpuUpload = false,
    this.allowEviction = false,
    this.downloadPriority = 0,
    this.decodePriority = 0,
  });

  ResourcePolicy withDownloadPriority(int priority) {
    return ResourcePolicy(
      allowDownload: allowDownload,
      allowDecode: allowDecode,
      allowGpuUpload: allowGpuUpload,
      allowEviction: allowEviction,
      downloadPriority: priority,
      decodePriority: decodePriority,
    );
  }

  static const _none = ResourcePolicy();

  static const _current = ResourcePolicy(
    allowDownload: true,
    allowDecode: true,
    allowGpuUpload: true,
    downloadPriority: 100,
    decodePriority: 100,
  );

  static const _near = ResourcePolicy(
    allowDownload: true,
    allowDecode: true,
    allowGpuUpload: true,
    downloadPriority: 50,
    decodePriority: 50,
  );

  static const _far = ResourcePolicy(
    allowDownload: true,
    allowDecode: false,
    allowGpuUpload: false,
    downloadPriority: 20,
    decodePriority: 0,
  );

  static const _keep = ResourcePolicy();

  static const _distant = ResourcePolicy(allowEviction: true);

  static const _draggingCurrent = ResourcePolicy(
    allowDownload: true,
    allowDecode: true,
    allowGpuUpload: true,
    downloadPriority: 100,
    decodePriority: 100,
  );

  static const _draggingNear = ResourcePolicy(
    allowDownload: true,
    allowDecode: true,
    allowGpuUpload: true,
    downloadPriority: 30,
    decodePriority: 30,
  );

  static const _draggingFar = ResourcePolicy(
    allowDownload: true,
    downloadPriority: 10,
  );

  static const _settlingNear = ResourcePolicy(
    allowDownload: true,
    allowDecode: true,
    downloadPriority: 40,
    decodePriority: 40,
  );

  static const _settlingFar = ResourcePolicy(
    allowDownload: true,
    downloadPriority: 15,
  );

  static const _table = <InteractionState, Map<PagePriority, ResourcePolicy>>{
    InteractionState.dragging: {
      PagePriority.current: _draggingCurrent,
      PagePriority.near: _draggingNear,
      PagePriority.far: _draggingFar,
      PagePriority.keep: _keep,
      PagePriority.distant: _distant,
    },
    InteractionState.jumping: {
      PagePriority.current: _current,
      PagePriority.near: _distant,
      PagePriority.far: _distant,
      PagePriority.keep: _keep,
      PagePriority.distant: _distant,
    },
    InteractionState.settling: {
      PagePriority.current: _current,
      PagePriority.near: _settlingNear,
      PagePriority.far: _settlingFar,
      PagePriority.keep: _keep,
      PagePriority.distant: _distant,
    },
    InteractionState.idle: {
      PagePriority.current: _current,
      PagePriority.near: _near,
      PagePriority.far: _far,
      PagePriority.keep: _keep,
      PagePriority.distant: _distant,
    },
  };

  static ResourcePolicy compute(InteractionState i, PagePriority p) =>
      _table[i]?[p] ?? _none;
}

// ───────────────────────────────────────────────────────────────
// 3. ResourceEntry — single source of truth
// ───────────────────────────────────────────────────────────────

/// Sub-state for the download phase.
class DownloadState {
  bool inProgress = false;
  int currentBytes = 0;
  int? totalBytes;
  Object? lastError;
  void reset() {
    inProgress = false;
    currentBytes = 0;
    totalBytes = null;
    lastError = null;
  }

  void updateProgress(int current, int? total) {
    currentBytes = current;
    totalBytes = total == 0 ? null : total;
  }

  double get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return 0;
    return (currentBytes / total).clamp(0.0, 1.0);
  }
}

/// Sub-state for the decode phase.
class DecodeState {
  bool inProgress = false;
  int decodedFrameCount = 0;
  int uploadedFrameCount = 0;
  int failureCount = 0;
  int lastFailureMs = 0;
  Object? lastError;
  void reset() {
    inProgress = false;
    decodedFrameCount = 0;
    uploadedFrameCount = 0;
    failureCount = 0;
    lastFailureMs = 0;
    lastError = null;
  }

  void markFailure(Object error) {
    inProgress = false;
    failureCount++;
    lastFailureMs = DateTime.now().millisecondsSinceEpoch;
    lastError = error;
  }

  void markSuccess() {
    inProgress = false;
    failureCount = 0;
    lastFailureMs = 0;
    lastError = null;
  }

  bool get isInBackoff {
    if (failureCount == 0) return false;
    final delayMs = (1000 * (1 << (failureCount - 1))).clamp(1000, 30000);
    return DateTime.now().millisecondsSinceEpoch - lastFailureMs < delayMs;
  }
}

/// Single source of truth for one image resource.
///
/// [FIX-1] Removed the `ResourceState` enum. Overall state is derived
/// dynamically from sub-states — no more dual-source conflicts.
class ResourceEntry {
  final String imageKey;
  final String fullKey;
  final String? sourceKey;
  final String cid;
  final String eid;

  PagePriority _priority = PagePriority.distant;
  PagePriority get priority => _priority;

  ResourcePolicy _policy = ResourcePolicy._none;
  ResourcePolicy get policy => _policy;

  /// [FIX-2] Monotonic counter. Incremented ONLY when allowDownload
  /// or allowDecode changes (not priority). Running tasks compare
  /// their snapshot against this to detect permission revocation.
  int executionEpoch = 0;

  Uint8List? bytes;
  dynamic holder; // DecoderHolder
  Object? error;

  final DownloadState download = DownloadState();
  final DecodeState decode = DecodeState();

  int generation = 0;
  int lastAccessMs = 0;

  ResourceEntry({
    required this.imageKey,
    required this.fullKey,
    this.sourceKey,
    required this.cid,
    required this.eid,
  });

  // ── Derived state ──────────────────────────────────────────

  /// [FIX-1] Dynamically derived overall state. No more dual-source
  /// conflicts with DownloadState/DecodeState.
  String get overallState {
    if (error != null) return 'error';
    if (holder != null) return 'decoded';
    if (decode.inProgress) return 'decoding';
    if (bytes != null) return 'downloaded';
    if (download.inProgress) return 'downloading';
    return 'none';
  }

  bool get hasBytes => bytes != null;
  bool get hasHolder => holder != null;

  // ── Mutations ──────────────────────────────────────────────

  void updatePriority(PagePriority p) => _priority = p;

  void updatePolicy(ResourcePolicy newPolicy) {
    // [FIX-2] Only increment epoch when execution permissions change
    if (_policy.allowDownload != newPolicy.allowDownload ||
        _policy.allowDecode != newPolicy.allowDecode) {
      executionEpoch++;
    }
    _policy = newPolicy;
  }

  void logTransition(String from, String to) {
    Log.info(
      'ImagePipeline.Resource',
      '$_shortKey $from → $to '
          '(dl=${_policy.allowDownload} dec=${_policy.allowDecode})',
    );
  }

  String get _shortKey {
    final s = imageKey.split('/').last;
    return s.length > 20 ? s.substring(s.length - 20) : s;
  }
}

// ───────────────────────────────────────────────────────────────
// 4. ExecutionContext — decouples Tasks from Policy/Entry
// ───────────────────────────────────────────────────────────────

/// [FIX-6] Tasks interact with the pipeline exclusively through
/// this context. They never access Policy, ResourceEntry, or
/// DecoderManager directly. This means Policy can change freely
/// without touching Task code.
class ExecutionContext {
  final ResourceEntry entry;
  final int _capturedEpoch;

  ExecutionContext(this.entry) : _capturedEpoch = entry.executionEpoch;

  /// Whether the task is still allowed to continue.
  bool get canContinue {
    return entry.executionEpoch == _capturedEpoch;
  }

  /// Type-specific permission checks.
  bool get downloadAllowed => canContinue && entry.policy.allowDownload;
  bool get decodeAllowed => canContinue && entry.policy.allowDecode;

  /// The entry's current policy (read-only for tasks).
  ResourcePolicy get policy => entry.policy;
}
