import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:nearlink/security/resume_checkpoint.dart';

const _peer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherPeer = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _fileHash = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

void main() {
  late Directory directory;
  late ResumeCheckpointStore store;
  late String id;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('linyue_resume_test_');
    store = ResumeCheckpointStore(directory);
    id = ResumeCheckpointStore.newId();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('persists only committed chunks and restores after a new instance', () async {
    await store.create(id: id, peerFingerprint: _peer, fileSha256: _fileHash,
      totalBytes: 3 * resumeCheckpointChunkSize);
    final file = store.partFile(id);
    await file.writeAsBytes(List<int>.filled(resumeCheckpointChunkSize, 13), flush: true);
    await store.commit(id, resumeCheckpointChunkSize);
    final restarted = ResumeCheckpointStore(directory);
    final point = await restarted.inspect(id: id, expectedPeer: _peer,
      expectedSha256: _fileHash, expectedSize: 3 * resumeCheckpointChunkSize);
    expect(point.checkpoint.committedBytes, resumeCheckpointChunkSize);
    expect(point.uncommittedBytes, 0);
  });

  test('extra unverified bytes are NOT acknowledged and can be truncated', () async {
    await store.create(id: id, peerFingerprint: _peer, fileSha256: _fileHash,
      totalBytes: 3 * resumeCheckpointChunkSize);
    final file = store.partFile(id);
    await file.writeAsBytes(List<int>.filled(resumeCheckpointChunkSize, 12), flush: true);
    await store.commit(id, resumeCheckpointChunkSize);
    final append = await file.open(mode: FileMode.append);
    try {
      await append.writeFrom(List<int>.filled(100, 2));
      await append.flush();
    } finally {
      await append.close();
    }
    final point = await store.inspect(id: id, expectedPeer: _peer,
      expectedSha256: _fileHash, expectedSize: 3 * resumeCheckpointChunkSize);
    expect(point.uncommittedBytes, 100);
    expect(await store.truncateUncommitted(point), resumeCheckpointChunkSize);
    expect(await file.length(), resumeCheckpointChunkSize);
  });

  test('different peer and file identity are rejected', () async {
    await store.create(id: id, peerFingerprint: _peer, fileSha256: _fileHash,
      totalBytes: resumeCheckpointChunkSize);
    await expectLater(store.inspect(id: id, expectedPeer: _otherPeer,
      expectedSha256: _fileHash, expectedSize: resumeCheckpointChunkSize),
      throwsStateError);
    await expectLater(store.inspect(id: id, expectedPeer: _peer,
      expectedSha256: _otherPeer, expectedSize: resumeCheckpointChunkSize),
      throwsStateError);
  });

  test('committed file corruption fails inspection', () async {
    await store.create(id: id, peerFingerprint: _peer, fileSha256: _fileHash,
      totalBytes: 2 * resumeCheckpointChunkSize);
    final file = store.partFile(id);
    await file.writeAsBytes(List<int>.filled(resumeCheckpointChunkSize, 13), flush: true);
    await store.commit(id, resumeCheckpointChunkSize);
    final bytes = await file.readAsBytes();
    bytes[0] ^= 0xff;
    await file.writeAsBytes(bytes, flush: true);
    await expectLater(store.inspect(id: id, expectedPeer: _peer,
      expectedSha256: _fileHash, expectedSize: 2 * resumeCheckpointChunkSize),
      throwsStateError);
  });

  test('regressed and misaligned offsets are rejected', () async {
    await store.create(id: id, peerFingerprint: _peer, fileSha256: _fileHash,
      totalBytes: 3 * resumeCheckpointChunkSize);
    final file = store.partFile(id);
    await file.writeAsBytes(List<int>.filled(resumeCheckpointChunkSize, 21), flush: true);
    await store.commit(id, resumeCheckpointChunkSize);
    await expectLater(store.commit(id, 123), throwsStateError);
    await expectLater(store.commit(id, 0), throwsStateError);
  });

  test('final commit checks the complete source digest', () async {
    final content = List<int>.filled(resumeCheckpointChunkSize, 44);
    final expected = crypto.sha256.convert(content).toString();
    await store.create(id: id, peerFingerprint: _peer, fileSha256: expected,
      totalBytes: content.length);
    await store.partFile(id).writeAsBytes(content, flush: true);
    final finished = await store.commit(id, content.length);
    expect(finished.committedBytes, content.length);
    await store.verifySource(store.partFile(id), finished);
  });

  test('invalid record identifiers cannot escape sandbox', () async {
    expect(() => store.partFile('../hello'), throwsFormatException);
    expect(() => store.partFile('c:/windows'), throwsFormatException);
  });

  test('journal corruption cannot silently approve unverifiable bytes', () async {
    await store.create(id: id, peerFingerprint: _peer, fileSha256: _fileHash,
      totalBytes: 2 * resumeCheckpointChunkSize);
    final file = store.partFile(id);
    await file.writeAsBytes(List<int>.filled(resumeCheckpointChunkSize, 7), flush: true);
    await store.commit(id, resumeCheckpointChunkSize);
    // Generation 1 is the active B slot. Corruption leaves generation 0,
    // which MUST NOT approve the extra bytes already written to the part.
    final b = File('${directory.path}${Platform.pathSeparator}.linyue_resume_$id.b.json');
    await b.writeAsString('not json', flush: true);
    final result = await store.inspect(id: id, expectedPeer: _peer,
      expectedSha256: _fileHash, expectedSize: 2 * resumeCheckpointChunkSize);
    expect(result.checkpoint.committedBytes, 0);
    expect(result.uncommittedBytes, resumeCheckpointChunkSize);
  });

  test('explicit discard deletes journal and part, never other files', () async {
    await store.create(id: id, peerFingerprint: _peer, fileSha256: _fileHash,
      totalBytes: resumeCheckpointChunkSize);
    final saved = File('${directory.path}${Platform.pathSeparator}completed.jpg');
    await saved.writeAsBytes([1, 2, 3]);
    await store.discard(id);
    expect(await store.partFile(id).exists(), false);
    expect(await saved.exists(), true);
  });
}
