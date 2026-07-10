import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:venera/foundation/log.dart';

/// Handles both `file://` protocol paths and direct file paths.
/// Delegates to `File()` — on Android, `_IOOverrides.createFile`
/// transparently handles SAF paths.
///
/// IMPORTANT: the file:// prefix is intentionally preserved. IOOverride owns
/// its interpretation; converting it to a URI/path here can break SAF access.
Future<Uint8List?> tryLoadLocalFile(String imageKey) async {
  if (imageKey.contains('://') && !imageKey.startsWith('file://')) return null;

  try {
    final file = File(imageKey);
    if (!await file.exists()) return null;

    final fileSize = await file.length();
    final isFileScheme = imageKey.startsWith('file://');

    if (fileSize > 1024 * 1024 && !isFileScheme) {
      final path = file.path;
      return Isolate.run(() => File(path).readAsBytesSync());
    }
    return file.readAsBytes();
  } catch (error, stackTrace) {
    Log.error('Local file load failed for $imageKey', error, stackTrace);
    return null;
  }
}
