// Opt-in network soak: flutter test qa/dev12b1_repeated_soak_test.dart
// Two full authenticated AES-GCM streams of 96MiB and 160MiB+7B.
import 'package:flutter_test/flutter_test.dart';
import 'dev12b1_soak_helper.dart';

void main() {
  test('repeated independent file transfers preserve integrity and consent', () async {
    final fixture = await SoakFixture.create();
    final memory = SoakMemorySampler();
    final timings = <Duration>[];
    try {
      await fixture.sendAndVerify(96 * mib, 'stability_096.bin',
        memory: memory, timings: timings);
      await fixture.sendAndVerify(160 * mib + 7, 'stability_160.bin',
        memory: memory, timings: timings);
      expect(fixture.consentCount, 2, reason: 'receiver still approves each new file');
      expect(fixture.sender.handshakeCount, 2,
        reason: 'resumable transfers use new signed authenticated sessions');
      expect(timings, hasLength(2));
      print('[DEV12-B1] TWO sequential encrypted uploads completed; ${memory.report}');
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 35)));
}
