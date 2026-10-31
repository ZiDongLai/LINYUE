// DEV12-C3A: isolated candidate only. Does not replace production v1.
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/linear_checkpoint_candidate.dart';

const int _mib = 1024 * 1024;
const int _step = 4 * _mib;
const String _peer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _otherPeer = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const String _mockFileHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Future<void> _appendBytes(File file, int length, {int seed = 17}) async {
  final handle = await file.open(mode: FileMode.append);
  try {
    final chunk = List<int>.generate(256 * 1024,
      (i) => (i * 7 + seed) % 251, growable: false);
    var remaining = length;
    while (remaining > 0) {
      final step = remaining < chunk.length ? remaining : chunk.length;
      await handle.writeFrom(chunk, 0, step);
      remaining -= step;
    }
    await handle.flush();
  } finally {
    await handle.close();
  }
}

void main() {
  late Directory directory;
  late LinearCheckpointCandidateStore candidate;
  late String id;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('linyue_linear_candidate_');
    candidate = LinearCheckpointCandidateStore(directory);
    id = LinearCheckpointCandidateStore.newId();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('64 MiB: commits hash only NEW spans; reboot inspect reads full prefix once', () async {
    await candidate.create(id: id, peerFingerprint: _peer,
      fileSha256: _mockFileHash, totalBytes: 96 * _mib);
    final file = candidate.partFile(id);
    final clock = Stopwatch()..start();
    for (var n = 1; n <= 16; n++) {
      await _appendBytes(file, _step, seed: n);
      final saved = await candidate.commit(id, n * _step);
      expect(saved.committed, n * _step);
    }
    clock.stop();
    expect(candidate.commitHashedBytes, 64 * _mib);
    final freshInstance = LinearCheckpointCandidateStore(directory);
    final restored = await freshInstance.inspect(id: id, expectedPeer: _peer,
      expectedSha256: _mockFileHash, expectedSize: 96 * _mib);
    expect(restored.record.committed, 64 * _mib);
    expect(restored.extraBytes, 0);
    expect(freshInstance.inspectionHashedBytes, 64 * _mib);
    print('[DEV12-C3A] LINEAR_COMMIT_PASS committed_mib=64 '
      'commit_hash_work_mib=${candidate.commitHashedBytes ~/ _mib} '
      'v1_theoretical_commit_work_mib=1024 '
      'reopened_inspection_hash_mib=${freshInstance.inspectionHashedBytes ~/ _mib} '
      'wall_ms=${clock.elapsedMilliseconds}');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('same-size old-prefix tampering always fails before resume', () async {
    await candidate.create(id: id, peerFingerprint: _peer,
      fileSha256: _mockFileHash, totalBytes: 12 * _mib);
    final file = candidate.partFile(id);
    await _appendBytes(file, _step);
    await candidate.commit(id, _step);
    await _appendBytes(file, _step, seed: 28);
    await candidate.commit(id, 2 * _step);
    final edited = await file.open(mode: FileMode.append);
    try {
      await edited.setPosition(0);
      await edited.writeByte(0xff);
      await edited.flush();
    } finally {
      await edited.close();
    }
    expect(await file.length(), 2 * _step);
    final afterRestart = LinearCheckpointCandidateStore(directory);
    await expectLater(afterRestart.inspect(id: id, expectedPeer: _peer,
      expectedSha256: _mockFileHash, expectedSize: 12 * _mib), throwsStateError);
    print('[DEV12-C3A] TAMPER_BEFORE_RESUME_REJECT_PASS');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('final SHA-256 detects corruption in a previously committed span', () async {
    final source = File('${directory.path}${Platform.pathSeparator}source8m.bin');
    await _appendBytes(source, 8 * _mib);
    final originalHash = (await crypto.sha256.bind(source.openRead()).first).toString();
    await candidate.create(id: id, peerFingerprint: _peer,
      fileSha256: originalHash, totalBytes: 8 * _mib);
    final file = candidate.partFile(id);
    final content = await source.openRead(0, _step).expand((bytes) => bytes).toList();
    await file.writeAsBytes(content, flush: true);
    await candidate.commit(id, _step);
    final edit = await file.open(mode: FileMode.append);
    try {
      await edit.setPosition(0);
      await edit.writeByte(0xff);
      await edit.flush();
    } finally {
      await edit.close();
    }
    final next = await file.open(mode: FileMode.append);
    try {
      await next.writeFrom(await source.openRead(_step).expand((bytes) => bytes).toList());
      await next.flush();
    } finally {
      await next.close();
    }
    expect(await file.length(), 8 * _mib);
    await expectLater(candidate.commit(id, 8 * _mib), throwsStateError);
    await expectLater(candidate.inspect(id: id, expectedPeer: _peer,
      expectedSha256: originalHash, expectedSize: 8 * _mib), throwsStateError);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('correct final source SHA-256 is mandatory', () async {
    final sample = List<int>.filled(256 * 1024, 7);
    final temp = File('${directory.path}${Platform.pathSeparator}source.bin');
    await temp.writeAsBytes(sample, flush: true);
    final digest = (await crypto.sha256.bind(temp.openRead()).first).toString();
    await candidate.create(id: id, peerFingerprint: _peer,
      fileSha256: digest, totalBytes: sample.length);
    await candidate.partFile(id).writeAsBytes(sample, flush: true);
    await candidate.commit(id, sample.length);
    final record = await LinearCheckpointCandidateStore(directory).inspect(id: id,
      expectedPeer: _peer, expectedSha256: digest, expectedSize: sample.length);
    expect(record.record.committed, sample.length);
    print('[DEV12-C3A] FINAL_SHA256_PASS');
  });

  test('corrupt newest journal falls back but never trusts uncommitted data', () async {
    await candidate.create(id: id, peerFingerprint: _peer,
      fileSha256: _mockFileHash, totalBytes: 12 * _mib);
    final part = candidate.partFile(id);
    await _appendBytes(part, _step);
    await candidate.commit(id, _step); // B: generation 1
    await _appendBytes(part, _step);
    await candidate.commit(id, 2 * _step); // A: generation 2
    final newSlot = File('${directory.path}${Platform.pathSeparator}.linyue_linear_$id.a.json');
    await newSlot.writeAsString('not-json', flush: true);
    final check = await LinearCheckpointCandidateStore(directory).inspect(id: id,
      expectedPeer: _peer, expectedSha256: _mockFileHash, expectedSize: 12 * _mib);
    expect(check.record.committed, _step);
    expect(check.extraBytes, _step);
    print('[DEV12-C3A] CORRUPT_SLOT_FALLBACK_PASS');
  });

  test('different authenticated device / file / length rejected', () async {
    await candidate.create(id: id, peerFingerprint: _peer,
      fileSha256: _mockFileHash, totalBytes: 8 * _mib);
    await expectLater(candidate.inspect(id: id, expectedPeer: _otherPeer,
      expectedSha256: _mockFileHash, expectedSize: 8 * _mib), throwsStateError);
    await expectLater(candidate.inspect(id: id, expectedPeer: _peer,
      expectedSha256: _otherPeer, expectedSize: 8 * _mib), throwsStateError);
    await expectLater(candidate.inspect(id: id, expectedPeer: _peer,
      expectedSha256: _mockFileHash, expectedSize: 7 * _mib), throwsStateError);
    expect(() => candidate.partFile('../escape'), throwsFormatException);
  });

  test('offset regression, premature partial interval and overflow rejected', () async {
    await candidate.create(id: id, peerFingerprint: _peer,
      fileSha256: _mockFileHash, totalBytes: 12 * _mib);
    await _appendBytes(candidate.partFile(id), _step);
    await candidate.commit(id, _step);
    await expectLater(candidate.commit(id, 0), throwsStateError);
    await expectLater(candidate.commit(id, _step + 256 * 1024), throwsStateError);
    await expectLater(candidate.commit(id, 16 * _mib), throwsStateError);
  });

  test('candidate uses separate journal and never touches v1 paths', () async {
    await candidate.create(id: id, peerFingerprint: _peer,
      fileSha256: _mockFileHash, totalBytes: 8 * _mib);
    final oldPart = File('${directory.path}${Platform.pathSeparator}.linyue_resume_$id.part');
    await oldPart.writeAsBytes([9, 8, 7], flush: true);
    await candidate.discard(id);
    expect(await oldPart.readAsBytes(), [9, 8, 7]);
    expect(await candidate.partFile(id).exists(), false);
    print('[DEV12-C3A] PRODUCTION_V1_UNTOUCHED_PASS');
  });
}
