import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/linear_resume_checkpoint.dart';
import 'package:nearlink/security/resume_checkpoint.dart';

void main() {
  test('production V2 commits 64 MiB in linear steps then verifies whole prefix', () async {
    final root = await Directory.systemTemp.createTemp('linyue_c3b_perf_');
    try {
      const total = 64 * 1024 * 1024;
      const step = 4 * 1024 * 1024;
      final source = File('${root.path}/source.bin');
      final out = source.openWrite();
      final block = List<int>.generate(256*1024, (i) => i % 253);
      for(var i=0;i<total~/block.length;i++) { out.add(block); }
      await out.close();
      final sha=(await hashes.sha256.bind(source.openRead()).first).toString();
      final store=LinearResumeCheckpointStore(Directory('${root.path}/receiver'));
      final id=ResumeCheckpointStore.newId();
      final peer=List<String>.filled(64, 'f').join();
      await store.create(id:id,peerFingerprint:peer,fileSha256:sha,totalBytes:total);
      final part=store.partFile(id);
      final writer=part.openWrite(mode:FileMode.append);
      final sourceReader=await source.open(mode:FileMode.read);
      final watch=Stopwatch()..start();
      try {
        for(var offset=step;offset<=total;offset+=step) {
          var remaining=step;
          while(remaining>0) {
            final bytes=await sourceReader.read(remaining.clamp(0,256*1024).toInt());
            if(bytes.isEmpty) throw StateError('source truncated');
            writer.add(bytes); remaining-=bytes.length;
          }
          await writer.flush();
          await store.commit(id,offset);
        }
      } finally {
        await sourceReader.close();
        await writer.close();
      }
      watch.stop();
      final inspection=await store.inspect(id:id,expectedPeer:peer,
        expectedSha256:sha,expectedSize:total);
      expect(inspection.record.committed,total);
      // Each new 4-MiB span is hashed once at commit. Finalization hashes
      // the whole file once more (required SHA-256 integrity invariant).
      expect(store.commitHashedBytes,total*2);
      expect(store.inspectionHashedBytes,total*2);
      print('[DEV12-C3B] PRODUCTION_V2_LINEAR_PASS commit_ms=${watch.elapsedMilliseconds} '
        'commit_hash_mib=${store.commitHashedBytes~/1024~/1024} '
        'resume_inspection_hash_mib=${store.inspectionHashedBytes~/1024~/1024}');
    } finally {await root.delete(recursive:true);}
  },timeout:const Timeout(Duration(minutes:4)));
}
