// DEV12-C1 opt-in prolonged authenticated AES-GCM loopback regression.
// Keeps the 512 MiB production cap and 1280 MiB staging quota unchanged.
// Run alone: flutter test qa/dev12c1_long_run_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'package:nearlink/services/transfer_progress.dart';
import 'dev12b1_soak_helper.dart';

void main() {
  test('192+416+480 MiB encrypted uploads followed by small-file transfer', () async {
    expect(secureStreamPilotMaxBytes, 512 * mib);
    final fixture = await SoakFixture.create();
    final durations = <Duration>[];
    final readings = <String>[];
    final totalWatch = Stopwatch()..start();
    try {
      for (final sizeMiB in <int>[192, 416, 480]) {
        final sampler = SoakMemorySampler();
        final filename = 'dev12c1_${sizeMiB}m.bin';
        await fixture.sendAndVerify(sizeMiB * mib, filename,
          memory: sampler, timings: durations);
        readings.add('$sizeMiB MiB: ${sampler.report}');
        expect(fixture.consentCount, durations.length,
          reason: 'each independent large-file task must be approved once');
        expect(fixture.sender.handshakeCount, durations.length,
          reason: 'resumable transfers require a new authenticated session');
      }
      // Regression: the legacy small encrypted-file route must still work
      // immediately after hours of authenticated chunked uploads.
      final source = await createDeterministicFile(
        fixture.temp, 'dev12c1_small_after_large.bin', 2 * mib + 19);
      final expected = await streamSha256(source);
      final received = File('${fixture.temp.path}${Platform.pathSeparator}'
        'received${Platform.pathSeparator}dev12c1_small_after_large.bin');
      final phases = <TransferProgressPhase>[];
      await fixture.sender.sendFile(
        ip: '127.0.0.1', port: fixture.receiver.boundPort!,
        remoteFingerprint: fixture.recipientIdentity.local.fingerprint,
        file: source,
        onProgress: (p) => phases.add(p.phase),
      );
      expect(await received.exists(), isTrue);
      expect(await received.length(), await source.length());
      expect(await streamSha256(received), expected);
      expect(phases.last, TransferProgressPhase.completed);
      expect(fixture.consentCount, 4);
      totalWatch.stop();
      final totalMiB = 192 + 416 + 480;
      print('[DEV12-C1] LONG_RUN_PASS large_files=3 small_file=1 '
        'total_large=$totalMiB MiB elapsed=${totalWatch.elapsed} '
        'encrypted_handshakes=${fixture.sender.handshakeCount} '
        'receiver_consents=${fixture.consentCount}');
      for (final line in readings) {
        print('[DEV12-C1] MEM_SAMPLE $line');
      }
      print('[DEV12-C1] RSS is only the local test process; '
        'it is not the Android device peak RAM.');
    } finally {
      totalWatch.stop();
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 100)));
}
