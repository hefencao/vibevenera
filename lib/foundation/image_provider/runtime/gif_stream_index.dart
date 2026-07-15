import 'dart:typed_data';

final class GifStreamIndexSnapshot {
  final int width;
  final int height;
  final int frameCount;
  final int completeOffset;
  final bool trailerSeen;

  const GifStreamIndexSnapshot({
    required this.width,
    required this.height,
    required this.frameCount,
    required this.completeOffset,
    required this.trailerSeen,
  });
}

enum _GifParseState {
  header,
  logicalScreen,
  globalColorTable,
  block,
  extensionLabel,
  extensionSize,
  extensionData,
  imageDescriptor,
  localColorTable,
  lzwCodeSize,
  imageDataSize,
  imageData,
  done,
}

/// Incrementally indexes complete GIF image blocks without retaining consumed
/// compressed bytes. A partial trailing block remains bounded to at most one
/// GIF sub-block or color table.
final class GifStreamIndexer {
  Uint8List _buffer = Uint8List(0);
  int _cursor = 0;
  int _baseOffset = 0;
  int _skipBytes = 0;
  int _width = 0;
  int _height = 0;
  int _frameCount = 0;
  int _completeOffset = 0;
  _GifParseState _state = _GifParseState.header;

  GifStreamIndexSnapshot get snapshot => GifStreamIndexSnapshot(
    width: _width,
    height: _height,
    frameCount: _frameCount,
    completeOffset: _completeOffset,
    trailerSeen: _state == _GifParseState.done,
  );

  void add(Uint8List bytes) {
    if (bytes.isEmpty || _state == _GifParseState.done) return;
    final remaining = _buffer.length - _cursor;
    final next = Uint8List(remaining + bytes.length);
    if (remaining > 0) {
      next.setRange(0, remaining, _buffer, _cursor);
    }
    next.setRange(remaining, next.length, bytes);
    _baseOffset += _cursor;
    _buffer = next;
    _cursor = 0;
    while (_advance()) {}
  }

  bool _advance() {
    switch (_state) {
      case _GifParseState.header:
        if (!_available(6)) return false;
        final gif = _buffer[_cursor] == 0x47 &&
            _buffer[_cursor + 1] == 0x49 &&
            _buffer[_cursor + 2] == 0x46 &&
            _buffer[_cursor + 3] == 0x38 &&
            (_buffer[_cursor + 4] == 0x37 ||
                _buffer[_cursor + 4] == 0x39) &&
            _buffer[_cursor + 5] == 0x61;
        if (!gif) throw const FormatException('Invalid GIF signature');
        _cursor += 6;
        _state = _GifParseState.logicalScreen;
        return true;
      case _GifParseState.logicalScreen:
        if (!_available(7)) return false;
        _width = _uint16(_cursor);
        _height = _uint16(_cursor + 2);
        final packed = _buffer[_cursor + 4];
        _cursor += 7;
        if ((packed & 0x80) != 0) {
          _skipBytes = 3 * (1 << ((packed & 0x07) + 1));
          _state = _GifParseState.globalColorTable;
        } else {
          _state = _GifParseState.block;
        }
        return true;
      case _GifParseState.globalColorTable:
      case _GifParseState.localColorTable:
      case _GifParseState.extensionData:
      case _GifParseState.imageData:
        if (!_available(_skipBytes)) return false;
        _cursor += _skipBytes;
        _state = switch (_state) {
          _GifParseState.globalColorTable => _GifParseState.block,
          _GifParseState.localColorTable => _GifParseState.lzwCodeSize,
          _GifParseState.extensionData => _GifParseState.extensionSize,
          _GifParseState.imageData => _GifParseState.imageDataSize,
          _ => throw StateError('Invalid GIF skip state'),
        };
        return true;
      case _GifParseState.block:
        if (!_available(1)) return false;
        final marker = _buffer[_cursor++];
        if (marker == 0x21) {
          _state = _GifParseState.extensionLabel;
        } else if (marker == 0x2c) {
          _state = _GifParseState.imageDescriptor;
        } else if (marker == 0x3b) {
          _completeOffset = _baseOffset + _cursor;
          _state = _GifParseState.done;
        } else {
          throw FormatException(
            'Invalid GIF block marker 0x${marker.toRadixString(16)}',
          );
        }
        return true;
      case _GifParseState.extensionLabel:
        if (!_available(1)) return false;
        _cursor++;
        _state = _GifParseState.extensionSize;
        return true;
      case _GifParseState.extensionSize:
      case _GifParseState.imageDataSize:
        if (!_available(1)) return false;
        final size = _buffer[_cursor++];
        if (size == 0) {
          if (_state == _GifParseState.imageDataSize) {
            _frameCount++;
            _completeOffset = _baseOffset + _cursor;
          }
          _state = _GifParseState.block;
        } else {
          _skipBytes = size;
          _state = _state == _GifParseState.extensionSize
              ? _GifParseState.extensionData
              : _GifParseState.imageData;
        }
        return true;
      case _GifParseState.imageDescriptor:
        if (!_available(9)) return false;
        final packed = _buffer[_cursor + 8];
        _cursor += 9;
        if ((packed & 0x80) != 0) {
          _skipBytes = 3 * (1 << ((packed & 0x07) + 1));
          _state = _GifParseState.localColorTable;
        } else {
          _state = _GifParseState.lzwCodeSize;
        }
        return true;
      case _GifParseState.lzwCodeSize:
        if (!_available(1)) return false;
        _cursor++;
        _state = _GifParseState.imageDataSize;
        return true;
      case _GifParseState.done:
        return false;
    }
  }

  bool _available(int count) => _buffer.length - _cursor >= count;

  int _uint16(int offset) =>
      _buffer[offset] | (_buffer[offset + 1] << 8);
}
