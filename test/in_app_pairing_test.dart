import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/in_app_pairing.dart';

class MemoryIdentityVault implements IdentityVault {
  final Map<String, String> content = {};
  @override
  Future<String?> read(String key) async => content[key];
  @override
  Future<void> write(String key, String value) async { content[key] = value; }
  @override
  Future<void> delete(String key) async { content.remove(key); }
}

void main() {
  test('same transcript gives same six-digit code; changes affect it', () {
    const t = PairingTranscript(
      id: '11111111111111111111111111111111', initiatorCard: 'A', responderCard: 'B',
      initiatorNonce: 'nonce-1', responderNonce: 'nonce-2');
    const copy = PairingTranscript(
      id: '11111111111111111111111111111111', initiatorCard: 'A', responderCard: 'B',
      initiatorNonce: 'nonce-1', responderNonce: 'nonce-2');
    const changed = PairingTranscript(
      id: '22222222222222222222222222222222', initiatorCard: 'A', responderCard: 'B',
      initiatorNonce: 'nonce-1', responderNonce: 'nonce-2');
    expect(t.comparisonCode, matches(RegExp(r'^\d{6}$')));
    expect(t.comparisonCode, copy.comparisonCode);
    expect(t.comparisonCode, isNot(changed.comparisonCode));
  });

  test('private-network filter rejects public and malformed addresses', () {
    expect(isPrivatePairingIp('192.168.1.23'), isTrue);
    expect(isPrivatePairingIp('10.0.0.2'), isTrue);
    expect(isPrivatePairingIp('127.0.0.1'), isTrue);
    expect(isPrivatePairingIp('8.8.8.8'), isFalse);
    expect(isPrivatePairingIp('192.168.1.999'), isFalse);
  });

  test('in-app mutual confirmation registers both identities and resumes', () async {
    final aVault = MemoryIdentityVault();
    final bVault = MemoryIdentityVault();
    final a = DeviceIdentityManager(aVault);
    final b = DeviceIdentityManager(bVault);
    await a.initialize();
    await b.initialize();
    final serverA = InAppPairingService(a, deviceName: '手机');
    final serverB = InAppPairingService(b, deviceName: '电脑');
    await serverA.start(address: InternetAddress.loopbackIPv4, port: 0);
    await serverB.start(address: InternetAddress.loopbackIPv4, port: 0);
    try {
      // The /offer response and the remote confirmation callback run
      // asynchronously. Do not assume which reaches the test first.
      final incomingCode = Completer<String>();
      serverB.onIncomingRequest = (prompt) async {
        expect(prompt.remoteName, '手机');
        expect(prompt.incoming, isTrue);
        if (!incomingCode.isCompleted) {
          incomingCode.complete(prompt.comparisonCode);
        }
        return true;
      };
      final result = await serverA.initiate(
        remoteIp: '127.0.0.1', remoteName: '电脑',
        port: serverB.boundPort!,
        confirm: (prompt) async {
          expect(prompt.incoming, isFalse);
          final remoteCode = await incomingCode.future.timeout(
            const Duration(seconds: 15),
          );
          expect(remoteCode, matches(RegExp(r'^\d{6}$')));
          expect(prompt.comparisonCode, remoteCode);
          return true;
        },
      );
      expect(result.fingerprint, b.local.fingerprint);
      expect(a.entries.single.fingerprint, b.local.fingerprint);
      expect(b.entries.single.fingerprint, a.local.fingerprint);
      final resumed = await serverA.tryResume(
        remoteIp: '127.0.0.1', port: serverB.boundPort!);
      expect(resumed?.fingerprint, b.local.fingerprint);
    } finally {
      await serverA.stop();
      await serverB.stop();
    }
    // Secure-store content persisted; nothing requires manual fingerprint input.
    final restoredA = DeviceIdentityManager(aVault);
    await restoredA.initialize();
    expect(restoredA.local.fingerprint, a.local.fingerprint);
    expect(restoredA.entries.single.fingerprint, b.local.fingerprint);
  });

  test('declined incoming code never saves either device', () async {
    final a = DeviceIdentityManager(MemoryIdentityVault());
    final b = DeviceIdentityManager(MemoryIdentityVault());
    await a.initialize();
    await b.initialize();
    final sa = InAppPairingService(a, deviceName: '手机');
    final sb = InAppPairingService(b, deviceName: '电脑');
    await sa.start(address: InternetAddress.loopbackIPv4, port: 0);
    await sb.start(address: InternetAddress.loopbackIPv4, port: 0);
    try {
      sb.onIncomingRequest = (_) async => false;
      await expectLater(
        sa.initiate(remoteIp: '127.0.0.1', remoteName: '电脑',
          port: sb.boundPort!, confirm: (_) async => true),
        throwsA(isA<StateError>()),
      );
      expect(a.entries, isEmpty);
      expect(b.entries, isEmpty);
    } finally {
      await sa.stop();
      await sb.stop();
    }
  });
}
