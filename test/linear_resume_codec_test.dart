// Standalone V2 crypto frame and durable prefix recovery regression.
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/linear_resume_checkpoint.dart';
import 'package:nearlink/security/resume_checkpoint.dart';
import 'package:nearlink/security/resumable_chunk_codec.dart';

void main() {
  test('interrupted V2 resumes only after rehash and uses a fresh key', () async {
    final tmp = await Directory.systemTemp.createTemp('linyue_c3b_resume_');
    try {
      const size = 9 * 1024 * 1024 + 17;
      final src = File('${tmp.path}/source.bin');
      final sink = src.openWrite();
      final block = List<int>.generate(256*1024, (i) => i % 251);
      for (var i = 0; i < size~/block.length; i++) { sink.add(block); }
      sink.add(block.take(size%block.length).toList());
      await sink.close();
      final sha = (await hashes.sha256.bind(src.openRead()).first).toString();
      final store = LinearResumeCheckpointStore(Directory('${tmp.path}/received'));
      final id = ResumeCheckpointStore.newId();
      final peer=List<String>.filled(64, 'a').join();
      await store.create(id:id,peerFingerprint:peer,fileSha256:sha,totalBytes:size);
      final key1 = await AesGcm.with256bits().newSecretKey();
      final codec = ResumableChunkCodec();
      final ctx1 = List<int>.filled(32,1);
      final frames=<List<int>>[];
      await codec.encodeRemaining(source:src,key:key1,context:ctx1,
        total:size,offset:0,sha256:sha,writeFrame:(b) async => frames.add(b));
      // 20 frames = 5 MiB; first 4 MiB checkpoint is durable.
      await expectLater(codec.decodeRemaining(
        encrypted: Stream<List<int>>.fromIterable(frames.take(20)),
        linearStore:store,id:id,key:key1,context:ctx1,total:size,offset:0,
        sha256:sha),throwsA(anything));
      final checkpoint = await store.inspect(id:id,expectedPeer:peer,
        expectedSha256:sha,expectedSize:size);
      expect(checkpoint.record.committed,4*1024*1024);
      final offset=await store.truncateUncommitted(checkpoint);
      expect(await store.partFile(id).length(),offset);
      final key2=await AesGcm.with256bits().newSecretKey();
      final ctx2=List<int>.filled(32,2);
      final more=<List<int>>[];
      await codec.encodeRemaining(source:src,key:key2,context:ctx2,
        total:size,offset:offset,sha256:sha,
        writeFrame:(b) async => more.add(b));
      await codec.decodeRemaining(encrypted:Stream<List<int>>.fromIterable(more),
        linearStore:store,id:id,key:key2,context:ctx2,
        total:size,offset:offset,sha256:sha);
      expect((await hashes.sha256.bind(store.partFile(id).openRead()).first).toString(),sha);
      expect((await store.inspect(id:id, expectedPeer:peer,
        expectedSha256:sha,expectedSize:size)).record.committed,size);
      print('[DEV12-C3B] V2_FRESH_KEY_RESUME_PASS');
    } finally { await tmp.delete(recursive:true); }
  },timeout:const Timeout(Duration(minutes:3)));
}
