part of '../webp_image.dart';

class HolderDecodeService {
  final webp.WorkerPoolScheduler _pool = webp.WorkerPoolScheduler.instance;
  int _generation = 0;

  int get generation => _generation;

  void updateGeneration(int gen) {
    _generation = gen;
    _pool.updateGeneration(gen);
  }

  bool invalidatePendingDecodes(DecoderHolder holder) =>
      _pool.invalidateDecoder(holder.decoder.address);

  /// Attach decode driving to a holder. The holder will call back
  /// via [onNeedFrames] when it needs more frames decoded.
  void attach(DecoderHolder holder) {
    holder.onNeedFrames = () => _requestDecode(holder);
  }

  void _requestDecode(DecoderHolder holder) {
    // Adaptive batch: more when buffer is low, fewer when nearly full.
    final bufLen = holder.queuedFrameCount;
    final target = holder.state == PageState.current
        ? DecoderHolder._highWatermark
        : DecoderHolder._precacheTarget;
    final maxBatch = holder.state == PageState.current ? 6 : 4;
    final refillCount = (target - bufLen).clamp(1, maxBatch);
    holder._decodeInFlight = true;
    holder._dispatchGen = _generation;
    final token = holder._decodeToken;
    final job = webp.DecodeJob(
      generation: _generation,
      decoderAddress: holder.decoder.address,
      decoderEpoch: _pool.decoderEpoch(holder.decoder.address),
      isStreaming: holder.decoder.isStreaming,
      framesToDecode: refillCount,
      targetW: holder.targetW,
      targetH: holder.targetH,
      onComplete: (frames) => holder.onFramesDecoded(frames, token),
    );
    _pool.dispatch(
      job,
      holder.state == PageState.current
          ? webp.DecodePriority.current
          : webp.DecodePriority.next,
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 4. DecoderManager — holder lifecycle + eviction
//
// [FIX] ResourceEntry management is now in PipelineController.
// DecoderManager focuses on holder creation, lookup, and eviction.
// ═══════════════════════════════════════════════════════════════

