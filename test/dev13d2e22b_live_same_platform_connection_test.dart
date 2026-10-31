import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/in_app_pairing.dart';
import 'package:nearlink/services/same_platform_connection_policy.dart';
import 'package:nearlink/services/same_platform_live_connection.dart';

const localId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const remoteId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const unrelatedId = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

PairingResult proof(String fingerprint, {String ip = '192.168.18.15'}) =>
    PairingResult(remoteName: '验证设备', fingerprint: fingerprint, remoteIp: ip);

void main() {
  group('E22-B live signed same-platform pairing integration', () {
    test('Windows–Windows registered device signed resume', () async {
      final gate = SamePlatformLiveConnection();
      var enrollmentCount = 0;
      final result = await gate.resolve(
        remoteIp: '192.168.18.15',
        localFingerprint: localId,
        secureChannelReady: true,
        isRegistered: (fp) => fp == remoteId,
        trySignedResume: () async => proof(remoteId),
        initiateSignedPairing: () async { enrollmentCount++; return proof(remoteId); },
      );
      expect(result.fingerprint, remoteId);
      expect(enrollmentCount, 0);
    });

    test('Android–Android first pairing must complete signed enrollment', () async {
      var enrolled = false;
      var prompts = 0;
      final result = await SamePlatformLiveConnection().resolve(
        remoteIp: '192.168.18.15',
        localFingerprint: localId,
        secureChannelReady: true,
        isRegistered: (fp) => enrolled && fp == remoteId,
        trySignedResume: () async => null,
        initiateSignedPairing: () async {
          prompts++; // Existing SAS service is responsible for human confirmation.
          enrolled = true;
          return proof(remoteId);
        },
      );
      expect(result.fingerprint, remoteId);
      expect(prompts, 1);
    });

    test('concurrent requests for the SAME IP join one proof and one enrollment', () async {
      final gate = SamePlatformLiveConnection();
      final waiting = Completer<PairingResult?>();
      var resumeCalls = 0;
      var enrollCalls = 0;
      Future<PairingResult> connect() => gate.resolve(
        remoteIp: '192.168.18.15', localFingerprint: localId,
        secureChannelReady: true, isRegistered: (fp) => fp == remoteId,
        trySignedResume: () { resumeCalls++; return waiting.future; },
        initiateSignedPairing: () async { enrollCalls++; return proof(remoteId); },
      );
      final first = connect();
      final second = connect();
      expect(gate.isConnecting('192.168.18.15'), isTrue);
      waiting.complete(null);
      final results = await Future.wait([first, second]);
      expect(results.map((r) => r.fingerprint).toList(), [remoteId, remoteId]);
      expect(resumeCalls, 1);
      expect(enrollCalls, 1);
      expect(gate.isConnecting('192.168.18.15'), isFalse);
    });

    test('different private IPs never share signed session', () async {
      final gate = SamePlatformLiveConnection();
      final a = await gate.resolve(
        remoteIp: '192.168.18.15', localFingerprint: localId,
        secureChannelReady: true, isRegistered: (fp) => fp == remoteId,
        trySignedResume: () async => proof(remoteId),
        initiateSignedPairing: () async => throw StateError('not needed'),
      );
      final b = await gate.resolve(
        remoteIp: '192.168.18.16', localFingerprint: localId,
        secureChannelReady: true, isRegistered: (fp) => fp == unrelatedId,
        trySignedResume: () async => proof(unrelatedId, ip: '192.168.18.16'),
        initiateSignedPairing: () async => throw StateError('not needed'),
      );
      expect(a.fingerprint, isNot(b.fingerprint));
    });

    test('self pairing rejected even with valid signature-looking result', () async {
      await expectLater(
        SamePlatformLiveConnection().resolve(
          remoteIp: '192.168.18.15', localFingerprint: localId,
          secureChannelReady: true, isRegistered: (_) => true,
          trySignedResume: () async => proof(localId),
          initiateSignedPairing: () async => throw StateError('unexpected'),
        ), throwsA(isA<StateError>()),
      );
    });

    test('a changed or unregistered fingerprint cannot use a stale IP slot', () async {
      await expectLater(
        SamePlatformLiveConnection().resolve(
          remoteIp: '192.168.18.15', localFingerprint: localId,
          secureChannelReady: true, isRegistered: (fp) => fp == remoteId,
          trySignedResume: () async => proof(unrelatedId),
          initiateSignedPairing: () async => throw StateError('unexpected'),
        ), throwsA(isA<StateError>()),
      );
    });

    test('result from another IP is rejected', () async {
      await expectLater(
        SamePlatformLiveConnection().resolve(
          remoteIp: '192.168.18.15', localFingerprint: localId,
          secureChannelReady: true, isRegistered: (_) => true,
          trySignedResume: () async => proof(remoteId, ip: '192.168.18.99'),
          initiateSignedPairing: () async => throw StateError('unexpected'),
        ), throwsA(isA<StateError>()),
      );
    });

    test('encryption not ready prevents all connection attempts', () async {
      var attempted = false;
      await expectLater(
        SamePlatformLiveConnection().resolve(
          remoteIp: '192.168.18.15', localFingerprint: localId,
          secureChannelReady: false, isRegistered: (_) => true,
          trySignedResume: () async { attempted = true; return proof(remoteId); },
          initiateSignedPairing: () async { attempted = true; return proof(remoteId); },
        ), throwsA(isA<StateError>()),
      );
      expect(attempted, isFalse);
    });

    test('loopback, public IP and invalid address are blocked before network', () async {
      for (final ip in ['127.0.0.1', '8.8.8.8', '255.255.255.255', 'host.local']) {
        var called = false;
        await expectLater(
          SamePlatformLiveConnection().resolve(
            remoteIp: ip, localFingerprint: localId,
            secureChannelReady: true, isRegistered: (_) => true,
            trySignedResume: () async { called = true; return proof(remoteId); },
            initiateSignedPairing: () async { called = true; return proof(remoteId); },
          ), throwsA(isA<StateError>()), reason: ip,
        );
        expect(called, isFalse, reason: ip);
      }
    });

    test('failing pairing is not cached; explicit retry can succeed', () async {
      final gate = SamePlatformLiveConnection();
      var calls = 0;
      Future<PairingResult> go() => gate.resolve(
        remoteIp: '192.168.18.15', localFingerprint: localId,
        secureChannelReady: true, isRegistered: (_) => true,
        trySignedResume: () async {
          calls++;
          if (calls == 1) throw StateError('temporary network failure');
          return proof(remoteId);
        },
        initiateSignedPairing: () async => throw StateError('unexpected'),
      );
      await expectLater(go(), throwsA(isA<StateError>()));
      expect(gate.isConnecting('192.168.18.15'), isFalse);
      expect((await go()).fingerprint, remoteId);
      expect(calls, 2);
    });

    test('different announced platforms cannot change authorization', () {
      for (final a in LinyueEndpointPlatform.values) {
        for (final b in LinyueEndpointPlatform.values) {
          final result = SamePlatformConnectionPolicy.evaluate(
            SamePlatformPeerCandidate(
              localFingerprint: localId,
              remoteIp: '192.168.18.15', reachable: true,
              enrolledFingerprint: remoteId,
              authenticatedFingerprint: remoteId,
              encryptedChannelReady: true,
              authenticatedProtocolConfirmed: true,
              localPlatform: a, announcedPlatform: b,
              announcedName: '任意广播设备名',
            ),
          );
          expect(result.mayAttemptSecureOperation, isTrue,
              reason: '${a.name}-${b.name}');
        }
      }
    });

    test('manual locator is never a trusted credential', () {
      expect(SamePlatformConnectionPolicy.evaluate(
        SamePlatformPeerCandidate(
          localFingerprint: localId, remoteIp: '192.168.18.15',
          reachable: true, enrolledFingerprint: null,
          authenticatedFingerprint: null, encryptedChannelReady: true,
          authenticatedProtocolConfirmed: true, manualAddress: true,
        ),
      ).mayAttemptSecureOperation, isFalse);
    });

    test('restored large-file job rejects a swapped authenticated peer', () {
      expect(() => SamePlatformLiveConnection.authorizeSignedIdentity(
        remoteIp: '192.168.18.15',
        localFingerprint: localId,
        registeredFingerprint: remoteId,
        signedFingerprint: unrelatedId,
        secureChannelReady: true,
      ), throwsA(isA<StateError>()));
    });

    test('signed resume for right identity can authorize queued file', () {
      expect(() => SamePlatformLiveConnection.authorizeSignedIdentity(
        remoteIp: '192.168.18.15',
        localFingerprint: localId,
        registeredFingerprint: remoteId,
        signedFingerprint: remoteId,
        secureChannelReady: true,
      ), returnsNormally);
    });
  });
}
