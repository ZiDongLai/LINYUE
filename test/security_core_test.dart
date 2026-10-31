import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_core.dart';

void main() {
  test('Ed25519 identities, authenticated X25519 and AES-GCM roundtrip', () async {
    final alice = await DevIdentity.generate();
    final bob = await DevIdentity.generate();
    final ae = await DevEphemeral.generate();
    final be = await DevEphemeral.generate();
    final transcript = SecureTranscript(
      initiatorIdentity: alice.publicKey,
      responderIdentity: bob.publicKey,
      initiatorEphemeral: ae.publicKey,
      responderEphemeral: be.publicKey,
      sessionNonce: secureRandomBytes(16),
    );
    final aliceSignature = await alice.sign(transcript.bytes);
    final bobSignature = await bob.sign(transcript.bytes);

    final aliceKeys = await deriveAuthenticatedKeys(
      role: SecureRole.initiator,
      transcript: transcript,
      localIdentity: alice,
      localEphemeral: ae,
      remoteIdentity: bob.publicKey,
      remoteEphemeral: be.publicKey,
      remoteSignature: bobSignature,
      expectedRemoteFingerprint: bob.fingerprint,
    );
    final bobKeys = await deriveAuthenticatedKeys(
      role: SecureRole.responder,
      transcript: transcript,
      localIdentity: bob,
      localEphemeral: be,
      remoteIdentity: alice.publicKey,
      remoteEphemeral: ae.publicKey,
      remoteSignature: aliceSignature,
      expectedRemoteFingerprint: alice.fingerprint,
    );
    expect(await aliceKeys.send.extractBytes(), await bobKeys.receive.extractBytes());
    expect(await aliceKeys.receive.extractBytes(), await bobKeys.send.extractBytes());
    expect(await aliceKeys.send.extractBytes(), isNot(await aliceKeys.receive.extractBytes()));

    final frame = await encryptFrame(
      session: aliceKeys,
      direction: 'initiator-to-responder',
      sequence: 0,
      plainText: utf8.encode('邻跃：加密核心离线自检'),
    );
    expect(frame.cipherText, isNot(utf8.encode('邻跃：加密核心离线自检')));
    expect(
      await decryptFrame(
        session: bobKeys,
        direction: 'initiator-to-responder',
        sequence: 0,
        frame: frame,
      ),
      utf8.encode('邻跃：加密核心离线自检'),
    );
    // Ciphertext tampering, sequence manipulation and spoofed fingerprint fail.
    final damagedBytes = <int>[...frame.cipherText];
    damagedBytes[0] ^= 1;
    final damaged = EncryptedFrame(
      nonce: frame.nonce,
      cipherText: damagedBytes,
      mac: frame.mac,
    );
    await expectLater(
      decryptFrame(
        session: bobKeys,
        direction: 'initiator-to-responder',
        sequence: 0,
        frame: damaged,
      ),
      throwsA(anything),
    );
    await expectLater(
      decryptFrame(
        session: bobKeys,
        direction: 'initiator-to-responder',
        sequence: 1,
        frame: frame,
      ),
      throwsA(anything),
    );
    await expectLater(
      deriveAuthenticatedKeys(
        role: SecureRole.initiator,
        transcript: transcript,
        localIdentity: alice,
        localEphemeral: ae,
        remoteIdentity: bob.publicKey,
        remoteEphemeral: be.publicKey,
        remoteSignature: bobSignature,
        expectedRemoteFingerprint: alice.fingerprint,
      ),
      throwsStateError,
    );
  });

  test('A changed signed transcript is rejected', () async {
    final alice = await DevIdentity.generate();
    final bob = await DevIdentity.generate();
    final ae = await DevEphemeral.generate();
    final be = await DevEphemeral.generate();
    final one = SecureTranscript(
      initiatorIdentity: alice.publicKey,
      responderIdentity: bob.publicKey,
      initiatorEphemeral: ae.publicKey,
      responderEphemeral: be.publicKey,
      sessionNonce: secureRandomBytes(16),
    );
    final signature = await bob.sign(one.bytes);
    final another = SecureTranscript(
      initiatorIdentity: alice.publicKey,
      responderIdentity: bob.publicKey,
      initiatorEphemeral: ae.publicKey,
      responderEphemeral: be.publicKey,
      sessionNonce: secureRandomBytes(16),
    );
    await expectLater(
      deriveAuthenticatedKeys(
        role: SecureRole.initiator,
        transcript: another,
        localIdentity: alice,
        localEphemeral: ae,
        remoteIdentity: bob.publicKey,
        remoteEphemeral: be.publicKey,
        remoteSignature: signature,
        expectedRemoteFingerprint: bob.fingerprint,
      ),
      throwsStateError,
    );
  });
}
