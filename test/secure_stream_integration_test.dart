import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'package:nearlink/services/transfer_progress.dart';

class _MemoryVault implements IdentityVault {
  final _store = <String, String>{};
  @override
  Future<String?> read(String key) async => _store[key];
  @override
  Future<void> write(String key, String value) async { _store[key] = value; }
  @override
  Future<void> delete(String key) async { _store.remove(key); }
}

Future<void> _trust(DeviceIdentityManager a, DeviceIdentityManager b) async {
  await a.register(displayName: 'Test peer', identityCard: b.local.card,
    independentlyCheckedFingerprint: b.local.fingerprint);
}

Future<File> _makeFile(Directory dir, String name, int size) async {
  final file = File('${dir.path}/$name');
  final writer = await file.open(mode: FileMode.writeOnly);
  final data = List<int>.generate(256 * 1024, (i) => i % 251);
  try {
    var written = 0;
    while (written < size) {
      final count = (size - written) < data.length ? size - written : data.length;
      await writer.writeFrom(data, 0, count);
      written += count;
    }
  } finally {
    await writer.close();
  }
  return file;
}

Future<String> _digest(File file) async =>
  (await hashes.sha256.bind(file.openRead()).first).toString();

void main() {
  test('25 MiB encrypted stream + small file rotate authenticated sessions and verify disk bytes', () async {
    final a = DeviceIdentityManager(_MemoryVault());
    final b = DeviceIdentityManager(_MemoryVault());
    await a.initialize(); await b.initialize();
    await _trust(a, b); await _trust(b, a);
    final dir = await Directory.systemTemp.createTemp('linyue_10b2_');
    final sender = SecureFileChannel(a, targetDirectory: Directory('${dir.path}/unused'));
    final receiver = SecureFileChannel(b, targetDirectory: Directory('${dir.path}/received'));
    final phases = <TransferProgressPhase>[];
    receiver.askReceiver = (_) async => true;
    var prompts = 0;
    receiver.askReceiver = (offer) async {
      prompts++;
      expect(offer.fingerprint, a.local.fingerprint);
      return true;
    };
    try {
      final source = await _makeFile(dir, 'large.bin', 25 * 1024 * 1024 + 19);
      final small = File('${dir.path}/small.txt')..writeAsStringSync('small unchanged DEV10-A path');
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await sender.sendStreamFile(
        ip: '127.0.0.1', port: receiver.boundPort!,
        remoteFingerprint: b.local.fingerprint, file: source,
        onProgress: (u) { phases.add(u.phase); },
      );
      final received = File('${dir.path}/received/large.bin');
      expect(await received.exists(), isTrue);
      expect(await received.length(), await source.length());
      expect(await _digest(received), await _digest(source));
      expect(phases, contains(TransferProgressPhase.completed));
      expect(phases.last, TransferProgressPhase.completed);
      expect((await Directory('${dir.path}/received').list().toList())
          .where((e) => e.path.contains('.linyue_part_')), isEmpty);

      // A completed resumable stream deliberately retires the sender session.
      // Signed re-authentication is automatic and is NOT a new six-digit SAS pairing.
      final handshakesAfterStream = sender.handshakeCount;
      expect(handshakesAfterStream, greaterThanOrEqualTo(1));
      await sender.sendFile(ip: '127.0.0.1', port: receiver.boundPort!,
        remoteFingerprint: b.local.fingerprint, file: small);
      expect(await File('${dir.path}/received/small.txt').readAsString(),
        'small unchanged DEV10-A path');
      expect(sender.handshakeCount, handshakesAfterStream + 1,
        reason: 'stream completion requires a fresh signed session for the next file; '
          'handshake count does not count manual SAS pairing prompts');
      expect(prompts, 2, reason: 'file consent remains per file');
    } finally {
      await sender.stop(); await receiver.stop();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('receiver refusing a large file creates no .part or destination', () async {
    final a = DeviceIdentityManager(_MemoryVault());
    final b = DeviceIdentityManager(_MemoryVault());
    await a.initialize(); await b.initialize();
    await _trust(a, b); await _trust(b, a);
    final dir = await Directory.systemTemp.createTemp('linyue_10b2_refuse_');
    final sender = SecureFileChannel(a, targetDirectory: Directory('${dir.path}/unused'));
    final receiver = SecureFileChannel(b, targetDirectory: Directory('${dir.path}/received'));
    receiver.askReceiver = (_) async => false;
    try {
      final source = await _makeFile(dir, 'nope.bin', secureFileMaxBytes + 4096);
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await expectLater(sender.sendStreamFile(ip: '127.0.0.1',
        port: receiver.boundPort!, remoteFingerprint: b.local.fingerprint,
        file: source), throwsA(isA<StateError>()));
      final receivedDir = Directory('${dir.path}/received');
      expect(await receivedDir.exists(), isFalse);
    } finally {
      await sender.stop(); await receiver.stop();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('file larger than the current secure stream pilot is rejected before connecting', () async {
    final a = DeviceIdentityManager(_MemoryVault());
    final b = DeviceIdentityManager(_MemoryVault());
    await a.initialize(); await b.initialize();
    await _trust(a, b);
    final dir = await Directory.systemTemp.createTemp('linyue_10b2_cap_');
    final sender = SecureFileChannel(a, targetDirectory: Directory('${dir.path}/unused'));
    try {
      final file = File('${dir.path}/over_cap.bin');
      final writer = await file.open(mode: FileMode.writeOnly);
      try {
        await writer.setPosition(secureStreamPilotMaxBytes);
        await writer.writeByte(1);
      } finally {
        await writer.close();
      }
      await expectLater(sender.sendStreamFile(ip: '127.0.0.1', port: 46732,
        remoteFingerprint: b.local.fingerprint, file: file),
        throwsA(isA<StateError>()));
      expect(sender.handshakeCount, 0);
    } finally {
      await sender.stop();
      await dir.delete(recursive: true);
    }
  });
}
