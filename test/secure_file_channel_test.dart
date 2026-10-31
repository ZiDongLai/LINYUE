import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/secure_file_channel.dart';

class _Vault implements IdentityVault {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async { _map[key] = value; }
  @override
  Future<void> delete(String key) async { _map.remove(key); }
}

Future<void> _enroll(DeviceIdentityManager a, DeviceIdentityManager b) async {
  // In production DEV8 provides an independently checked 6-digit SAS.
  // This test explicitly models identities that have ALREADY been paired.
  await a.register(displayName: 'Other', identityCard: b.local.card,
      independentlyCheckedFingerprint: b.local.fingerprint);
}

void main() {
  test('registered peers transfer encrypted bytes and reuse a session', () async {
    final a = DeviceIdentityManager(_Vault());
    final b = DeviceIdentityManager(_Vault());
    // initialize is asynchronous: await before accessing local identity.
    await a.initialize();
    await b.initialize();
    await _enroll(a, b);
    await _enroll(b, a);
    final dir = await Directory.systemTemp.createTemp('linyue_secure9a_');
    final source = File('${dir.path}/secret.txt');
    await source.writeAsString('DEV9A experimental secret file 12345');
    final receiver = SecureFileChannel(b, targetDirectory: Directory('${dir.path}/received'));
    final sender = SecureFileChannel(a, targetDirectory: Directory('${dir.path}/not_used'));
    var requests = 0;
    receiver.askReceiver = (offer) async {
      requests++;
      expect(offer.fingerprint, a.local.fingerprint);
      return true;
    };
    try {
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await sender.sendFile(ip: '127.0.0.1', port: receiver.boundPort!,
        remoteFingerprint: b.local.fingerprint, file: source);
      await sender.sendFile(ip: '127.0.0.1', port: receiver.boundPort!,
        remoteFingerprint: b.local.fingerprint, file: source);
      expect(sender.handshakeCount, 1, reason: 'no repeated pairing or handshake per file');
      expect(requests, 2, reason: 'receiving files still requires individual consent');
      expect(await File('${dir.path}/received/secret.txt').readAsString(), await source.readAsString());
      expect(await File('${dir.path}/received/secret_1.txt').readAsString(), await source.readAsString());
    } finally {
      await sender.stop();
      await receiver.stop();
      await dir.delete(recursive: true);
    }
  });

  test('unregistered identity is rejected with no fallback or saved file', () async {
    final a = DeviceIdentityManager(_Vault());
    final b = DeviceIdentityManager(_Vault());
    await a.initialize();
    await b.initialize();
    // a trusts b; b has NOT trusted a.
    await _enroll(a, b);
    final dir = await Directory.systemTemp.createTemp('linyue_unpaired_');
    final source = File('${dir.path}/secret.txt')..writeAsStringSync('no plaintext fallback');
    final receiver = SecureFileChannel(b, targetDirectory: Directory('${dir.path}/received'));
    final sender = SecureFileChannel(a, targetDirectory: Directory('${dir.path}/unused'));
    try {
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await expectLater(sender.sendFile(ip: '127.0.0.1',
        port: receiver.boundPort!, remoteFingerprint: b.local.fingerprint,
        file: source), throwsA(isA<StateError>()));
      expect(await Directory('${dir.path}/received').exists(), isFalse);
    } finally {
      await sender.stop();
      await receiver.stop();
      await dir.delete(recursive: true);
    }
  });

  test('receiver refusal writes no file and does not reuse uncertain state', () async {
    final a = DeviceIdentityManager(_Vault());
    final b = DeviceIdentityManager(_Vault());
    await a.initialize(); await b.initialize();
    await _enroll(a, b); await _enroll(b, a);
    final dir = await Directory.systemTemp.createTemp('linyue_refusal_');
    final file = File('${dir.path}/refused.bin')..writeAsBytesSync([1, 2, 3, 4]);
    final receiver = SecureFileChannel(b, targetDirectory: Directory('${dir.path}/received'));
    final sender = SecureFileChannel(a, targetDirectory: Directory('${dir.path}/unused'));
    receiver.askReceiver = (_) async => false;
    try {
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await expectLater(sender.sendFile(ip: '127.0.0.1', port: receiver.boundPort!,
          remoteFingerprint: b.local.fingerprint, file: file), throwsA(isA<StateError>()));
      expect(await Directory('${dir.path}/received').exists(), isFalse);
    } finally {
      await sender.stop(); await receiver.stop(); await dir.delete(recursive: true);
    }
  });

  test('local identity revocation blocks a previously approved session', () async {
    final a = DeviceIdentityManager(_Vault());
    final b = DeviceIdentityManager(_Vault());
    await a.initialize(); await b.initialize();
    await _enroll(a, b); await _enroll(b, a);
    final dir = await Directory.systemTemp.createTemp('linyue_revoke_');
    final file = File('${dir.path}/sample.txt')..writeAsStringSync('hello');
    final receiver = SecureFileChannel(b, targetDirectory: Directory('${dir.path}/received'));
    final sender = SecureFileChannel(a, targetDirectory: Directory('${dir.path}/unused'));
    receiver.askReceiver = (_) async => true;
    try {
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await sender.sendFile(ip: '127.0.0.1', port: receiver.boundPort!,
        remoteFingerprint: b.local.fingerprint, file: file);
      await b.revoke(a.local.fingerprint);
      await expectLater(sender.sendFile(ip: '127.0.0.1', port: receiver.boundPort!,
          remoteFingerprint: b.local.fingerprint, file: file), throwsA(isA<StateError>()));
      expect((await Directory('${dir.path}/received').list().toList()).length, 1);
    } finally {
      await sender.stop(); await receiver.stop(); await dir.delete(recursive: true);
    }
  });
}
