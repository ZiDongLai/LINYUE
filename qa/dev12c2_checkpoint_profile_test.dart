// DEV12-C2 opt-in performance diagnostic for the *existing* durable resume
// checkpoint implementation. No security checks are disabled or bypassed.
// Run: flutter test qa/dev12c2_checkpoint_profile_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/resume_checkpoint.dart';

const int _mib = 1024 * 1024;
const int _step = 4 * _mib;

void main() {
  test('measure real checkpoint-commit growth and enforce corruption refusal', () async {
    final root = await Directory.systemTemp.createTemp('linyue_dev12c2_checkpoint_');
    try {
      final store = ResumeCheckpointStore(root);
      const id = '0123456789abcdef0123456789abcdef';
      const peer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const digest = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      // Deliberately keep total > tested prefix: final-file digest is validated
      // independently by the actual transfer, not by this synthetic prefix test.
      await store.create(id: id, peerFingerprint: peer,
        fileSha256: digest, totalBytes: 96 * _mib);
      final handle = await store.partFile(id).open(mode: FileMode.append);
      final chunk = List<int>.generate(256 * 1024, (i) => (i * 13 + 29) % 251,
        growable: false);
      final segment = <int>[];
      int bytes = 0;
      try {
        for (var i = 1; i <= 16; i++) {
          for (var j = 0; j < 16; j++) {
            await handle.writeFrom(chunk);
          }
          await handle.flush();
          bytes += _step;
          final watch = Stopwatch()..start();
          final point = await store.commit(id, bytes);
          watch.stop();
          expect(point.committedBytes, bytes);
          segment.add(watch.elapsedMilliseconds);
          if (i == 4 || i == 8 || i == 16) {
            final theoreticalHashMiB = (i * i * _step) ~/ _mib;
            print('[DEV12-C2] CHECKPOINT prefix=${i * 4} MiB '
              'commit_ms=${watch.elapsedMilliseconds} '
              'cumulative_expected_rehash=$theoreticalHashMiB MiB');
          }
        }
      } finally {
        await handle.close();
      }
      final elapsed = segment.fold<int>(0, (sum, ms) => sum + ms);
      // Each commit hashes the previous prefix *and* current prefix. With
      // N commits of 4 MiB, this is (4 MiB * N^2), i.e. quadratic work.
      const n = 16;
      final theoretical = n * n * _step;
      expect(theoretical, 1024 * _mib);
      final projected512 = 128 * 128 * _step;
      expect(projected512, 64 * 1024 * _mib);
      print('[DEV12-C2] CHECKPOINT_TOTAL verified_prefix=64 MiB '
        'commit_total_ms=$elapsed hashing_work=${theoretical ~/ _mib} MiB '
        'projected_512MiB_hashing_work=${projected512 ~/ _mib} MiB '
        'note=source_read_volume_model_not_OS_disk_bytes');
      // Security regression: tampering with a durable prefix must still be
      // rejected when the next commit attempts to trust that prefix.
      // FileMode.writeOnly truncates an existing file. This is a single-byte
      // in-place corruption test, so the 64 MiB prefix must remain intact.
      final edit = await store.partFile(id).open(mode: FileMode.append);
      try {
        await edit.setPosition(0);
        await edit.writeByte(0xff);
        await edit.flush();
      } finally {
        await edit.close();
      }
      expect(await store.partFile(id).length(), 64 * _mib);
      expect((await store.partFile(id).openRead(0, 1).first).single, 0xff);
      final append = await store.partFile(id).open(mode: FileMode.append);
      try {
        for (var i = 0; i < 16; i++) {
          await append.writeFrom(chunk);
        }
        await append.flush();
      } finally {
        await append.close();
      }
      await expectLater(store.commit(id, 68 * _mib), throwsStateError);
      print('[DEV12-C2] CHECKPOINT_TAMPER_REJECT_PASS');
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
