import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';

class TestVault implements IdentityVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

void main() {
  test('identity remains stable after app-like restart; signature verified', () async {
    final vault = TestVault();
    final a = DeviceIdentityManager(vault);
    await a.initialize();
    final public = a.local.publicKey;
    final challenge = utf8.encode('linyue/dev4/identity-proof/test');
    final signature = await a.local.sign(challenge);
    expect(await Ed25519().verify(challenge, signature: signature), isTrue);
    final b = DeviceIdentityManager(vault);
    await b.initialize();
    expect(b.local.fingerprint, a.local.fingerprint);
    expect(b.local.card, a.local.card);
    expect(PublicIdentityCard.parse(b.local.card).fingerprint, a.local.fingerprint);
    expect(public.bytes, b.local.publicKey.bytes);
  });

  test('different devices have different identities', () async {
    final a = DeviceIdentityManager(TestVault());
    final b = DeviceIdentityManager(TestVault());
    await a.initialize();
    await b.initialize();
    expect(a.local.fingerprint, isNot(b.local.fingerprint));
  });

  test('registering requires independently entered full fingerprint', () async {
    final source = DeviceIdentityManager(TestVault());
    await source.initialize();
    final vault = TestVault();
    final target = DeviceIdentityManager(vault);
    await target.initialize();
    await expectLater(
      target.register(
        displayName: '我的电脑',
        identityCard: source.local.card,
        independentlyCheckedFingerprint: target.local.fingerprint,
      ),
      throwsStateError,
    );
    expect(target.entries, isEmpty);
    await target.register(
      displayName: '我的电脑',
      identityCard: source.local.card,
      independentlyCheckedFingerprint: source.local.fingerprint,
    );
    expect(target.entries.single.name, '我的电脑');
    final restarted = DeviceIdentityManager(vault);
    await restarted.initialize();
    expect(restarted.entries.single.fingerprint, source.local.fingerprint);
    await expectLater(
      restarted.register(
        displayName: '重复',
        identityCard: source.local.card,
        independentlyCheckedFingerprint: source.local.fingerprint,
      ),
      throwsStateError,
    );
    await restarted.revoke(source.local.fingerprint);
    expect(restarted.entries, isEmpty);
    final reloaded = DeviceIdentityManager(vault);
    await reloaded.initialize();
    expect(reloaded.entries, isEmpty);
  });

  test('invalid import and self-register are rejected', () async {
    final a = DeviceIdentityManager(TestVault());
    await a.initialize();
    expect(() => PublicIdentityCard.parse('bad'), throwsFormatException);
    expect(() => PublicIdentityCard.parse('${a.local.card}wrong'), throwsFormatException);
    await expectLater(a.register(
      displayName: 'self',
      identityCard: a.local.card,
      independentlyCheckedFingerprint: a.local.fingerprint,
    ), throwsStateError);
  });

  test('corrupted seed does not regenerate identity', () async {
    final vault = TestVault();
    final a = DeviceIdentityManager(vault);
    await a.initialize();
    final fingerprint = a.local.fingerprint;
    final seedEntry = vault.values.keys.firstWhere((key) => key.contains('.seed.'));
    vault.values[seedEntry] = 'broken';
    await expectLater(DeviceIdentityManager(vault).initialize(), throwsStateError);
    expect(a.local.fingerprint, fingerprint);
  });
}
