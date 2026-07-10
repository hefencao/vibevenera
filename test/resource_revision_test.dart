import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/pipeline/resource_entry.dart';

void main() {
  test('decode policy changes do not invalidate network execution', () {
    final entry = ResourceEntry(
      imageKey: 'image',
      fullKey: 'image@100x100',
      cid: 'cid',
      eid: 'eid',
    );
    entry.updatePolicy(const ResourcePolicy(
      allowDownload: true,
      allowDecode: true,
      allowGpuUpload: true,
    ));
    final context = ExecutionContext(entry);

    entry.updatePolicy(const ResourcePolicy(
      allowDownload: true,
      allowDecode: false,
      allowGpuUpload: false,
    ));

    expect(context.downloadAllowed, isTrue);
    expect(context.decodeAllowed, isFalse);
  });
}
