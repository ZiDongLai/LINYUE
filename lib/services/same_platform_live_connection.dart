import 'dart:async';

import '../security/in_app_pairing.dart';
import 'same_platform_connection_policy.dart';

/// E22-B: only an authenticated pairing result may enter the live session.
/// Peer name, UDP ID, IP and advertised platform are untrusted locators.
/// Both Windows and Android can initiate and accept; no platform role switch.
final class SamePlatformLiveConnection {
  final Map<String, Future<PairingResult>> _inFlight = {};

  bool isConnecting(String remoteIp) => _inFlight.containsKey(remoteIp);

  /// Coalesce concurrent local pairing requests to the same remote IP.
  /// The server-side signed pairing protocol remains the authority and still
  /// requires the user's independent six-digit code confirmation for new peers.
  Future<PairingResult> resolve({
    required String remoteIp,
    required String localFingerprint,
    required bool secureChannelReady,
    required bool Function(String fingerprint) isRegistered,
    required Future<PairingResult?> Function() trySignedResume,
    required Future<PairingResult> Function() initiateSignedPairing,
  }) async {
    if (!SamePlatformConnectionPolicy.isPlausibleLanAddress(remoteIp)) {
      throw StateError('只能连接有效局域网地址，禁止回环、自连接或公网地址');
    }
    // A later caller must not inherit the FIRST caller's enrollment or
    // channel-readiness decision merely because both selected the same IP.
    // Keep a single signed network exchange, but authorize EACH caller after
    // awaiting its result. This matters if enrollment/channel state changes
    // while the pairing confirmation dialog is open.
    if (!secureChannelReady) {
      throw StateError('加密会话未就绪，不允许连接');
    }
    final active = _inFlight[remoteIp];
    if (active != null) {
      final signedResult = await active;
      _checkSignedResult(
        remoteIp: remoteIp,
        localFingerprint: localFingerprint,
        secureChannelReady: secureChannelReady,
        isRegistered: isRegistered,
        signedResult: signedResult,
      );
      return signedResult;
    }
    final pending = _prove(
      remoteIp: remoteIp,
      localFingerprint: localFingerprint,
      secureChannelReady: secureChannelReady,
      isRegistered: isRegistered,
      trySignedResume: trySignedResume,
      initiateSignedPairing: initiateSignedPairing,
    );
    _inFlight[remoteIp] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_inFlight[remoteIp], pending)) {
        _inFlight.remove(remoteIp);
      }
    }
  }

  Future<PairingResult> _prove({
    required String remoteIp,
    required String localFingerprint,
    required bool secureChannelReady,
    required bool Function(String fingerprint) isRegistered,
    required Future<PairingResult?> Function() trySignedResume,
    required Future<PairingResult> Function() initiateSignedPairing,
  }) async {
    if (!secureChannelReady) {
      throw StateError('加密会话未就绪，不允许连接');
    }
    final signedResult = await trySignedResume() ?? await initiateSignedPairing();
    _checkSignedResult(
      remoteIp: remoteIp,
      localFingerprint: localFingerprint,
      secureChannelReady: secureChannelReady,
      isRegistered: isRegistered,
      signedResult: signedResult,
    );
    return signedResult;
  }

  static void _checkSignedResult({
    required String remoteIp,
    required String localFingerprint,
    required bool secureChannelReady,
    required bool Function(String fingerprint) isRegistered,
    required PairingResult signedResult,
  }) {
    // A signed proof proves who responded, not that the current caller has
    // enrolled that identity. In particular, discovery name/IP is not trust.
    if (signedResult.remoteIp != remoteIp ||
        !isRegistered(signedResult.fingerprint)) {
      throw StateError('签名认证的设备身份或地址与所选设备不一致');
    }
    authorizeSignedIdentity(
      remoteIp: remoteIp,
      localFingerprint: localFingerprint,
      registeredFingerprint: signedResult.fingerprint,
      signedFingerprint: signedResult.fingerprint,
      secureChannelReady: secureChannelReady,
    );
  }

  /// Use this for a separate freshly signed resume proof before a queued
  /// transfer. The decision NEVER trusts a fingerprint provided by discovery.
  static void authorizeSignedIdentity({
    required String remoteIp,
    required String localFingerprint,
    required String registeredFingerprint,
    required String signedFingerprint,
    required bool secureChannelReady,
  }) {
    final decision = SamePlatformConnectionPolicy.evaluate(
      SamePlatformPeerCandidate(
        localFingerprint: localFingerprint,
        remoteIp: remoteIp,
        reachable: true, // A signed proof has just completed over this IP.
        enrolledFingerprint: registeredFingerprint,
        authenticatedFingerprint: signedFingerprint,
        encryptedChannelReady: secureChannelReady,
        authenticatedProtocolConfirmed: true, // Ed25519 signed-pairing v1.
      ),
    );
    if (!decision.mayAttemptSecureOperation) {
      throw StateError('同平台安全连接检查失败：${decision.outcome.name}');
    }
  }
}
