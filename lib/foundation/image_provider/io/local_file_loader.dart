import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:venera/foundation/log.dart';

/// Handles both `file://` protocol paths and direct file paths.
/// Delegates to `File()` — on Android, `_IOOverrides.createFile`
/// transparently handles SAF paths.
///
/// Returns null if not a local file, needs network loading.
///
/// For files larger than 1MB, use Isolate.run to avoid blocking
/// the main isolate during synchronous filesystem work.
Future<Uint8List?> tryLoadLocalFile(String imageKey) async {
  if (imageKey.contains('://') && !imageKey.startsWith('file://')) return null;

  try {
    final file = File(imageKey);
    if (!await file.exists()) return null;

    final fileSize = await file.length();
    final isFileScheme = imageKey.startsWith('file://');

    if (fileSize > 1024 * 1024 && !isFileScheme) {
      final path = file.path;
      return await Isolate.run(() => File(path).readAsBytesSync());
    }
    return await file.readAsBytes();
  } catch (e) {
    Log.error('Local file load failed for $imageKey', e);
    return null;
  }
}