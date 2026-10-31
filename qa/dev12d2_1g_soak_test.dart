// DEV12-D2: manual 1 GiB full encrypted network soak. NOT part of flutter test.
// Requires local temp volume with > 3 GiB free, and potentially a long run.
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'dev12b1_soak_helper.dart';

void main() {
  test('exactly 1 GiB V2 AES-GCM streamed file is SHA-256 identical', () async {
    expect(secureStreamPilotMaxBytes, 1024 * mib);
    final fixture = await SoakFixture.create();
    final timings = <Duration>[];
    final memory = SoakMemorySampler();
    try {
      await fixture.sendAndVerify(1024 * mib, 'dev12d2_exact_1g.bin',
          memory: memory, timings: timings);
      expect(fixture.consentCount, 1);
      print('[DEV12-D2] ONE_GIB_PASS elapsed_ms=${timings.single.inMilliseconds} '
          '${memory.report}');
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(hours: 3)));
}
