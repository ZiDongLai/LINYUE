// Opt-in 256 MiB maximum pilot-size full encrypted E2E test.
// flutter test qa/dev12b1_256m_boundary_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'dev12b1_soak_helper.dart';

void main() {
  test('exact 256MiB AES-GCM stream succeeds with persisted SHA-256', () async {
    expect(secureStreamPilotMaxBytes, greaterThanOrEqualTo(256 * mib));
    final fixture = await SoakFixture.create();
    final timings = <Duration>[];
    final memory = SoakMemorySampler();
    try {
      await fixture.sendAndVerify(256 * mib,
        'exact_256_mib.bin', memory: memory, timings: timings);
      expect(fixture.consentCount, 1);
      print('[DEV12-B1] MAX PILOT SIZE verified; ${memory.report}');
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 35)));

  test('current stream maximum + 1 byte fails before network handshake', () async {
    final fixture = await SoakFixture.create();
    try {
      // Sparse file: no payload allocation required for negative test.
      final source = File('${fixture.temp.path}${Platform.pathSeparator}too_large.bin');
      final fd = await source.open(mode: FileMode.writeOnly);
      try { await fd.truncate(secureStreamPilotMaxBytes + 1); }
      finally { await fd.close(); }
      final count = fixture.sender.handshakeCount;
      await expectLater(fixture.sender.sendStreamFile(ip: '127.0.0.1',
        port: fixture.receiver.boundPort!,
        remoteFingerprint: fixture.recipientIdentity.local.fingerprint,
        file: source), throwsA(isA<StateError>()));
      expect(fixture.sender.handshakeCount, count,
        reason: 'oversized file must not even attempt a handshake');
      expect(fixture.consentCount, 0);
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
