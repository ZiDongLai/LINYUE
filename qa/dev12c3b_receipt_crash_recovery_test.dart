import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/linear_resume_checkpoint.dart';
import 'package:nearlink/security/resume_checkpoint.dart';
import 'package:nearlink/security/resume_completion_receipt.dart';

void main() {
  test('V2 saved-intent survives crash before rename; reverify then finalize once', () async {
    final tmp=await Directory.systemTemp.createTemp('linyue_c3b_receipt_');
    try {
      const total=4*1024*1024+17;
      final src=File('${tmp.path}/src.bin');
      final out=src.openWrite();
      final chunk=List<int>.generate(256*1024,(i)=>i%241);
      for(var i=0;i<total~/chunk.length;i++){out.add(chunk);}
      out.add(chunk.take(total%chunk.length).toList());
      await out.close();
      final digest=(await hashes.sha256.bind(src.openRead()).first).toString();
      final dir=Directory('${tmp.path}/receiver');
      final v2=LinearResumeCheckpointStore(dir);
      final legacy=ResumeCheckpointStore(dir);
      final ledger=ResumeCompletionLedger(legacy,linearStore:v2);
      final id=ResumeCheckpointStore.newId();
      final peer=List<String>.filled(64,'c').join();
      await v2.create(id:id,peerFingerprint:peer,fileSha256:digest,totalBytes:total);
      // Mirror the real receiver: flush only the bytes being committed.
      // Previously the test wrote all (4 MiB + 17) before committing 4 MiB,
      // which correctly failed the store's strict file-length check.
      const firstSpan=4*1024*1024;
      final sourceBytes=await src.readAsBytes();
      final part=v2.partFile(id);
      await part.writeAsBytes(sourceBytes.sublist(0,firstSpan),flush:true);
      expect(await part.length(),firstSpan);
      await v2.commit(id,firstSpan); // first durable full span
      await part.writeAsBytes(sourceBytes.sublist(firstSpan),
        mode:FileMode.append,flush:true);
      expect(await part.length(),total);
      await v2.commit(id,total); // final verified tail and full source SHA-256
      await ledger.prepare(id:id,fingerprint:peer,digest:digest,total:total,
        originalName:'src.bin', savedName:'received.bin');
      expect(await ledger.receiptFile(id).exists(),isTrue);
      expect(await File('${dir.path}/received.bin').exists(),isFalse);
      // Simulate application exit after persisted completion intent, before
      // final rename / encrypted ACK. New objects must read disk journals.
      final resumedLedger=ResumeCompletionLedger(ResumeCheckpointStore(dir),
        linearStore:LinearResumeCheckpointStore(dir));
      final first=await resumedLedger.reconcile(id:id,fingerprint:peer,digest:digest,
        total:total,originalName:'src.bin');
      expect(first,isNotNull);
      final saved = first!;
      expect(await saved.exists(),isTrue);
      expect((await hashes.sha256.bind(saved.openRead()).first).toString(),digest);
      final second=await resumedLedger.reconcile(id:id,fingerprint:peer,digest:digest,
        total:total,originalName:'src.bin');
      expect(second!.path,saved.path);
      expect((await dir.list().where((e)=>e.path.endsWith('received.bin')).length),1);
      print('[DEV12-C3B FIX2] V2_ACK_LOSS_RECOVERY_PASS duplicates=0');
      // Modify a byte while preserving length: reject by content SHA-256,
      // not merely by a different file size.
      final corrupted=await saved.readAsBytes();
      corrupted[0] ^= 0xff;
      await saved.writeAsBytes(corrupted,flush:true);
      expect(await saved.length(),total);
      expect((await hashes.sha256.bind(saved.openRead()).first).toString(),
        isNot(digest));
      await expectLater(resumedLedger.reconcile(id:id,fingerprint:peer,digest:digest,
        total:total,originalName:'src.bin'),throwsStateError);
      print('[DEV12-C3B FIX2] V2_RECEIPT_TAMPER_REJECT_PASS');
    } finally {await tmp.delete(recursive:true);}
  },timeout:const Timeout(Duration(minutes:3)));
}
