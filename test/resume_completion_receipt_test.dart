import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/resume_checkpoint.dart';
import 'package:nearlink/security/resume_completion_receipt.dart';

const String peerA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String peerB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Future<({ResumeCheckpointStore store, ResumeCompletionLedger ledger,
  String task, String digest, int size})> stage(Directory parent) async {
  final dir = Directory('${parent.path}${Platform.pathSeparator}received');
  final store = ResumeCheckpointStore(dir);
  final ledger = ResumeCompletionLedger(store);
  final task = ResumeCheckpointStore.newId();
  final bytes = List<int>.generate(resumeCheckpointChunkSize + 7, (i) => i % 249);
  final digest = crypto.sha256.convert(bytes).toString();
  await store.create(id: task, peerFingerprint: peerA,
    fileSha256: digest, totalBytes: bytes.length);
  await store.partFile(task).writeAsBytes(bytes, flush: true);
  await store.commit(task, bytes.length);
  return (store: store, ledger: ledger, task: task, digest: digest, size: bytes.length);
}

void main() {
  test('lost success response: completed file is reused without duplicates', () async {
    final temp = await Directory.systemTemp.createTemp('linyue_d3_ack_');
    try {
      final p = await stage(temp);
      await p.ledger.prepare(id: p.task, fingerprint: peerA,
        digest: p.digest, total: p.size,
        originalName: 'video.mp4', savedName: 'video.mp4');
      await p.store.partFile(p.task).rename('${p.store.directory.path}${Platform.pathSeparator}video.mp4');
      await p.store.discard(p.task);
      // Sender did not receive the previous encrypted response.
      for (var n = 0; n < 2; n++) {
        final found = await p.ledger.reconcile(id: p.task,
          fingerprint: peerA, digest: p.digest,
          total: p.size, originalName: 'video.mp4');
        expect(found?.path.endsWith('video.mp4'), isTrue);
        expect(await found!.length(), p.size);
      }
      expect(await File('${p.store.directory.path}${Platform.pathSeparator}video_1.mp4').exists(), isFalse);
    } finally { await temp.delete(recursive: true); }
  });

  test('crash between completion-intent write and final rename recovers safely', () async {
    final temp = await Directory.systemTemp.createTemp('linyue_d3_recover_');
    try {
      final p = await stage(temp);
      await p.ledger.prepare(id: p.task, fingerprint: peerA,
        digest: p.digest, total: p.size,
        originalName: 'footage.mov', savedName: 'footage.mov');
      final recovered = await p.ledger.reconcile(id: p.task,
        fingerprint: peerA, digest: p.digest,
        total: p.size, originalName: 'footage.mov');
      expect(await recovered!.exists(), isTrue);
      expect((await crypto.sha256.bind(recovered.openRead()).first).toString(), p.digest);
      expect(await p.store.partFile(p.task).exists(), isFalse);
    } finally { await temp.delete(recursive: true); }
  });

  test('wrong identity, wrong content or renamed source cannot claim completion', () async {
    final temp = await Directory.systemTemp.createTemp('linyue_d3_mismatch_');
    try {
      final p = await stage(temp);
      await p.ledger.prepare(id: p.task, fingerprint: peerA,
        digest: p.digest, total: p.size,
        originalName: 'a.bin', savedName: 'a.bin');
      await expectLater(p.ledger.reconcile(id: p.task,
        fingerprint: peerB, digest: p.digest,
        total: p.size, originalName: 'a.bin'), throwsStateError);
      await expectLater(p.ledger.reconcile(id: p.task,
        fingerprint: peerA, digest: '0000000000000000000000000000000000000000000000000000000000000000',
        total: p.size, originalName: 'a.bin'), throwsStateError);
      await expectLater(p.ledger.reconcile(id: p.task,
        fingerprint: peerA, digest: p.digest,
        total: p.size, originalName: 'b.bin'), throwsStateError);
    } finally { await temp.delete(recursive: true); }
  });

  test('modified completed file is never acknowledged', () async {
    final temp = await Directory.systemTemp.createTemp('linyue_d3_tamper_');
    try {
      final p = await stage(temp);
      await p.ledger.prepare(id: p.task, fingerprint: peerA,
        digest: p.digest, total: p.size,
        originalName: 'a.bin', savedName: 'a.bin');
      final finalFile = await p.store.partFile(p.task).rename(
        '${p.store.directory.path}${Platform.pathSeparator}a.bin');
      final handle = await finalFile.open(mode: FileMode.writeOnlyAppend);
      try { await handle.writeByte(1); await handle.flush(); } finally { await handle.close(); }
      await expectLater(p.ledger.reconcile(id: p.task,
        fingerprint: peerA, digest: p.digest,
        total: p.size, originalName: 'a.bin'), throwsStateError);
      expect(await File('${p.store.directory.path}${Platform.pathSeparator}a_1.bin').exists(), isFalse);
    } finally { await temp.delete(recursive: true); }
  });

  test('incomplete data cannot be recorded as completed', () async {
    final temp = await Directory.systemTemp.createTemp('linyue_d3_incomplete_');
    try {
      final p = await stage(temp);
      final partial = p.store.partFile(p.task);
      final handle = await partial.open(mode: FileMode.writeOnly);
      try { await handle.truncate(1); await handle.flush(); } finally { await handle.close(); }
      await expectLater(p.ledger.prepare(id: p.task, fingerprint: peerA,
        digest: p.digest, total: p.size,
        originalName: 'a.bin', savedName: 'a.bin'), throwsA(anything));
      expect(await p.ledger.receiptFile(p.task).exists(), isFalse);
    } finally { await temp.delete(recursive: true); }
  });
}
