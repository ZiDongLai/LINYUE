import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'package:nearlink/services/transfer_progress.dart';

class _Vault implements IdentityVault {
  final Map<String, String> values = {};
  @override Future<String?> read(String key) async => values[key];
  @override Future<void> write(String key, String value) async { values[key] = value; }
  @override Future<void> delete(String key) async { values.remove(key); }
}

void main() {
  test('real encrypted send and receive progress; completed only with ACK', () async {
    final a = DeviceIdentityManager(_Vault()), b = DeviceIdentityManager(_Vault());
    await a.initialize(); await b.initialize();
    await a.register(displayName: 'B', identityCard: b.local.card,
      independentlyCheckedFingerprint: b.local.fingerprint);
    await b.register(displayName: 'A', identityCard: a.local.card,
      independentlyCheckedFingerprint: a.local.fingerprint);
    final temp = await Directory.systemTemp.createTemp('ly_progress10a_');
    final source = File('${temp.path}/sample.bin');
    await source.writeAsBytes(List<int>.generate(150000, (i) => i % 251));
    final r = SecureFileChannel(b, targetDirectory: Directory('${temp.path}/received'));
    final s = SecureFileChannel(a, targetDirectory: Directory('${temp.path}/none'));
    final sent = <TransferProgressInfo>[], received = <TransferProgressInfo>[];
    r.askReceiver = (_) async => true;
    r.onIncomingProgress = received.add;
    try {
      await r.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await s.sendFile(ip: '127.0.0.1', port: r.boundPort!,
        remoteFingerprint: b.local.fingerprint, file: source,
        onProgress: sent.add);
      expect(sent.where((e) => e.phase == TransferProgressPhase.uploading), isNotEmpty);
      expect(received.where((e) => e.phase == TransferProgressPhase.receiving), isNotEmpty);
      expect(sent.last.phase, TransferProgressPhase.completed);
      expect(received.last.phase, TransferProgressPhase.completed);
      expect(sent.last.safeBytes, 150000);
      expect(received.last.safeBytes, 150000);
      final uploaded = sent.where((e) => e.phase == TransferProgressPhase.uploading)
        .map((e) => e.safeBytes).toList();
      expect(uploaded, orderedEquals([...uploaded]..sort()));
      final output = File('${temp.path}/received/sample.bin');
      expect(await output.readAsBytes(), await source.readAsBytes());
    } finally {
      await s.stop(); await r.stop(); await temp.delete(recursive: true);
    }
  });

  test('receiver rejects: sender never emits completed and no file saved', () async {
    final a = DeviceIdentityManager(_Vault()), b = DeviceIdentityManager(_Vault());
    await a.initialize(); await b.initialize();
    await a.register(displayName: 'B', identityCard: b.local.card,
      independentlyCheckedFingerprint: b.local.fingerprint);
    await b.register(displayName: 'A', identityCard: a.local.card,
      independentlyCheckedFingerprint: a.local.fingerprint);
    final temp = await Directory.systemTemp.createTemp('ly_progress_decline_');
    final source = File('${temp.path}/sample.bin')..writeAsBytesSync([1, 2, 3]);
    final r = SecureFileChannel(b, targetDirectory: Directory('${temp.path}/received'));
    final s = SecureFileChannel(a, targetDirectory: Directory('${temp.path}/none'));
    final phases = <TransferProgressPhase>[];
    r.askReceiver = (_) async => false;
    try {
      await r.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await expectLater(s.sendFile(ip: '127.0.0.1', port: r.boundPort!,
        remoteFingerprint: b.local.fingerprint, file: source,
        onProgress: (e) => phases.add(e.phase)), throwsA(isA<StateError>()));
      expect(phases, contains(TransferProgressPhase.failed));
      expect(phases, isNot(contains(TransferProgressPhase.completed)));
      expect(await Directory('${temp.path}/received').exists(), false);
    } finally {
      await s.stop(); await r.stop(); await temp.delete(recursive: true);
    }
  });
}
