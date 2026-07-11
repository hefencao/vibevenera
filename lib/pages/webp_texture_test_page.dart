import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:venera/foundation/image_provider/renderer/webp_texture_channel.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/webp_decoder.dart' as webp;

/// 【临时】Stage 1+2 验证页，收口阶段删除。
/// - 验证点 A：纯色 RGBA -> native texture -> Texture widget。
/// - 验证点 B：选一个动图 webp -> source/cursor/worker 解码 -> 逐帧上传纹理
///   -> ticker 按帧时长播放。全程不分配 ui.Image、每帧不 setState。
class WebPTextureTestPage extends StatefulWidget {
  const WebPTextureTestPage({super.key});

  @override
  State<WebPTextureTestPage> createState() => _WebPTextureTestPageState();
}

class _WebPTextureTestPageState extends State<WebPTextureTestPage> {
  int? _textureId;
  String _status = 'init';

  // playback state
  webp.NativeWebPSource? _source;
  webp.NativeWebPPlaybackCursor? _cursor;
  bool _playing = false;
  bool _maxThroughput = false; // 跳过帧时长 delay，测解码/上传硬上限
  int _threads = 4; // libwebp 解码线程数
  int _frameCount = 0;
  int _fpsWindowStart = 0;
  double _fps = 0;
  int _decodeW = 0, _decodeH = 0;

  // 分段耗时累计（微秒），每个 fps 窗口平均后展示
  int _decodeUs = 0, _copyUs = 0, _uploadUs = 0, _delayUs = 0, _segFrames = 0;
  String _segReport = '';

  final _pool = webp.WorkerPoolScheduler.instance;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    final channel = WebPTextureChannel.instance;
    if (!channel.isSupported) {
      setState(() => _status = 'unsupported platform');
      return;
    }
    try {
      final id = await channel.create();
      if (id == null) {
        setState(() => _status = 'create returned null');
        return;
      }
      _textureId = id;
      await _pushColor(id, 0xFF, 0x00, 0x00);
      setState(() => _status = 'texture=$id ready (red)');
    } catch (e) {
      setState(() => _status = 'error: $e');
    }
  }

  Future<void> _pushColor(int id, int r, int g, int b) async {
    const w = 256, h = 256;
    final px = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      px[i * 4] = r;
      px[i * 4 + 1] = g;
      px[i * 4 + 2] = b;
      px[i * 4 + 3] = 0xFF;
    }
    await WebPTextureChannel.instance.update(id, w, h, px);
  }

  Future<void> _pickAndPlay() async {
    final picked = await selectFile(ext: ['webp']);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!webp.isWebP(bytes)) {
      setState(() => _status = 'not a webp');
      return;
    }
    try {
      _cursor?.dispose();
      _source?.dispose();
      final source = webp.createNativeWebPSource(expectedLength: bytes.length);
      source.append(bytes, offset: 0);
      source.seal();
      final cursor = webp.createNativeWebPPlaybackCursor(
        source,
        targetWidth: 1080,
        targetHeight: 2340,
      );
      cursor.setThreadLimit(_threads);
      _source = source;
      _cursor = cursor;
      _frameCount = 0;
      _fpsWindowStart = DateTime.now().millisecondsSinceEpoch;
      _playing = true;
      setState(() => _status = 'playing ${picked.name}');
      unawaited(_playLoop());
    } catch (e) {
      setState(() => _status = 'setup error: $e');
    }
  }

  void _stop() {
    _playing = false;
    setState(() => _status = 'stopped');
  }

  Future<void> _playLoop() async {
    final id = _textureId;
    final cursor = _cursor;
    if (id == null || cursor == null) return;

    while (_playing && mounted) {
      final t0 = DateTime.now().microsecondsSinceEpoch;
      final frame = await _decodeOneFrame(cursor);
      final t1 = DateTime.now().microsecondsSinceEpoch;
      if (!_playing || !mounted) break;
      if (frame == null) {
        try {
          cursor.restart();
        } catch (_) {}
        continue;
      }
      final st = cursor.state;
      final w = st.targetWidth, h = st.targetHeight;
      _decodeW = w;
      _decodeH = h;
      if (w > 0 && h > 0) {
        final view = Pointer<Uint8>.fromAddress(
          frame.address,
        ).asTypedList(w * h * 4);
        final copy = Uint8List.fromList(view);
        webp.nativePoolRelease(frame.address);
        final t2 = DateTime.now().microsecondsSinceEpoch;
        await WebPTextureChannel.instance.update(id, w, h, copy);
        final t3 = DateTime.now().microsecondsSinceEpoch;

        _decodeUs += t1 - t0;
        _copyUs += t2 - t1;
        _uploadUs += t3 - t2;
        _frameCount++;
        _segFrames++;
        _updateFps();

        if (!_maxThroughput) {
          final durMs = frame.durationMs <= 0 ? 100 : frame.durationMs;
          final t4a = DateTime.now().microsecondsSinceEpoch;
          await Future<void>.delayed(
            Duration(milliseconds: durMs.clamp(8, 1000)),
          );
          _delayUs += DateTime.now().microsecondsSinceEpoch - t4a;
        }
      } else {
        webp.nativePoolRelease(frame.address);
      }
    }
  }

  Future<webp.WebPAnimFrameAddress?> _decodeOneFrame(
    webp.NativeWebPPlaybackCursor cursor,
  ) {
    final st = cursor.state;
    final c = Completer<webp.WebPAnimFrameAddress?>();
    _pool.dispatch(
      webp.DecodeJob(
        generation: 1,
        decoderAddress: cursor.address,
        decoderEpoch: _pool.decoderEpoch(cursor.address),
        usePlaybackCursor: true,
        framesToDecode: 1,
        targetW: st.targetWidth,
        targetH: st.targetHeight,
        onComplete: (frames) =>
            c.complete(frames.isEmpty ? null : frames.first),
        onError: (e) => c.completeError(e),
      ),
      webp.DecodePriority.current,
    );
    return c.future;
  }

  void _updateFps() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _fpsWindowStart;
    if (elapsed >= 500) {
      final fps = _frameCount / (elapsed / 1000.0);
      final n = _segFrames > 0 ? _segFrames : 1;
      final report =
          'decode=${(_decodeUs / n / 1000).toStringAsFixed(1)}ms '
          'copy=${(_copyUs / n / 1000).toStringAsFixed(1)}ms '
          'upload=${(_uploadUs / n / 1000).toStringAsFixed(1)}ms '
          'delay=${(_delayUs / n / 1000).toStringAsFixed(1)}ms';
      _fpsWindowStart = now;
      _frameCount = 0;
      _decodeUs = _copyUs = _uploadUs = _delayUs = _segFrames = 0;
      if (mounted) {
        setState(() {
          _fps = fps;
          _segReport = report;
        });
      }
    }
  }

  @override
  void dispose() {
    _playing = false;
    final id = _textureId;
    if (id != null) WebPTextureChannel.instance.dispose(id);
    _cursor?.dispose();
    _source?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WebP Texture Test (Stage 1+2)')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: _textureId == null
                  ? const ColoredBox(color: Colors.grey)
                  : Texture(textureId: _textureId!),
            ),
            const SizedBox(height: 12),
            Text(_status),
            Text('decodeSize=${_decodeW}x$_decodeH  fps=${_fps.toStringAsFixed(1)}'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_segReport, textAlign: TextAlign.center),
            ),
            SwitchListTile(
              title: const Text('Max throughput (skip frame delay)'),
              value: _maxThroughput,
              onChanged: (v) => setState(() => _maxThroughput = v),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('threads: '),
                for (final t in [1, 2, 4, 6])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ChoiceChip(
                      label: Text('$t'),
                      selected: _threads == t,
                      onSelected: _playing
                          ? null
                          : (_) => setState(() => _threads = t),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _playing ? null : _pickAndPlay,
                  child: const Text('Pick webp & play'),
                ),
                ElevatedButton(
                  onPressed: _playing ? _stop : null,
                  child: const Text('Stop'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
