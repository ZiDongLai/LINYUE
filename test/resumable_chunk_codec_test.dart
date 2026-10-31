import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/resume_checkpoint.dart';
import 'package:nearlink/security/resumable_chunk_codec.dart';

const peer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Future<File> make(Directory d, int size) async {
  final f = File('${d.path}/input.bin');
  final writer = await f.open(mode: FileMode.writeOnly);
  final block = List<int>.generate(resumeCheckpointChunkSize, (i) => i % 233);
  try {
    var pos = 0;
    while (pos < size) {
      final n = (size-pos) < block.length ? size-pos : block.length;
      await writer.writeFrom(block, 0, n); pos += n;
    }
  } finally { await writer.close(); }
  return f;
}
void main() {
  test('interrupted transfer resumes at committed chunk using FRESH key', () async {
    final dir = await Directory.systemTemp.createTemp('linyue_d2_');
    try {
      final count = 7 * resumeCheckpointChunkSize + 17;
      final src = await make(dir, count);
      final sha = (await crypto.sha256.bind(src.openRead()).first).toString();
      final store = ResumeCheckpointStore(Directory('${dir.path}/receiver'));
      final id = ResumeCheckpointStore.newId();
      await store.create(id: id, peerFingerprint: peer, fileSha256: sha, totalBytes: count);
      final codec = ResumableChunkCodec();
      final key1 = await AesGcm.with256bits().newSecretKey();
      final context1 = List<int>.filled(32, 1);
      final frames = <List<int>>[];
      await codec.encodeRemaining(source: src, key: key1, context: context1,
        total: count, offset: 0, sha256: sha, writeFrame: (f) async => frames.add(f));
      // Fail after first 4 chunks: no complete authenticated EOF.
      await expectLater(codec.decodeRemaining(
        encrypted: Stream<List<int>>.fromIterable(frames.take(4)),
        store: store, id: id, key: key1, context: context1, total: count,
        offset: 0, sha256: sha), throwsA(anything));
      // The 4 chunks were flushed on receiver but only committed records
      // may be trusted. Fresh session truncates any uncommitted tail.
      final point = await store.inspect(id: id, expectedPeer: peer,
        expectedSha256: sha, expectedSize: count);
      final start = await store.truncateUncommitted(point);
      final key2 = await AesGcm.with256bits().newSecretKey();
      final context2 = List<int>.filled(32, 2);
      final frames2 = <List<int>>[];
      await codec.encodeRemaining(source: src, key: key2, context: context2,
        total: count, offset: start, sha256: sha,
        writeFrame: (f) async => frames2.add(f));
      await codec.decodeRemaining(encrypted: Stream<List<int>>.fromIterable(frames2),
        store: store, id: id, key: key2, context: context2,
        total: count, offset: start, sha256: sha);
      expect((await crypto.sha256.bind(store.partFile(id).openRead()).first).toString(), sha);
      expect((await store.inspect(id: id, expectedPeer: peer,
        expectedSha256: sha, expectedSize: count)).checkpoint.committedBytes, count);
    } finally { await dir.delete(recursive: true); }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('wrong offset, wrong session keys, and altered frames are rejected', () async {
    final dir = await Directory.systemTemp.createTemp('linyue_d2_tamper_');
    try {
      final src = await make(dir, resumeCheckpointChunkSize+9);
      final sha = (await crypto.sha256.bind(src.openRead()).first).toString();
      final codec = ResumableChunkCodec();
      final key = await AesGcm.with256bits().newSecretKey();
      final wrong = await AesGcm.with256bits().newSecretKey();
      final ctx = List<int>.filled(32, 3);
      await expectLater(codec.encodeRemaining(source: src, key: key,
        context: ctx, total: await src.length(), offset: 1,
        sha256: sha, writeFrame: (_) async {}), throwsFormatException);
      final frames = <List<int>>[];
      await codec.encodeRemaining(source: src, key: key, context: ctx,
        total: await src.length(), offset: 0, sha256: sha,
        writeFrame: (f) async => frames.add(f));
      final store = ResumeCheckpointStore(Directory('${dir.path}/received'));
      final id = ResumeCheckpointStore.newId();
      await store.create(id:id, peerFingerprint:peer, fileSha256:sha, totalBytes:await src.length());
      await expectLater(codec.decodeRemaining(
        encrypted: Stream<List<int>>.fromIterable(frames), store:store,
        id:id, key:wrong, context:ctx, total:await src.length(), offset:0,
        sha256:sha), throwsA(anything));
      final tamper=frames.map((f)=>List<int>.of(f)).toList();
      tamper[0][35]^=1;
      await expectLater(codec.decodeRemaining(
        encrypted: Stream<List<int>>.fromIterable(tamper), store:store,
        id:id, key:key, context:ctx, total:await src.length(), offset:0,
        sha256:sha), throwsA(anything));
    } finally { await dir.delete(recursive:true); }
  });
}
