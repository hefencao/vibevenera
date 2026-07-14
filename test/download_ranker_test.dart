import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/download_ranker.dart';
import 'package:venera/foundation/image_provider/pipeline/resource_entry.dart';

void main() {
  test('next page ranks above previous page in both reading directions', () {
    final entry = ResourceEntry(
      imageKey: 'page',
      fullKey: 'page@100x100',
      cid: 'comic',
      eid: 'episode',
    )..updatePriority(PagePriority.near);

    int rank(int offset, int direction) => DownloadRanker(
      runningDownloads: 0,
      queuedDownloads: 0,
      maxConcurrent: 3,
      readDirection: direction,
      offsetFor: (_) => offset,
    ).rank(entry);

    expect(rank(1, 1), greaterThan(rank(-1, 1)));
    expect(rank(-1, -1), greaterThan(rank(1, -1)));
    expect(rank(1, 1), rank(-1, -1));
  });
}
