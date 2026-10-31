// DEV12-C3B: authenticated network transfer using V2 for new tasks, V1 for
// pre-existing partially received tasks. No plaintext or implicit migration.
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/resume_checkpoint.dart';
import 'package:nearlink/security/linear_resume_checkpoint.dart';
import 'package:nearlink/security/resume_format_router.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'package:nearlink/services/transfer_progress.dart';

const _chunk = 256 * 1024;
class _MemoryVault implements IdentityVault {
  final _v = <String, String>{};
  @override Future<String?> read(String key) async => _v[key];
  @override Future<void> write(String key, String value) async => _v[key] = value;
  @override Future<void> delete(String key) async => _v.remove(key);
}
Future<void> _pair(DeviceIdentityManager a, DeviceIdentityManager b) async {
  await a.register(displayName: 'authenticated test device',
    identityCard: b.local.card,
    independentlyCheckedFingerprint: b.local.fingerprint);
}
Future<File> _source(Directory dir, String name, int size) async {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  final out = await file.open(mode: FileMode.writeOnly);
  final block = List<int>.generate(_chunk, (i) => (i * 7 + 13) % 251);
  try {
    var written = 0;
    while (written < size) {
      final take = (size-written).clamp(0, block.length).toInt();
      await out.writeFrom(block, 0, take);
      written += take;
    }
  } finally { await out.close(); }
  return file;
}
Future<String> _hash(File f) async =>
    (await hashes.sha256.bind(f.openRead()).first).toString();

void main() {
  test('brand-new encrypted offer uses linear-V2 checkpoint, final bytes match', () async {
    final tmp = await Directory.systemTemp.createTemp('linyue_c3b_new_');
    final a = DeviceIdentityManager(_MemoryVault());
    final b = DeviceIdentityManager(_MemoryVault());
    await a.initialize(); await b.initialize();
    await _pair(a,b); await _pair(b,a);
    final sender = SecureFileChannel(a, targetDirectory: Directory('${tmp.path}/sender'));
    final receiving = Directory('${tmp.path}/received');
    final receiver = SecureFileChannel(b, targetDirectory: receiving);
    receiver.askReceiver = (_) async => true;
    var observedV2 = false;
    receiver.onIncomingProgress = (p) {
      if (p.phase == TransferProgressPhase.receiving) {
        if (receiving.existsSync()) {
          observedV2 |= receiving.listSync().any((f) =>
            f.path.contains('.linyue_resume_v2_') && f.path.endsWith('.part'));
        }
      }
    };
    try {
      final source = await _source(tmp, 'new-v2.bin', 21 * 1024 * 1024 + 17);
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      await sender.sendStreamFile(ip: '127.0.0.1', port: receiver.boundPort!,
        remoteFingerprint: b.local.fingerprint, file: source);
      expect(observedV2, isTrue, reason: 'new task must not default to legacy journal');
      final output = File('${receiving.path}/new-v2.bin');
      expect(await output.exists(), isTrue);
      expect(await _hash(output), await _hash(source));
      expect(await receiving.list().where((entity) =>
        entity.path.endsWith('.part')).isEmpty, isTrue);
      print('[DEV12-C3B] V2_NETWORK_SHA256_PASS bytes=${await output.length()}');
    } finally {
      await sender.stop(); await receiver.stop(); await tmp.delete(recursive:true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('already-existing V1 checkpoint resumes with same authenticated task id', () async {
    final tmp = await Directory.systemTemp.createTemp('linyue_c3b_v1_');
    final a = DeviceIdentityManager(_MemoryVault());
    final b = DeviceIdentityManager(_MemoryVault());
    await a.initialize(); await b.initialize();
    await _pair(a,b); await _pair(b,a);
    final sender = SecureFileChannel(a, targetDirectory: Directory('${tmp.path}/sender'));
    final receiving = Directory('${tmp.path}/received');
    final receiver = SecureFileChannel(b, targetDirectory: receiving);
    var prompts = 0;
    receiver.askReceiver = (_) async { prompts++; return true; };
    try {
      final source = await _source(tmp, 'legacy.bin', 22 * 1024 * 1024 + 17);
      final digest = await _hash(source);
      final id = ResumeCheckpointStore.newId();
      final v1 = ResumeCheckpointStore(receiving);
      await receiving.create(recursive:true);
      await v1.create(id: id, peerFingerprint: a.local.fingerprint,
        fileSha256: digest, totalBytes: await source.length());
      final prefix = source.openRead(0, 4*1024*1024);
      final sink = v1.partFile(id).openWrite(mode: FileMode.append);
      await sink.addStream(prefix);
      await sink.flush();
      await sink.close();
      await v1.commit(id, 4*1024*1024);
      await File('${receiving.path}/.linyue_resume_$id.name').writeAsString('legacy.bin',flush:true);
      expect(await ResumeFormatRouter(receiving).choose(id), ResumeCheckpointFormat.legacyV1);
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4,port:0);
      await sender.sendStreamFile(ip:'127.0.0.1', port:receiver.boundPort!,
        remoteFingerprint:b.local.fingerprint, file:source,
        resumeTaskId:id, expectedSha256:digest);
      expect(prompts, 0, reason:'previously consented V1 task must not re-prompt');
      expect(await _hash(File('${receiving.path}/legacy.bin')), digest);
      print('[DEV12-C3B] V1_EXISTING_RESUME_PASS');
    } finally {
      await sender.stop(); await receiver.stop(); await tmp.delete(recursive:true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('V1+V2 collision and missing part refuse routing without modifying files', () async {
    final tmp = await Directory.systemTemp.createTemp('linyue_c3b_collision_');
    try {
      final id = ResumeCheckpointStore.newId();
      final v1 = ResumeCheckpointStore(tmp);
      final v2 = LinearResumeCheckpointStore(tmp);
      final fingerprint = List<String>.filled(64, 'a').join();
      final digest = List<String>.filled(64, 'b').join();
      await v1.create(id:id, peerFingerprint:fingerprint, fileSha256:digest,
        totalBytes:24*1024*1024);
      await v2.create(id:id, peerFingerprint:fingerprint, fileSha256:digest,
        totalBytes:24*1024*1024);
      final v1Path = v1.partFile(id);
      final v2Path = v2.partFile(id);
      await expectLater(ResumeFormatRouter(tmp).choose(id), throwsStateError);
      expect(await v1Path.exists(), isTrue);
      expect(await v2Path.exists(), isTrue);
      await v1.discard(id);
      await v2Path.delete(); // V2 journal slot survives but .part disappeared.
      expect(await ResumeFormatRouter(tmp).choose(id), ResumeCheckpointFormat.linearV2);
      await expectLater(v2.inspect(id:id,expectedPeer:fingerprint,
        expectedSha256:digest,expectedSize:24*1024*1024),throwsStateError);
      print('[DEV12-C3B] COLLISION_FAIL_CLOSED_PASS');
    } finally { await tmp.delete(recursive:true); }
  });
}
