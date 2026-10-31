// DEV12-B2 manually opted-in 512 MiB encrypted network boundary test.
// Run: flutter test qa/dev12b2_512m_boundary_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'dev12b1_soak_helper.dart';

void main() {
  test('exact 512MiB full AES-GCM stream persists with identical SHA-256', () async {
    expect(secureStreamPilotMaxBytes, greaterThanOrEqualTo(512 * mib));
    final fixture = await SoakFixture.create();
    final durations = <Duration>[];
    final memory = SoakMemorySampler();
    try {
      await fixture.sendAndVerify(secureStreamPilotMaxBytes,
          'exact_512_mib.bin', memory: memory, timings: durations);
      expect(fixture.consentCount, 1);
      expect(fixture.sender.handshakeCount, 1);
      print('[DEV12-B2] 512MiB verified. ${memory.report}');
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 50)));

  test('1GiB+1B is rejected before network authentication', () async {
    final fixture = await SoakFixture.create();
    try {
      final tooLarge = File('${fixture.temp.path}${Platform.pathSeparator}too_large.bin');
      final handle = await tooLarge.open(mode: FileMode.writeOnly);
      try {
        await handle.truncate(secureStreamPilotMaxBytes + 1);
      } finally {
        await handle.close();
      }
      final before = fixture.sender.handshakeCount;
      await expectLater(fixture.sender.sendStreamFile(
        ip: '127.0.0.1', port: fixture.receiver.boundPort!,
        remoteFingerprint: fixture.recipientIdentity.local.fingerprint,
        file: tooLarge,
      ), throwsA(isA<StateError>()));
      expect(fixture.sender.handshakeCount, before);
      expect(fixture.consentCount, 0);
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
