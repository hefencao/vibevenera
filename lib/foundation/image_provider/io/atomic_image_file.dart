import 'dart:io';
import 'dart:typed_data';

import 'image_data_validator.dart';

File _writeLockFor(File destination) => File('${destination.path}.writing');

/// Reads a cache file only when its image container is complete.
///
/// Corrupt/partial files are deleted so the caller can fall back to network.
Future<Uint8List?> readValidImageFile(
  File file, {
  bool deleteInvalid = true,
  bool allowUnknown = false,
}) async {
  final lock = _writeLockFor(file);
  if (await lock.exists()) {
    // A previous fallback copy either is still running or the process stopped
    // halfway through it. Never expose the destination while this marker is
    // present. Cleaning both files makes the next load redownload safely.
    if (deleteInvalid) {
      try {
        if (await file.exists()) await file.delete();
        await lock.delete();
      } on FileSystemException {
        // Another writer may still own the files.
      }
    }
    return null;
  }
  if (!await file.exists()) return null;

  final validation = await ImageDataValidator.validateFile(
    file,
    allowUnknown: allowUnknown,
  );
  if (!validation.valid) {
    if (deleteInvalid) {
      try {
        await file.delete();
      } on FileSystemException {
        // A concurrent reader/writer may own the file. The invalid result is
        // still ignored; the next load can retry deletion.
      }
    }
    return null;
  }
  return file.readAsBytes();
}

/// Writes image bytes without exposing a partial final cache file.
///
/// The temporary file lives in the destination directory so rename is atomic
/// on normal file systems. If a document provider does not support rename, a
/// `.writing` marker prevents this loader from consuming the fallback copy.
Future<void> writeImageBytesAtomically(
  File destination,
  Uint8List bytes, {
  bool allowUnknown = false,
}) async {
  final memoryValidation = ImageDataValidator.validateBytes(
    bytes,
    allowUnknown: allowUnknown,
  );
  if (!memoryValidation.valid) {
    throw InvalidImageDataException(memoryValidation.reason);
  }

  await destination.parent.create(recursive: true);
  final temp = File(
    '${destination.path}.tmp.${pid}.${DateTime.now().microsecondsSinceEpoch}',
  );
  final lock = _writeLockFor(destination);

  try {
    await temp.writeAsBytes(bytes, flush: true);
    final diskValidation = await ImageDataValidator.validateFile(
      temp,
      allowUnknown: allowUnknown,
    );
    if (!diskValidation.valid) {
      throw InvalidImageDataException(
        'temporary cache validation failed: ${diskValidation.reason}',
      );
    }

    try {
      if (await destination.exists()) await destination.delete();
      await temp.rename(destination.path);
    } on FileSystemException {
      // Some Android document providers do not implement rename. Keep a
      // marker for readers until the fully validated temporary file is copied.
      await lock.writeAsString('writing', flush: true);
      try {
        if (await temp.exists()) {
          await temp.copy(destination.path);
        }
        final finalValidation = await ImageDataValidator.validateFile(
          destination,
          allowUnknown: allowUnknown,
        );
        if (!finalValidation.valid) {
          if (await destination.exists()) await destination.delete();
          throw InvalidImageDataException(
            'final cache validation failed: ${finalValidation.reason}',
          );
        }
      } finally {
        if (await lock.exists()) await lock.delete();
      }
    }
  } finally {
    if (await temp.exists()) {
      try {
        await temp.delete();
      } on FileSystemException {
        // Best effort cleanup.
      }
    }
  }
}
