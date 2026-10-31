import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/trusted_auto_receive_policy.dart';

class _FakeVault implements IdentityVault {
  final Map<String, String> values = <String, String>{};
  bool failRead = false;
  bool failWrite = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('vault unavailable');
    return values[key];
  }
  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('vault write failure');
    values[key] = value;
  }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

void main() {
  final a = List.filled(64, 'a').join();
  final b = List.filled(64, 'b').join();
  test('first verified but ungranted file still needs permission', () async {
    final policy = TrustedAutoReceivePolicy(_FakeVault());
    await policy.load();
    expect(policy.mayAutoAccept(a,
      authenticatedRegisteredIdentity: true, receivingAllowed: true), isFalse);
    print('[DEV13B3] FIRST_FILE_REQUIRES_CONSENT_PASS');
  });
  test('granted authenticated fingerprint survives restart', () async {
    final vault = _FakeVault();
    final first = TrustedAutoReceivePolicy(vault);
    await first.load();
    await first.grant(a);
    final next = TrustedAutoReceivePolicy(vault);
    await next.load();
    expect(next.mayAutoAccept(a,
      authenticatedRegisteredIdentity: true, receivingAllowed: true), isTrue);
    expect(next.mayAutoAccept(b,
      authenticatedRegisteredIdentity: true, receivingAllowed: true), isFalse);
    print('[DEV13B3] AUTHENTICATED_RESTART_AUTO_PASS');
  });
  test('wrong identity or paused receiver refuses automatic consent', () async {
    final policy = TrustedAutoReceivePolicy(_FakeVault());
    await policy.load();
    await policy.grant(a);
    expect(policy.mayAutoAccept(a,
      authenticatedRegisteredIdentity: false, receivingAllowed: true), isFalse);
    expect(policy.mayAutoAccept(a,
      authenticatedRegisteredIdentity: true, receivingAllowed: false), isFalse);
    print('[DEV13B3] UNTRUSTED_OR_PAUSED_REJECT_PASS');
  });
  test('enabled toggle, reset and restoration persist correctly', () async {
    final vault = _FakeVault();
    final policy = TrustedAutoReceivePolicy(vault);
    await policy.load();
    await policy.grant(a);
    await policy.setEnabled(false);
    expect(policy.mayAutoAccept(a,
      authenticatedRegisteredIdentity: true, receivingAllowed: true), isFalse);
    final reopened = TrustedAutoReceivePolicy(vault);
    await reopened.load();
    expect(reopened.enabled, isFalse);
    expect(reopened.authorizedCount, 1);
    await reopened.setEnabled(true);
    await reopened.revokeAll();
    expect(reopened.authorizedCount, 0);
    expect(reopened.mayAutoAccept(a,
      authenticatedRegisteredIdentity: true, receivingAllowed: true), isFalse);
    print('[DEV13B3] SETTINGS_REVOKE_PASS');
  });
  test('corrupt grant data fail closed, without overwriting vault', () async {
    final vault = _FakeVault();
    await vault.write('linyue.dev13.trusted.auto.receive.v1',
      jsonEncode({'version': 1, 'enabled': true, 'fingerprints': ['not-a-fingerprint']}));
    final policy = TrustedAutoReceivePolicy(vault);
    await expectLater(policy.load(), throwsFormatException);
    expect(policy.mayAutoAccept(a,
      authenticatedRegisteredIdentity: true, receivingAllowed: true), isFalse);
    expect(policy.ready, isFalse);
    print('[DEV13B3] CORRUPT_STORE_FAIL_CLOSED_PASS');
  });
  test('persist failures cannot accidentally enable automatic consent', () async {
    final vault = _FakeVault();
    final policy = TrustedAutoReceivePolicy(vault);
    await policy.load();
    vault.failWrite = true;
    await expectLater(policy.grant(a), throwsStateError);
    expect(policy.authorizedCount, 0);
    expect(policy.mayAutoAccept(a,
      authenticatedRegisteredIdentity: true, receivingAllowed: true), isFalse);
    print('[DEV13B3] WRITE_FAILURE_FAIL_CLOSED_PASS');
  });
  test('invalid fingerprints can never be stored or accepted', () async {
    final policy = TrustedAutoReceivePolicy(_FakeVault());
    await policy.load();
    await expectLater(policy.grant('device@192.168.1.2'), throwsArgumentError);
    expect(policy.authorizedCount, 0);
    print('[DEV13B3] IP_NOT_IDENTITY_PASS');
  });
  test('unavailable vault never loads grants', () async {
    final vault = _FakeVault()..failRead = true;
    final policy = TrustedAutoReceivePolicy(vault);
    await expectLater(policy.load(), throwsStateError);
    expect(policy.mayAutoAccept(a,
      authenticatedRegisteredIdentity: true, receivingAllowed: true), isFalse);
  });
}
