// LINYUE Security Core - DEV3 experimental module only.
// Not connected to the v0.1 HTTP transport: NO wire encryption yet.
// Do NOT present this module as a secure-transfer feature to end users.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

const String secureProtocolLabel = 'linyue-secure-experimental-v1';

List<int> secureRandomBytes(int length) {
  if (length < 1 || length > 1024) {
    throw ArgumentError.value(length, 'length', 'out of range');
  }
  final rng = Random.secure();
  return List<int>.generate(length, (_) => rng.nextInt(256), growable: false);
}

String publicKeyFingerprint(SimplePublicKey key) {
  if (key.type != KeyPairType.ed25519 || key.bytes.length != 32) {
    throw ArgumentError('Expected a 32-byte Ed25519 public key');
  }
  // Full 256-bit fingerprint, not a six-digit assertion of trust.
  return hashes.sha256.convert(key.bytes).toString();
}

/// Ephemeral in-memory key material. Persistent OS-protected key storage is
/// explicitly postponed. Generating an identity here does NOT pair a device.
class DevIdentity {
  DevIdentity._(this.keyPair, this.publicKey);

  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;

  static Future<DevIdentity> generate() async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return DevIdentity._(keyPair, publicKey);
  }

  String get fingerprint => publicKeyFingerprint(publicKey);

  Future<Signature> sign(List<int> message) =>
      Ed25519().sign(message, keyPair: keyPair);
}

class DevEphemeral {
  DevEphemeral._(this.keyPair, this.publicKey);

  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;

  static Future<DevEphemeral> generate() async {
    final keyPair = await X25519().newKeyPair();
    return DevEphemeral._(keyPair, await keyPair.extractPublicKey());
  }
}

/// Both peers must build this transcript in the *same ordered roles*.
/// Its fields are included in the signatures and in HKDF key derivation.
class SecureTranscript {
  SecureTranscript({
    required this.initiatorIdentity,
    required this.responderIdentity,
    required this.initiatorEphemeral,
    required this.responderEphemeral,
    required this.sessionNonce,
  }) {
    if (initiatorIdentity.type != KeyPairType.ed25519 ||
        responderIdentity.type != KeyPairType.ed25519 ||
        initiatorEphemeral.type != KeyPairType.x25519 ||
        responderEphemeral.type != KeyPairType.x25519 ||
        initiatorIdentity.bytes.length != 32 ||
        responderIdentity.bytes.length != 32 ||
        initiatorEphemeral.bytes.length != 32 ||
        responderEphemeral.bytes.length != 32 ||
        sessionNonce.length != 16) {
      throw ArgumentError('Invalid transcript key type/length/nonce');
    }
  }

  final SimplePublicKey initiatorIdentity;
  final SimplePublicKey responderIdentity;
  final SimplePublicKey initiatorEphemeral;
  final SimplePublicKey responderEphemeral;
  final List<int> sessionNonce;

  List<int> get bytes => utf8.encode([
        secureProtocolLabel,
        base64Url.encode(initiatorIdentity.bytes),
        base64Url.encode(responderIdentity.bytes),
        base64Url.encode(initiatorEphemeral.bytes),
        base64Url.encode(responderEphemeral.bytes),
        base64Url.encode(sessionNonce),
      ].join('|'));

  List<int> get digest => hashes.sha256.convert(bytes).bytes;
}

enum SecureRole { initiator, responder }

class SessionKeys {
  const SessionKeys({
    required this.send,
    required this.receive,
    required this.transcriptHash,
  });

  final SecretKey send;
  final SecretKey receive;
  final List<int> transcriptHash;
}

/// Derives two direction-separated AES-256 keys from authenticated X25519.
/// The FULL remote fingerprint must be pinned out of band and the other
/// party's Ed25519 signature must verify over the entire transcript.
/// This is a foundation, NOT a deployed network protocol.
Future<SessionKeys> deriveAuthenticatedKeys({
  required SecureRole role,
  required SecureTranscript transcript,
  required DevIdentity localIdentity,
  required DevEphemeral localEphemeral,
  required SimplePublicKey remoteIdentity,
  required SimplePublicKey remoteEphemeral,
  required Signature remoteSignature,
  required String expectedRemoteFingerprint,
}) async {
  final expectedLocalIdentity = role == SecureRole.initiator
      ? transcript.initiatorIdentity
      : transcript.responderIdentity;
  final expectedLocalEphemeral = role == SecureRole.initiator
      ? transcript.initiatorEphemeral
      : transcript.responderEphemeral;
  final expectedRemoteIdentity = role == SecureRole.initiator
      ? transcript.responderIdentity
      : transcript.initiatorIdentity;
  final expectedRemoteEphemeral = role == SecureRole.initiator
      ? transcript.responderEphemeral
      : transcript.initiatorEphemeral;
  bool matches(SimplePublicKey a, SimplePublicKey b) =>
      a.type == b.type && base64.encode(a.bytes) == base64.encode(b.bytes);

  if (!matches(expectedLocalIdentity, localIdentity.publicKey) ||
      !matches(expectedLocalEphemeral, localEphemeral.publicKey) ||
      !matches(expectedRemoteIdentity, remoteIdentity) ||
      !matches(expectedRemoteEphemeral, remoteEphemeral)) {
    throw StateError('Transcript identity/ephemeral mismatch');
  }
  if (expectedRemoteFingerprint != publicKeyFingerprint(remoteIdentity)) {
    throw StateError('Remote identity is not the pinned device');
  }
  if (remoteSignature.publicKey is! SimplePublicKey ||
      !matches(remoteSignature.publicKey as SimplePublicKey, remoteIdentity) ||
      !await Ed25519().verify(transcript.bytes, signature: remoteSignature)) {
    throw StateError('Remote transcript signature invalid');
  }

  final shared = await X25519().sharedSecretKey(
    keyPair: localEphemeral.keyPair,
    remotePublicKey: remoteEphemeral,
  );
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final salt = transcript.digest;
  final aToB = await hkdf.deriveKey(
    secretKey: shared,
    nonce: salt,
    info: utf8.encode('$secureProtocolLabel|initiator-to-responder'),
  );
  final bToA = await hkdf.deriveKey(
    secretKey: shared,
    nonce: salt,
    info: utf8.encode('$secureProtocolLabel|responder-to-initiator'),
  );
  return SessionKeys(
    send: role == SecureRole.initiator ? aToB : bToA,
    receive: role == SecureRole.initiator ? bToA : aToB,
    transcriptHash: salt,
  );
}

/// AES-GCM authenticated frame. The sequence and direction are bound into AAD.
/// Replay tracking and frame limits are mandatory *before network deployment*.
class EncryptedFrame {
  const EncryptedFrame({
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final List<int> nonce;
  final List<int> cipherText;
  final List<int> mac;
}

List<int> _frameAad(List<int> transcriptHash, String direction, int sequence) {
  if (transcriptHash.length != 32 ||
      (direction != 'initiator-to-responder' &&
          direction != 'responder-to-initiator') ||
      sequence < 0) {
    throw ArgumentError('Invalid authenticated frame metadata');
  }
  return <int>[
    ...transcriptHash,
    ...utf8.encode('$secureProtocolLabel|$direction|$sequence'),
  ];
}

Future<EncryptedFrame> encryptFrame({
  required SessionKeys session,
  required String direction,
  required int sequence,
  required List<int> plainText,
}) async {
  final cipher = AesGcm.with256bits();
  final nonce = cipher.newNonce(); // Fresh random nonce per frame.
  final box = await cipher.encrypt(
    plainText,
    secretKey: session.send,
    nonce: nonce,
    aad: _frameAad(session.transcriptHash, direction, sequence),
  );
  return EncryptedFrame(
    nonce: List<int>.from(box.nonce),
    cipherText: List<int>.from(box.cipherText),
    mac: List<int>.from(box.mac.bytes),
  );
}

Future<List<int>> decryptFrame({
  required SessionKeys session,
  required String direction,
  required int sequence,
  required EncryptedFrame frame,
}) async {
  if (frame.nonce.length != 12 || frame.mac.length != 16) {
    throw FormatException('Invalid AES-GCM frame');
  }
  return AesGcm.with256bits().decrypt(
    SecretBox(frame.cipherText, nonce: frame.nonce, mac: Mac(frame.mac)),
    secretKey: session.receive,
    aad: _frameAad(session.transcriptHash, direction, sequence),
  );
}
