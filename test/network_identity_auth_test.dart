import 'dart:io';
import 'dart:convert';

import 'package:nearlink/security/secure_core.dart' show secureRandomBytes;

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/network_identity_auth.dart';

class _MemoryVault implements IdentityVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

Future<void> _register(DeviceIdentityManager who, DeviceIdentityManager other) async {
  await who.register(
    displayName: 'Test remote device',
    identityCard: other.local.card,
    independentlyCheckedFingerprint: other.local.fingerprint,
  );
}

void main() {
  test('mutual Ed25519 proof works only with reciprocal pinned identities', () async {
    final alice = DeviceIdentityManager(_MemoryVault());
    final bob = DeviceIdentityManager(_MemoryVault());
    await alice.initialize();
    await bob.initialize();
    await _register(alice, bob);
    await _register(bob, alice);
    final server = IdentityProofServer(bob);
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    try {
      final result = await IdentityProofClient(alice).verify(
        remoteIp: '127.0.0.1',
        port: server.port!,
        target: alice.entries.single,
      );
      expect(result.fingerprint, bob.local.fingerprint);
    } finally { await server.stop(); }
  });

  test('peer not registered by responder is rejected', () async {
    final alice = DeviceIdentityManager(_MemoryVault());
    final bob = DeviceIdentityManager(_MemoryVault());
    await alice.initialize();
    await bob.initialize();
    await _register(alice, bob);
    final server = IdentityProofServer(bob);
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    try {
      await expectLater(
        IdentityProofClient(alice).verify(
          remoteIp: '127.0.0.1', port: server.port!, target: alice.entries.single,
        ),
        throwsA(isA<StateError>()),
      );
    } finally { await server.stop(); }
  });

  test('impostor with a different private key is rejected by pinned identity', () async {
    final alice = DeviceIdentityManager(_MemoryVault());
    final bob = DeviceIdentityManager(_MemoryVault());
    final impostor = DeviceIdentityManager(_MemoryVault());
    await alice.initialize();
    await bob.initialize();
    await impostor.initialize();
    await _register(alice, bob);
    await _register(impostor, alice);
    final server = IdentityProofServer(impostor);
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    try {
      await expectLater(
        IdentityProofClient(alice).verify(
          remoteIp: '127.0.0.1', port: server.port!, target: alice.entries.single,
        ),
        throwsA(isA<StateError>()),
      );
    } finally { await server.stop(); }
  });

  test('revocation makes new proofs fail', () async {
    final alice = DeviceIdentityManager(_MemoryVault());
    final bob = DeviceIdentityManager(_MemoryVault());
    await alice.initialize();
    await bob.initialize();
    await _register(alice, bob);
    await _register(bob, alice);
    final server = IdentityProofServer(bob);
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    try {
      await IdentityProofClient(alice).verify(
        remoteIp: '127.0.0.1', port: server.port!, target: alice.entries.single,
      );
      await bob.revoke(alice.local.fingerprint);
      await expectLater(
        IdentityProofClient(alice).verify(
          remoteIp: '127.0.0.1', port: server.port!, target: alice.entries.single,
        ),
        throwsA(isA<StateError>()),
      );
    } finally { await server.stop(); }
  });

  test('challenge cannot be replayed; modified client proof is rejected', () async {
    final alice = DeviceIdentityManager(_MemoryVault());
    final bob = DeviceIdentityManager(_MemoryVault());
    await alice.initialize();
    await bob.initialize();
    await _register(alice, bob);
    await _register(bob, alice);
    final server = IdentityProofServer(bob);
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    final client = HttpClient();
    Future<HttpClientResponse> post(String path, Map<String, dynamic> obj) async {
      final request = await client.postUrl(Uri(
        scheme: 'http', host: '127.0.0.1', port: server.port!, path: path,
      ));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(obj));
      return request.close();
    }
    try {
      final nonceA = base64Url.encode(secureRandomBytes(32)).replaceAll('=', '');
      final start = await post('/begin', {
        'version': identityProofVersion,
        'initiator': alice.local.card,
        'expectedResponder': bob.local.card,
        'clientNonce': nonceA,
      });
      expect(start.statusCode, 200);
      final data = jsonDecode(await start.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final transcript = utf8.encode([
        identityProofVersion, 'initiator-finish', data['id'],
        alice.local.card, bob.local.card, nonceA, data['serverNonce'],
      ].join('|'));
      final signature = await alice.local.sign(transcript);
      final sig = base64Url.encode(signature.bytes).replaceAll('=', '');
      final begin = {
        'version': identityProofVersion,
        'id': data['id'],
        'proof': sig,
      };
      // Invalid proof consumes the challenge, so a later valid replay is rejected.
      final corrupted = Map<String, dynamic>.from(begin);
      corrupted['proof'] = base64Url.encode(List<int>.filled(64, 0)).replaceAll('=', '');
      final tamper = await post('/finish', corrupted);
      expect(tamper.statusCode, 403);
      await tamper.drain();
      final replay = await post('/finish', begin);
      expect(replay.statusCode, 403);
      await replay.drain();
    } finally {
      client.close(force: true);
      await server.stop();
    }
  });

  test('disallow public IPv4, invalid addresses, and non-canonical input', () {
    expect(IdentityProofClient.isAllowedTestIpv4('192.168.1.6'), isTrue);
    expect(IdentityProofClient.isAllowedTestIpv4('10.0.0.5'), isTrue);
    expect(IdentityProofClient.isAllowedTestIpv4('172.31.9.1'), isTrue);
    expect(IdentityProofClient.isAllowedTestIpv4('127.0.0.1'), isTrue);
    expect(IdentityProofClient.isAllowedTestIpv4('172.32.0.1'), isFalse);
    expect(IdentityProofClient.isAllowedTestIpv4('8.8.8.8'), isFalse);
    expect(IdentityProofClient.isAllowedTestIpv4('192.168.001.1'), isFalse);
  });
}
