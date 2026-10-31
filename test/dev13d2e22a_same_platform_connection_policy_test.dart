import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/same_platform_connection_policy.dart';

const localKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const remoteKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

SamePlatformPeerCandidate sample({
  LinyueEndpointPlatform localPlatform = LinyueEndpointPlatform.windows,
  LinyueEndpointPlatform remotePlatform = LinyueEndpointPlatform.android,
  String localFingerprint = localKey,
  String? enrolledFingerprint = remoteKey,
  String? authenticatedFingerprint = remoteKey,
  String remoteIp = '192.168.1.20',
  bool reachable = true,
  bool encryptedChannelReady = true,
  bool authenticatedProtocolConfirmed = true,
  bool manualAddress = false,
  String announcedName = 'Android · 我的手机',
}) => SamePlatformPeerCandidate(
  localPlatform: localPlatform,
  announcedPlatform: remotePlatform,
  localFingerprint: localFingerprint,
  enrolledFingerprint: enrolledFingerprint,
  authenticatedFingerprint: authenticatedFingerprint,
  remoteIp: remoteIp,
  reachable: reachable,
  encryptedChannelReady: encryptedChannelReady,
  authenticatedProtocolConfirmed: authenticatedProtocolConfirmed,
  manualAddress: manualAddress,
  announcedName: announcedName,
);

void main() {
  group('E22-A platform-neutral connection preflight', () {
    test('Windows to Windows does not require platform-specific client role', () {
      final outcome = SamePlatformConnectionPolicy.evaluate(sample(
        remotePlatform: LinyueEndpointPlatform.windows,
      ));
      expect(outcome.mayAttemptSecureOperation, isTrue);
      expect(outcome.preferredDialSide, PreferredDialSide.local);
    });

    test('Android to Android uses the same policy', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        localPlatform: LinyueEndpointPlatform.android,
        remotePlatform: LinyueEndpointPlatform.android,
      )).outcome, PeerPreflightOutcome.ready);
    });

    test('Windows to Android remains supported', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample()).outcome,
          PeerPreflightOutcome.ready);
    });

    test('Android to Windows remains supported', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        localPlatform: LinyueEndpointPlatform.android,
        remotePlatform: LinyueEndpointPlatform.windows,
      )).mayAttemptSecureOperation, isTrue);
    });

    test('untrusted displayed platform or name never changes permission', () {
      final normal = SamePlatformConnectionPolicy.evaluate(sample());
      final forged = SamePlatformConnectionPolicy.evaluate(sample(
        remotePlatform: LinyueEndpointPlatform.windows,
        announcedName: 'Windows · 管理员（伪造）',
      ));
      expect(normal.outcome, forged.outcome);
    });

    test('unknown enrollment never becomes trusted from UDP presence', () {
      final decision = SamePlatformConnectionPolicy.evaluate(sample(
        enrolledFingerprint: null,
      ));
      expect(decision.outcome, PeerPreflightOutcome.pairingRequired);
      expect(decision.mayAttemptSecureOperation, isFalse);
    });

    test('registered but no signed identity proof remains untrusted', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        authenticatedFingerprint: null,
      )).outcome, PeerPreflightOutcome.pairingRequired);
    });

    test('self identity is rejected even if another UDP id advertises it', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        authenticatedFingerprint: localKey,
      )).outcome, PeerPreflightOutcome.selfConnection);
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        enrolledFingerprint: localKey,
      )).outcome, PeerPreflightOutcome.selfConnection);
    });

    test('forged authenticated fingerprint does not match registered identity', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        authenticatedFingerprint: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      )).outcome, PeerPreflightOutcome.authenticatedIdentityMismatch);
    });

    test('disconnected peer must not trigger sending', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(reachable: false)).outcome,
          PeerPreflightOutcome.unreachable);
    });

    test('unencrypted endpoint is never ready even after pairing', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        encryptedChannelReady: false,
      )).outcome, PeerPreflightOutcome.encryptedChannelNotReady);
    });

    test('no claimed plaintext or unsigned version compatibility bypass', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        authenticatedProtocolConfirmed: false,
      )).outcome, PeerPreflightOutcome.authenticatedProtocolNotConfirmed);
    });

    test('manual IPv4 entry is a locator, not special trust', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        manualAddress: true,
        authenticatedFingerprint: null,
      )).outcome, PeerPreflightOutcome.pairingRequired);
    });

    test('loopback, external, broadcast and noncanonical addresses are blocked', () {
      for (final address in [
        '127.0.0.1', '8.8.8.8', '255.255.255.255',
        '192.168.001.2', '0.0.0.0', 'localhost', '192.168.1.999',
      ]) {
        expect(SamePlatformConnectionPolicy.evaluate(sample(
          remoteIp: address,
        )).outcome, PeerPreflightOutcome.invalidPeerAddress, reason: address);
      }
      for (final address in ['10.2.3.4', '172.18.0.8', '192.168.1.3']) {
        expect(SamePlatformConnectionPolicy.isPlausibleLanAddress(address), isTrue,
          reason: address);
      }
    });

    test('malformed local fingerprint rejects the attempt', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        localFingerprint: 'fake',
      )).outcome, PeerPreflightOutcome.invalidLocalIdentity);
    });

    test('malformed or absent authenticated identity cannot bypass enrollment', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        authenticatedFingerprint: 'not-a-fingerprint',
      )).outcome, PeerPreflightOutcome.pairingRequired);
    });

    test('simultaneous dialing preference is stable and complementary', () {
      expect(SamePlatformConnectionPolicy.preferredDialSide(localKey, remoteKey),
          PreferredDialSide.local);
      expect(SamePlatformConnectionPolicy.preferredDialSide(remoteKey, localKey),
          PreferredDialSide.remote);
      expect(SamePlatformConnectionPolicy.preferredDialSide(localKey, localKey),
          PreferredDialSide.undecidable);
    });

    test('signed fingerprint comparisons ignore capitalization but not contents', () {
      expect(SamePlatformConnectionPolicy.evaluate(sample(
        localFingerprint: localKey.toUpperCase(),
        enrolledFingerprint: remoteKey.toUpperCase(),
      )).outcome, PeerPreflightOutcome.ready);
    });
  });
}
