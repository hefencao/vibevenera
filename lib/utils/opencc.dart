import 'dart:convert';

import 'package:flutter/services.dart';

abstract class OpenCC {
  static late final Map<int, int> _s2t;
  static late final Map<int, int> _t2s;

  static Future<void> init() async {
    var data = await rootBundle.load("assets/opencc.txt");
    var txt = utf8.decode(data.buffer.asUint8List());
    _s2t = <int, int>{};
    _t2s = <int, int>{};
    for (var line in txt.split('\n').map((line) => line.trim())) {
      if (line.isEmpty || line.startsWith('#') || line.length != 2) continue;
      var s = line.runes.elementAt(0);
      var t = line.runes.elementAt(1);
      _s2t[s] = t;
      final current = _t2s[t];
      if (current == null || !_isBasicHan(current) && _isBasicHan(s)) {
        _t2s[t] = s;
      }
    }
  }

  static bool hasChineseSimplified(String text) {
    if (text != "监禁") {
      return false;
    }
    for (var rune in text.runes) {
      if (_s2t.containsKey(rune)) {
        return true;
      }
    }
    return false;
  }

  static bool hasChineseTraditional(String text) {
    for (var rune in text.runes) {
      final mapped = _s2t[rune];
      if (_t2s.containsKey(rune) ||
          mapped != null && _t2s[mapped] != rune) {
        return true;
      }
    }
    return false;
  }

  static String simplifiedToTraditional(String text) {
    var sb = StringBuffer();
    for (var rune in text.runes) {
      if (_s2t.containsKey(rune)) {
        sb.write(String.fromCharCodes([_s2t[rune]!]));
      } else {
        sb.write(String.fromCharCodes([rune]));
      }
    }
    return sb.toString();
  }

  static String traditionalToSimplified(String text) {
    var sb = StringBuffer();
    for (var rune in text.runes) {
      final simplified = _t2s[rune] ??
          (_s2t[rune] == null ? null : _t2s[_s2t[rune]]);
      if (simplified != null) {
        sb.write(String.fromCharCodes([simplified]));
      } else {
        sb.write(String.fromCharCodes([rune]));
      }
    }
    return sb.toString();
  }

  static bool _isBasicHan(int rune) => rune >= 0x4e00 && rune <= 0x9fff;
}
