// DEV12-C1 completion-ack-loss simulation using an identical stable task ID.
// Localhost only; verifies signed re-authentication, idempotent completion,
// and rejection if the already-saved file was subsequently corrupted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'dev12b1_soak_helper.dart';

void main() {
  test('re-sending completed task returns valid completion without duplicate', () async {
    final fixture = await SoakFixture.create();
    try {
      final source = await createDeterministicFile(
        fixture.temp, 'stable_task.bin', 24 * mib + 33);
      final hash = await streamSha256(source);
      final taskId = List<String>.filled(32, 'c').join();
      final saved = File('${fixture.temp.path}${Platform.pathSeparator}'
        'received${Platform.pathSeparator}stable_task.bin');

      Future<void> sendSameTask() => fixture.sender.sendStreamFile(
        ip: '127.0.0.1', port: fixture.receiver.boundPort!,
        remoteFingerprint: fixture.recipientIdentity.local.fingerprint,
        file: source, resumeTaskId: taskId, expectedSha256: hash);

      await sendSameTask();
      expect(await saved.exists(), isTrue);
      expect(await streamSha256(saved), hash);
      expect(fixture.consentCount, 1);

      // A second upload of this SAME task models a lost final ACK. It must
      // re-authenticate, re-check the saved file, and avoid creating a copy.
      await sendSameTask();
      expect(fixture.sender.handshakeCount, 2);
      expect(fixture.consentCount, 1,
        reason: 'a verified completed task must not request fresh consent');
      final folder = saved.parent;
      final savedCopies = await folder.list(followLinks: false)
        .where((e) => e is File && e.uri.pathSegments.last.startsWith('stable_task'))
        .toList();
      expect(savedCopies, hasLength(1),
        reason: 'lost final ACK must not produce a duplicate file');
      expect(await streamSha256(saved), hash);
      print('[DEV12-C1] ACK_LOSS_PASS reauth=2 duplicates=0 sha256_verified=true');
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('tampered saved file must never receive a successful completed receipt', () async {
    final fixture = await SoakFixture.create();
    try {
      final source = await createDeterministicFile(
        fixture.temp, 'tamper_case.bin', 24 * mib + 91);
      final digest = await streamSha256(source);
      final taskId = List<String>.filled(32, 'd').join();
      final target = File('${fixture.temp.path}${Platform.pathSeparator}'
        'received${Platform.pathSeparator}tamper_case.bin');
      Future<void> send() => fixture.sender.sendStreamFile(
        ip: '127.0.0.1', port: fixture.receiver.boundPort!,
        remoteFingerprint: fixture.recipientIdentity.local.fingerprint,
        file: source, resumeTaskId: taskId, expectedSha256: digest);
      await send();
      expect(await streamSha256(target), digest);
      final bytes = await target.readAsBytes();
      bytes[0] ^= 1;
      await target.writeAsBytes(bytes, flush: true);
      expect(await streamSha256(target), isNot(digest));
      await expectLater(send(), throwsA(anything),
        reason: 'disk-tampered receipt must never authenticate as complete');
      expect(fixture.consentCount, 1);
      print('[DEV12-C1] TAMPER_REJECT_PASS prior_complete_not_trusted=true');
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
