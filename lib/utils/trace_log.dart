import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

class TraceLog {
  static const _tag = 'Venera';

  static void info(String name, String message) => _write(4, name, message);
  static void warning(String name, String message) => _write(5, name, message);
  static void error(
    String name,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final text = error == null ? message : '$message: $error';
    _write(6, name, stackTrace == null ? text : '$text\n$stackTrace');
  }

  static void _write(int priority, String name, String message) {
    final text = '[$name] $message';
    if (Platform.isAndroid) {
      _AndroidLog.write(priority, _tag, text);
    } else {
      developer.log(text, name: _tag, level: priority * 100);
    }
  }
}

typedef _AndroidLogWriteNative = Int32 Function(
  Int32 priority,
  Pointer<Utf8> tag,
  Pointer<Utf8> text,
);
typedef _AndroidLogWriteDart = int Function(
  int priority,
  Pointer<Utf8> tag,
  Pointer<Utf8> text,
);

class _AndroidLog {
  static final _AndroidLogWriteDart _write = DynamicLibrary.open('liblog.so')
      .lookupFunction<_AndroidLogWriteNative, _AndroidLogWriteDart>(
        '__android_log_write',
      );

  static void write(int priority, String tag, String text) {
    final tagPtr = tag.toNativeUtf8();
    final textPtr = text.toNativeUtf8();
    try {
      _write(priority, tagPtr, textPtr);
    } finally {
      calloc.free(tagPtr);
      calloc.free(textPtr);
    }
  }
}
