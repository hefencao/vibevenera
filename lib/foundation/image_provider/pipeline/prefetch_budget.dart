import 'dart:io';

import 'resource_entry.dart';
import 'resource_manager.dart';

class PrefetchBudget {
  static const int mobileBudgetBytes = 48 * 1024 * 1024;
  static const int desktopBudgetBytes = 192 * 1024 * 1024;
  static const int mobileUnknownBytes = 16 * 1024 * 1024;
  static const int desktopUnknownBytes = 32 * 1024 * 1024;

  const PrefetchBudget();

  bool exceededFor(ResourceEntry entry, ResourceManager resources) {
    if (entry.priority == PagePriority.current ||
        entry.priority == PagePriority.near) {
      return false;
    }
    final knownSize = entry.bytes?.length ?? entry.download.totalBytes;
    final budget = budgetBytes;
    if (knownSize != null && knownSize >= budget ~/ 2) {
      return currentBytes(resources, excluding: entry.imageKey) > 0;
    }
    return currentBytes(resources) >= budget;
  }

  int currentBytes(ResourceManager resources, {String? excluding}) {
    var total = 0;
    resources.forEach((entry) {
      if (entry.imageKey == excluding) return;
      if (entry.priority == PagePriority.current ||
          entry.priority == PagePriority.near) {
        return;
      }
      total +=
          entry.bytes?.length ??
          entry.download.totalBytes ??
          (entry.download.inProgress ? unknownBytes : 0);
    });
    return total;
  }

  int get budgetBytes {
    if (Platform.isAndroid || Platform.isIOS) return mobileBudgetBytes;
    return desktopBudgetBytes;
  }

  int get unknownBytes {
    if (Platform.isAndroid || Platform.isIOS) return mobileUnknownBytes;
    return desktopUnknownBytes;
  }
}