import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';

import 'app.dart';
import 'app_page_route.dart';

extension Navigation on BuildContext {
  void pop<T>([T? result]) {
    if(mounted) {
      Navigator.of(this).pop(result);
    }
  }

  bool canPop() {
    return Navigator.of(this).canPop();
  }

  Future<T?> to<T>(
    Widget Function() builder, {
    Duration? transitionDuration,
    Duration? reverseTransitionDuration,
    bool allowSnapshotting = true,
    bool hideNavigationInLandscape = false,
  }) {
    final navigator = Navigator.of(this);
    return navigator.push<T>(AppPageRoute(
      builder: (context) => builder(),
      transitionDurationOverride: transitionDuration,
      reverseTransitionDurationOverride: reverseTransitionDuration,
      allowSnapshotting: allowSnapshotting,
      managedPredictiveBack:
          identical(navigator, App.mainNavigatorKey?.currentState),
      hideNavigationInLandscape: hideNavigationInLandscape,
    ));
  }

  Future<void> toReplacement<T>(Widget Function() builder) {
    final navigator = Navigator.of(this);
    return navigator.pushReplacement(AppPageRoute(
      builder: (context) => builder(),
      managedPredictiveBack:
          identical(navigator, App.mainNavigatorKey?.currentState),
    ));
  }

  double get width => MediaQuery.of(this).size.width;

  double get height => MediaQuery.of(this).size.height;

  EdgeInsets get padding => MediaQuery.of(this).padding;

  EdgeInsets get viewInsets => MediaQuery.of(this).viewInsets;

  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  Brightness get brightness => Theme.of(this).brightness;

  bool get isDarkMode => brightness == Brightness.dark;

  void showMessage({required String message}) {
    showToast(message: message, context: this);
  }

  Color useBackgroundColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 100 : 800]!;
  }

  Color useTextColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 800 : 100]!;
  }
}
