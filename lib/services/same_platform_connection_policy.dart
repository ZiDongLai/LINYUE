/// DEV13D2E22-A: platform-neutral LAN candidate preflight.
///
/// A discovery name/UDP sender/visible IP is never evidence of identity.
/// These pure decisions do NOT open sockets, pair peers, authorize transfers,
/// or replace the signed-pairing and authenticated encrypted channel.
/// A caller must supply [authenticatedFingerprint] only after verifying the
/// signed remote identity, never from a broadcast or a local cache alone.
enum LinyueEndpointPlatform { windows, android, other }

enum PeerPreflightOutcome {
  invalidLocalIdentity,
  invalidPeerAddress,
  selfConnection,
  unreachable,
  pairingRequired,
  authenticatedIdentityMismatch,
  encryptedChannelNotReady,
  authenticatedProtocolNotConfirmed,
  ready,
}

enum PreferredDialSide { local, remote, undecidable }

/// The only identity evidence here is a cryptographically authenticated
/// fingerprint passed by the secure layer and the locally enrolled fingerprint.
/// [announcedPlatform] and [announcedName] are *untrusted display hints*.
final class SamePlatformPeerCandidate {
  const SamePlatformPeerCandidate({
    required this.localFingerprint,
    required this.remoteIp,
    required this.reachable,
    required this.enrolledFingerprint,
    required this.authenticatedFingerprint,
    required this.encryptedChannelReady,
    required this.authenticatedProtocolConfirmed,
    this.localPlatform = LinyueEndpointPlatform.other,
    this.announcedPlatform = LinyueEndpointPlatform.other,
    this.announcedName = '',
    this.manualAddress = false,
  });

  final String localFingerprint;
  final String remoteIp;
  final bool reachable;
  final String? enrolledFingerprint;
  final String? authenticatedFingerprint;
  final bool encryptedChannelReady;
  final bool authenticatedProtocolConfirmed;
  final LinyueEndpointPlatform localPlatform;
  final LinyueEndpointPlatform announcedPlatform;
  final String announcedName;
  final bool manualAddress;
}

final class SamePlatformPeerDecision {
  const SamePlatformPeerDecision(this.outcome, {this.preferredDialSide = PreferredDialSide.undecidable});

  final PeerPreflightOutcome outcome;
  final PreferredDialSide preferredDialSide;

  /// Authorization still belongs to the existing authenticated channel.
  bool get mayAttemptSecureOperation => outcome == PeerPreflightOutcome.ready;
}

final class SamePlatformConnectionPolicy {
  const SamePlatformConnectionPolicy._();

  static final RegExp _fingerprintFormat = RegExp(r'^[a-f0-9]{64}$');

  static String? _fingerprint(String? value) {
    if (value == null) return null;
    final text = value.trim().toLowerCase();
    return _fingerprintFormat.hasMatch(text) ? text : null;
  }

  /// Only ordinary LAN IPv4 endpoints; loopback is intentionally rejected.
  /// Pairing layer must separately apply its own private-address rules.
  static bool isPlausibleLanAddress(String raw) {
    final parts = raw.split('.');
    if (parts.length != 4) return false;
    final numbers = <int>[];
    for (final part in parts) {
      if (!RegExp(r'^[0-9]{1,3}$').hasMatch(part) ||
          (part.length > 1 && part.startsWith('0'))) return false;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
      numbers.add(value);
    }
    return numbers[0] == 10 ||
        (numbers[0] == 172 && numbers[1] >= 16 && numbers[1] <= 31) ||
        (numbers[0] == 192 && numbers[1] == 168);
  }

  /// Advisory race-resolution rule only. Both endpoint types can accept and
  /// initiate; this must NOT be used to silently skip signature verification.
  /// If a future two-way connect negotiates an initiator, the same two
  /// enrolled public-key fingerprints lead to complementary decisions.
  static PreferredDialSide preferredDialSide(
    String localFingerprint,
    String remoteFingerprint,
  ) {
    final local = _fingerprint(localFingerprint);
    final remote = _fingerprint(remoteFingerprint);
    if (local == null || remote == null || local == remote) {
      return PreferredDialSide.undecidable;
    }
    return local.compareTo(remote) < 0
        ? PreferredDialSide.local
        : PreferredDialSide.remote;
  }

  static SamePlatformPeerDecision evaluate(SamePlatformPeerCandidate peer) {
    final local = _fingerprint(peer.localFingerprint);
    if (local == null) {
      return const SamePlatformPeerDecision(PeerPreflightOutcome.invalidLocalIdentity);
    }
    if (!isPlausibleLanAddress(peer.remoteIp)) {
      return const SamePlatformPeerDecision(PeerPreflightOutcome.invalidPeerAddress);
    }

    final enrolled = _fingerprint(peer.enrolledFingerprint);
    final authenticated = _fingerprint(peer.authenticatedFingerprint);
    // Even if this loopback/self connection is discovered under another
    // ephemeral UDP device id, it must not be treated as a remote device.
    if (enrolled == local || authenticated == local) {
      return const SamePlatformPeerDecision(PeerPreflightOutcome.selfConnection);
    }
    if (!peer.reachable) {
      return const SamePlatformPeerDecision(PeerPreflightOutcome.unreachable);
    }
    if (enrolled == null || authenticated == null) {
      return const SamePlatformPeerDecision(PeerPreflightOutcome.pairingRequired);
    }
    if (enrolled != authenticated) {
      return const SamePlatformPeerDecision(PeerPreflightOutcome.authenticatedIdentityMismatch);
    }
    if (!peer.encryptedChannelReady) {
      return const SamePlatformPeerDecision(PeerPreflightOutcome.encryptedChannelNotReady);
    }
    if (!peer.authenticatedProtocolConfirmed) {
      return const SamePlatformPeerDecision(PeerPreflightOutcome.authenticatedProtocolNotConfirmed);
    }
    return SamePlatformPeerDecision(
      PeerPreflightOutcome.ready,
      preferredDialSide: preferredDialSide(local, authenticated),
    );
  }
}
