import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';
import 'package:nearlink/security/outbound_resume_controller.dart';

const fpA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const fpB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late Directory root;
  late OutboundResumeController sender;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('linyue_e2_');
    final data = Directory('${root.path}${Platform.pathSeparator}private');
    sender = OutboundResumeController(
      journal: OutboundResumeJournal(data, minBytes: 1, maxBytes: 4096),
      sourcesDirectory: Directory('${data.path}${Platform.pathSeparator}sources'),
      maxStagedBytes: 8192,
    );
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<OutboundResumeRecord> stage(String name, {int bytes = 1024}) =>
    sender.prepare(source: Stream<List<int>>.fromIterable([
        List<int>.generate(bytes, (n) => n % 251),
      ]), name: name, expectedBytes: bytes, peerFingerprint: fpA);

  test('staged source survives controller recreation with same task ID', () async {
    final a = await stage('film.mov');
    final other = OutboundResumeController(
      journal: OutboundResumeJournal(sender.journal.directory,
        minBytes: 1, maxBytes: 4096),
      sourcesDirectory: sender.sourcesDirectory, maxStagedBytes: 8192);
    final loaded = (await other.load()).single;
    expect(loaded.taskId, a.taskId);
    expect(loaded.peerFingerprint, fpA);
    expect(await File(loaded.sourcePath).length(), 1024);
    expect(await other.verify(loaded, authenticatedFingerprint: fpA),
      OutboundRestoreCheck.ready);
  });

  test('all concurrent writes preserve their respective IDs', () async {
    final all = await Future.wait([stage('a.bin'), stage('b.bin'), stage('c.bin')]);
    expect((await sender.load()).map((r) => r.taskId).toSet(),
      all.map((r) => r.taskId).toSet());
  });

  test('wrong trusted fingerprint cannot resume', () async {
    final record = await stage('a.bin');
    expect(await sender.verify(record, authenticatedFingerprint: fpB),
      OutboundRestoreCheck.peerUntrusted);
  });

  test('tampered staged bytes reject resume without trusting journal alone', () async {
    final record = await stage('a.bin');
    await File(record.sourcePath).writeAsBytes(List<int>.filled(1024, 1));
    expect(await sender.verify(record, authenticatedFingerprint: fpA),
      OutboundRestoreCheck.sourceChanged);
  });

  test('mark sending persisted; completed task can be forgotten', () async {
    final record = await stage('a.bin');
    await sender.mark(record, OutboundResumeStatus.sending);
    expect((await sender.load()).single.status, OutboundResumeStatus.sending);
    await sender.forget(record);
    expect(await sender.load(), isEmpty);
    expect(await File(record.sourcePath).exists(), isFalse);
  });

  test('cannot use staged file of wrong size', () async {
    await expectLater(sender.prepare(source: Stream<List<int>>.value([1,2,3]),
      name: 'a.bin', expectedBytes: 1024, peerFingerprint: fpA),
      throwsStateError);
    expect(await sender.load(), isEmpty);
  });

  test('staging storage cap fails closed', () async {
    final tiny = OutboundResumeController(journal: sender.journal,
      sourcesDirectory: sender.sourcesDirectory, maxStagedBytes: 1500);
    await tiny.prepare(source: Stream<List<int>>.value(List<int>.filled(1024, 3)),
      name: 'first.bin', expectedBytes: 1024, peerFingerprint: fpA);
    await expectLater(tiny.prepare(
      source: Stream<List<int>>.value(List<int>.filled(1024, 3)),
      name: 'second.bin', expectedBytes: 1024, peerFingerprint: fpA),
      throwsStateError);
    expect((await tiny.load()).length, 1);
  });

  test('forget refuses to delete files outside the private staging root', () async {
    final outside = File('${root.path}${Platform.pathSeparator}user.bin');
    await outside.writeAsBytes(List<int>.filled(1024, 4));
    final record = await sender.journal.inspectNewSource(
      file: outside, peerFingerprint: fpA);
    await sender.journal.save([record]);
    // DEV12-D4A: unsafe cleanup must fail closed, not silently succeed.
    // The external original AND durable recovery record must be preserved.
    await expectLater(sender.forget(record), throwsStateError);
    expect(await outside.exists(), isTrue);
    expect(await outside.length(), 1024);
    final records = await sender.load();
    expect(records, hasLength(1));
    expect(records.single.taskId, record.taskId);
    expect(records.single.sourcePath, record.sourcePath);
  });
}
