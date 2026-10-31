// DEV12-C1 FIX1 regression. Loopback only; production file cap is unchanged.
// Demonstrates that a large resumable transfer cannot leave a cached session
// that the small-file sender later mistakes for an authenticated live session.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/transfer_progress.dart';
import 'dev12b1_soak_helper.dart';

void main() {
  test('stream completion rotates session before buffered small-file send', () async {
    final fixture = await SoakFixture.create();
    try {
      final memory = SoakMemorySampler();
      final timings = <Duration>[];
      // Minimum size that triggers the production streaming path.
      await fixture.sendAndVerify(20 * mib + 1, 'rotation_large.bin',
        memory: memory, timings: timings);
      final handshakesAfterStream = fixture.sender.handshakeCount;
      expect(handshakesAfterStream, greaterThanOrEqualTo(1));
      final small = await createDeterministicFile(
        fixture.temp, 'rotation_small.bin', 4097);
      final originalHash = await streamSha256(small);
      final saved = File('${fixture.temp.path}${Platform.pathSeparator}'
        'received${Platform.pathSeparator}rotation_small.bin');
      final phases = <TransferProgressPhase>[];
      await fixture.sender.sendFile(
        ip: '127.0.0.1', port: fixture.receiver.boundPort!,
        remoteFingerprint: fixture.recipientIdentity.local.fingerprint,
        file: small,
        onProgress: (progress) => phases.add(progress.phase),
      );
      expect(fixture.sender.handshakeCount, handshakesAfterStream + 1,
        reason: 'a fresh signed session is mandatory after a streamed file');
      expect(fixture.consentCount, 2,
        reason: 'both independent files need receiver approval');
      expect(await saved.exists(), isTrue);
      expect(await streamSha256(saved), originalHash);
      expect(phases, isNotEmpty);
      expect(phases.last, TransferProgressPhase.completed);
      print('[DEV12-C1 FIX1] SESSION_ROTATION_PASS '
        'new_handshake=true consents=2 sha256_verified=true');
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
