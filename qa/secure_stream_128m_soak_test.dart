// Manual/opt-in 128MiB soak test.  Run using:
// flutter test qa/secure_stream_128m_soak_test.dart
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/secure_file_channel.dart';

class _MemoryVault implements IdentityVault {
  final Map<String,String> items = {};
  @override Future<String?> read(String key) async => items[key];
  @override Future<void> write(String key, String value) async {items[key] = value;}
  @override Future<void> delete(String key) async {items.remove(key);}
}

Future<String> hashFile(File file) async =>
  (await hashes.sha256.bind(file.openRead()).first).toString();

void main() {
  test('128MiB authenticated chunk stream / SHA-256 / accepted receipt', () async {
    const size = 128 * 1024 * 1024 + 17;
    final a = DeviceIdentityManager(_MemoryVault());
    final b = DeviceIdentityManager(_MemoryVault());
    await a.initialize(); await b.initialize();
    await a.register(displayName:'B', identityCard:b.local.card,
      independentlyCheckedFingerprint:b.local.fingerprint);
    await b.register(displayName:'A', identityCard:a.local.card,
      independentlyCheckedFingerprint:a.local.fingerprint);
    final dir = await Directory.systemTemp.createTemp('linyue_dev12a_');
    final source = File('${dir.path}${Platform.pathSeparator}large128.bin');
    final sender = SecureFileChannel(a, targetDirectory: Directory('${dir.path}/unused'));
    final receiver = SecureFileChannel(b, targetDirectory: Directory('${dir.path}/received'));
    receiver.askReceiver = (_) async => true;
    try {
      // Bounded peak memory: a fixed-sized chunk, not a 128 MiB List.
      final writer = await source.open(mode: FileMode.writeOnly);
      final part = List<int>.generate(256*1024, (i) => i % 251);
      try {
        var bytes = 0;
        while(bytes < size) {
          final take = size - bytes < part.length ? size - bytes : part.length;
          await writer.writeFrom(part,0,take);
          bytes += take;
        }
      } finally {await writer.close();}
      await receiver.start(bindAddress:InternetAddress.loopbackIPv4, port:0);
      await sender.sendStreamFile(ip:'127.0.0.1',port:receiver.boundPort!,
        remoteFingerprint:b.local.fingerprint,file:source);
      final saved = File('${dir.path}/received/large128.bin');
      expect(await saved.exists(),isTrue);
      expect(await saved.length(),size);
      expect(await hashFile(saved),await hashFile(source));
    } finally {
      await sender.stop(); await receiver.stop();
      await dir.delete(recursive:true);
    }
  },timeout:const Timeout(Duration(minutes:12)));
}
