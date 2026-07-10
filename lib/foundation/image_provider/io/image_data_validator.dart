import 'dart:io';
import 'dart:typed_data';

enum ImageDataFormat { jpeg, png, gif, webp, bmp, avif, unknown }

final class ImageDataValidation {
  final bool valid;
  final ImageDataFormat format;
  final String reason;
  final int? declaredLength;

  const ImageDataValidation._({
    required this.valid,
    required this.format,
    required this.reason,
    this.declaredLength,
  });

  const ImageDataValidation.valid(ImageDataFormat format, {int? declaredLength})
    : this._(
        valid: true,
        format: format,
        reason: '',
        declaredLength: declaredLength,
      );

  const ImageDataValidation.invalid(
    String reason, {
    ImageDataFormat format = ImageDataFormat.unknown,
    int? declaredLength,
  }) : this._(
         valid: false,
         format: format,
         reason: reason,
         declaredLength: declaredLength,
       );
}

final class InvalidImageDataException implements Exception {
  final String message;

  const InvalidImageDataException(this.message);

  @override
  String toString() => 'Invalid image data: $message';
}

/// Lightweight integrity validation used before a downloaded file becomes a
/// reusable cache entry.
///
/// This deliberately does not decode pixels. It verifies the container magic
/// and the completion marker/declared size for the formats used by the app.
abstract final class ImageDataValidator {
  /// Returns the full RIFF length declared by a WEBP header, or null when the
  /// prefix is not a complete RIFF/WEBP header.
  static int? webPDeclaredLength(Uint8List prefix) {
    if (prefix.length < 12 ||
        !_startsWithAscii(prefix, 'RIFF') ||
        !_asciiAt(prefix, 8, 'WEBP')) {
      return null;
    }
    final value = _uint32Le(prefix, 4) + 8;
    return value >= 12 ? value : null;
  }

  static Future<ImageDataValidation> validateFile(
    File file, {
    bool allowUnknown = false,
  }) async {
    if (!await file.exists()) {
      return const ImageDataValidation.invalid('file does not exist');
    }
    final length = await file.length();
    if (length <= 0) {
      return const ImageDataValidation.invalid('empty file');
    }

    final raf = await file.open(mode: FileMode.read);
    try {
      final prefixLength = length < 64 ? length : 64;
      final prefix = await raf.read(prefixLength);
      final suffixLength = length < 32 ? length : 32;
      await raf.setPosition(length - suffixLength);
      final suffix = await raf.read(suffixLength);
      return _validateSegments(
        prefix: prefix,
        suffix: suffix,
        totalLength: length,
        allowUnknown: allowUnknown,
      );
    } finally {
      await raf.close();
    }
  }

  static ImageDataValidation validateBytes(
    Uint8List bytes, {
    bool allowUnknown = false,
  }) {
    if (bytes.isEmpty) {
      return const ImageDataValidation.invalid('empty bytes');
    }
    final prefixLength = bytes.length < 64 ? bytes.length : 64;
    final suffixLength = bytes.length < 32 ? bytes.length : 32;
    return _validateSegments(
      prefix: Uint8List.sublistView(bytes, 0, prefixLength),
      suffix: Uint8List.sublistView(
        bytes,
        bytes.length - suffixLength,
        bytes.length,
      ),
      totalLength: bytes.length,
      allowUnknown: allowUnknown,
    );
  }

  static ImageDataValidation _validateSegments({
    required Uint8List prefix,
    required Uint8List suffix,
    required int totalLength,
    required bool allowUnknown,
  }) {
    if (_startsWith(prefix, const [0xff, 0xd8])) {
      if (!_contains(suffix, const [0xff, 0xd9])) {
        return const ImageDataValidation.invalid(
          'JPEG end marker is missing',
          format: ImageDataFormat.jpeg,
        );
      }
      return const ImageDataValidation.valid(ImageDataFormat.jpeg);
    }

    if (_startsWith(prefix, const [
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ])) {
      if (!_endsWith(suffix, const [
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4e,
        0x44,
        0xae,
        0x42,
        0x60,
        0x82,
      ])) {
        return const ImageDataValidation.invalid(
          'PNG IEND chunk is missing',
          format: ImageDataFormat.png,
        );
      }
      return const ImageDataValidation.valid(ImageDataFormat.png);
    }

    if (_startsWithAscii(prefix, 'GIF87a') ||
        _startsWithAscii(prefix, 'GIF89a')) {
      if (!_contains(suffix, const [0x3b])) {
        return const ImageDataValidation.invalid(
          'GIF trailer is missing',
          format: ImageDataFormat.gif,
        );
      }
      return const ImageDataValidation.valid(ImageDataFormat.gif);
    }

    if (prefix.length >= 12 &&
        _startsWithAscii(prefix, 'RIFF') &&
        _asciiAt(prefix, 8, 'WEBP')) {
      final declaredLength = webPDeclaredLength(prefix) ?? 0;
      if (declaredLength < 12) {
        return ImageDataValidation.invalid(
          'invalid WebP RIFF length $declaredLength',
          format: ImageDataFormat.webp,
          declaredLength: declaredLength,
        );
      }
      if (declaredLength != totalLength) {
        return ImageDataValidation.invalid(
          'incomplete WebP: file=$totalLength, RIFF=$declaredLength',
          format: ImageDataFormat.webp,
          declaredLength: declaredLength,
        );
      }
      return ImageDataValidation.valid(
        ImageDataFormat.webp,
        declaredLength: declaredLength,
      );
    }

    if (_startsWithAscii(prefix, 'BM')) {
      if (prefix.length < 6) {
        return const ImageDataValidation.invalid(
          'BMP header is truncated',
          format: ImageDataFormat.bmp,
        );
      }
      final declaredLength = _uint32Le(prefix, 2);
      if (declaredLength > 0 && declaredLength != totalLength) {
        return ImageDataValidation.invalid(
          'incomplete BMP: file=$totalLength, header=$declaredLength',
          format: ImageDataFormat.bmp,
          declaredLength: declaredLength,
        );
      }
      return ImageDataValidation.valid(
        ImageDataFormat.bmp,
        declaredLength: declaredLength > 0 ? declaredLength : null,
      );
    }

    if (_looksLikeAvif(prefix)) {
      if (totalLength < 24) {
        return const ImageDataValidation.invalid(
          'AVIF/HEIF file is too short',
          format: ImageDataFormat.avif,
        );
      }
      return const ImageDataValidation.valid(ImageDataFormat.avif);
    }

    if (_looksLikeTextResponse(prefix)) {
      return const ImageDataValidation.invalid(
        'response looks like HTML/JSON/text rather than an image',
      );
    }

    return allowUnknown
        ? const ImageDataValidation.valid(ImageDataFormat.unknown)
        : const ImageDataValidation.invalid('unsupported image signature');
  }

  static bool _looksLikeAvif(Uint8List bytes) {
    if (bytes.length < 12 || !_asciiAt(bytes, 4, 'ftyp')) return false;
    const brands = ['avif', 'avis', 'heic', 'heix', 'mif1', 'msf1'];
    for (final brand in brands) {
      if (_asciiAt(bytes, 8, brand)) return true;
    }
    return false;
  }

  static bool _looksLikeTextResponse(Uint8List bytes) {
    var index = 0;
    while (index < bytes.length &&
        (bytes[index] == 0x20 ||
            bytes[index] == 0x09 ||
            bytes[index] == 0x0a ||
            bytes[index] == 0x0d)) {
      index++;
    }
    if (index >= bytes.length) return true;
    final first = bytes[index];
    if (first == 0x3c || first == 0x7b || first == 0x5b) return true;

    final count = bytes.length < 32 ? bytes.length : 32;
    var printable = 0;
    for (var i = 0; i < count; i++) {
      final value = bytes[i];
      if (value == 0x09 ||
          value == 0x0a ||
          value == 0x0d ||
          (value >= 0x20 && value <= 0x7e)) {
        printable++;
      }
    }
    return count >= 12 && printable * 100 ~/ count >= 95;
  }

  static int _uint32Le(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _contains(Uint8List bytes, List<int> needle) {
    if (needle.isEmpty) return true;
    if (bytes.length < needle.length) return false;
    for (var start = 0; start <= bytes.length - needle.length; start++) {
      var matches = true;
      for (var i = 0; i < needle.length; i++) {
        if (bytes[start + i] != needle[i]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  static bool _endsWith(Uint8List bytes, List<int> suffix) {
    if (bytes.length < suffix.length) return false;
    final start = bytes.length - suffix.length;
    for (var i = 0; i < suffix.length; i++) {
      if (bytes[start + i] != suffix[i]) return false;
    }
    return true;
  }

  static bool _startsWithAscii(Uint8List bytes, String value) =>
      _asciiAt(bytes, 0, value);

  static bool _asciiAt(Uint8List bytes, int offset, String value) {
    if (offset < 0 || offset + value.length > bytes.length) return false;
    for (var i = 0; i < value.length; i++) {
      if (bytes[offset + i] != value.codeUnitAt(i)) return false;
    }
    return true;
  }
}
