import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';

class _Vault implements IdentityVault {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

Future<void> _enroll(DeviceIdentityManager a, DeviceIdentityManager b) =>
  a.register(displayName: 'registered peer', identityCard: b.local.card,
    independentlyCheckedFingerprint: b.local.fingerprint);

void main() {
  test('E17-B1 registered identities exchange AES-GCM text with authenticated ACK', () async {
    final alice = DeviceIdentityManager(_Vault());
    final bob = DeviceIdentityManager(_Vault());
    await alice.initialize(); await bob.initialize();
    await _enroll(alice, bob); await _enroll(bob, alice);
    final dir = await Directory.systemTemp.createTemp('linyue_e17b1_');
    final sender = SecureFileChannel(alice, targetDirectory: Directory('${dir.path}/a'));
    final receiver = SecureFileChannel(bob, targetDirectory: Directory('${dir.path}/b'));
    final delivered = <TextChatMessage>[];
    receiver.onVerifiedTextMessage = (msg, peer) async {
      expect(peer, alice.local.fingerprint);
      delivered.add(msg);
      return true;
    };
    final message = TextChatMessage.create('你好 Windows ↔ Android 🌟\n第二行');
    try {
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      final one = await sender.sendText(ip: '127.0.0.1', port: receiver.boundPort!,
        remoteFingerprint: bob.local.fingerprint, message: message);
      expect(one.messageId, message.id);
      expect(one.alreadyReceived, isFalse);
      final duplicate = await sender.sendText(ip: '127.0.0.1', port: receiver.boundPort!,
        remoteFingerprint: bob.local.fingerprint, message: message);
      expect(duplicate.alreadyReceived, isTrue);
      expect(delivered.map((x) => x.body).toList(), [message.body]);
      expect(sender.handshakeCount, 1);
    } finally {
      await sender.stop(); await receiver.stop(); await dir.delete(recursive: true);
    }
  });

  test('E17-B1 no receiver text handler => capability refused without delivery', () async {
    final alice = DeviceIdentityManager(_Vault());
    final bob = DeviceIdentityManager(_Vault());
    await alice.initialize(); await bob.initialize();
    await _enroll(alice, bob); await _enroll(bob, alice);
    final dir = await Directory.systemTemp.createTemp('linyue_e17b1_old_');
    final sender = SecureFileChannel(alice, targetDirectory: Directory('${dir.path}/a'));
    final receiver = SecureFileChannel(bob, targetDirectory: Directory('${dir.path}/b'));
    try {
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await expectLater(sender.sendText(ip: '127.0.0.1',
        port: receiver.boundPort!, remoteFingerprint: bob.local.fingerprint,
        message: TextChatMessage.create('never sent')), throwsA(isA<StateError>()));
      expect(receiver.handshakeCount, 0);
    } finally {
      await sender.stop(); await receiver.stop(); await dir.delete(recursive: true);
    }
  });

  test('E17-B1 peer not enrolled at receiver cannot establish session', () async {
    final alice = DeviceIdentityManager(_Vault());
    final bob = DeviceIdentityManager(_Vault());
    await alice.initialize(); await bob.initialize();
    await _enroll(alice, bob);
    final dir = await Directory.systemTemp.createTemp('linyue_e17b1_denied_');
    final sender = SecureFileChannel(alice, targetDirectory: Directory('${dir.path}/a'));
    final receiver = SecureFileChannel(bob, targetDirectory: Directory('${dir.path}/b'));
    var count = 0;
    receiver.onVerifiedTextMessage = (_, __) async { count++; return true; };
    try {
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await expectLater(sender.sendText(ip: '127.0.0.1',
        port: receiver.boundPort!, remoteFingerprint: bob.local.fingerprint,
        message: TextChatMessage.create('blocked')), throwsA(isA<StateError>()));
      expect(count, 0);
    } finally {
      await sender.stop(); await receiver.stop(); await dir.delete(recursive: true);
    }
  });

  test('E17-B1 negative ACK when local UI rejects does not falsely consume ID', () async {
    final alice = DeviceIdentityManager(_Vault());
    final bob = DeviceIdentityManager(_Vault());
    await alice.initialize(); await bob.initialize();
    await _enroll(alice, bob); await _enroll(bob, alice);
    final dir = await Directory.systemTemp.createTemp('linyue_e17b1_retry_');
    final sender = SecureFileChannel(alice, targetDirectory: Directory('${dir.path}/a'));
    final receiver = SecureFileChannel(bob, targetDirectory: Directory('${dir.path}/b'));
    var count = 0;
    receiver.onVerifiedTextMessage = (_, __) async {count++;return count > 1;};
    final message = TextChatMessage.create('retry me');
    try {
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await expectLater(sender.sendText(ip: '127.0.0.1',
        port: receiver.boundPort!, remoteFingerprint: bob.local.fingerprint,
        message: message), throwsA(isA<StateError>()));
      final receipt = await sender.sendText(ip: '127.0.0.1',
        port: receiver.boundPort!, remoteFingerprint: bob.local.fingerprint,
        message: message);
      expect(receipt.alreadyReceived, isFalse);
      expect(count, 2);
    } finally {
      await sender.stop(); await receiver.stop(); await dir.delete(recursive: true);
    }
  });
}
