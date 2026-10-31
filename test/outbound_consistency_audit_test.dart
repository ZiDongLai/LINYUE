// DEV12-D4B1: only small, isolated, synthetic app-private fixtures.
// NEVER points at the user's real application directory.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/outbound_consistency_audit.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';

const peer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const digest = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const folderA = '11111111111111111111111111111111';
const folderB = '22222222222222222222222222222222';

void main() {
  late Directory sandbox;
  late Directory sources;
  late OutboundResumeJournal journal;
  late OutboundConsistencyAudit audit;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('linyue_dev12d4b1_');
    sources = Directory('${sandbox.path}${Platform.pathSeparator}private'
        '${Platform.pathSeparator}sources');
    journal = OutboundResumeJournal(sources.parent, minBytes: 1, maxBytes: 4096);
    audit = OutboundConsistencyAudit(journal: journal,
      sourcesDirectory: sources);
  });
  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<OutboundResumeRecord> task({String folder = folderA,
      String id = folderA, int bytes = 64, String? external}) async {
    final file = external != null ? File(external) : File(
      '${sources.path}${Platform.pathSeparator}$folder'
      '${Platform.pathSeparator}source.bin');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(bytes, 12));
    final record = OutboundResumeRecord(taskId: id,
      peerFingerprint: peer, sourcePath: file.absolute.path,
      fileName: 'source.bin', fileBytes: bytes, fileSha256: digest,
      createdUtc: DateTime.now().toUtc(), status: OutboundResumeStatus.pending);
    await journal.save([record]);
    return record;
  }

  test('healthy task is metadata-clean and unchanged', () async {
    final r = await task();
    final before = await File(r.sourcePath).readAsBytes();
    final result = await audit.inspect();
    expect(result.clean, isTrue);
    expect(result.tasksRead, 1);
    expect(await File(r.sourcePath).readAsBytes(), before);
    print('[DEV12-D4B1] HEALTHY_READ_ONLY_PASS');
  });

  test('crash between file deletion and journal update is reported', () async {
    final r = await task();
    await File(r.sourcePath).delete();
    final report = await audit.inspect();
    expect(report.has(OutboundAuditCode.sourceMissing), isTrue);
    expect((await journal.load()).single.taskId, r.taskId);
    print('[DEV12-D4B1] DELETE_BEFORE_JOURNAL_DETECTED_PASS');
  });

  test('stale source size never silently counts as a resumable task', () async {
    final r = await task();
    await File(r.sourcePath).writeAsBytes([7,8]);
    final report = await audit.inspect();
    expect(report.has(OutboundAuditCode.sourceSizeChanged), isTrue);
    expect(await File(r.sourcePath).length(), 2);
    print('[DEV12-D4B1] SIZE_MISMATCH_DETECTED_PASS');
  });

  test('unregistered .writing temp directory is classified as orphan', () async {
    await journal.save([]);
    final folder = Directory('${sources.path}${Platform.pathSeparator}$folderB');
    await folder.create(recursive: true);
    final temp = File('${folder.path}${Platform.pathSeparator}source.bin.writing');
    await temp.writeAsBytes([1,2,3]);
    final report = await audit.inspect();
    expect(report.has(OutboundAuditCode.orphanDirectory), isTrue);
    expect(await temp.readAsBytes(), [1,2,3]);
    print('[DEV12-D4B1] ORPHAN_TEMP_RETAINED_PASS');
  });

  test('two corrupt journal slots abort audit without orphan guessing', () async {
    await sources.create(recursive: true);
    await journal.directory.create(recursive: true);
    for (final suffix in ['a','b']) {
      await File('${journal.directory.path}${Platform.pathSeparator}'
        '.linyue_outbound_resume_$suffix.json').writeAsString('broken-json');
    }
    final report = await audit.inspect();
    expect(report.has(OutboundAuditCode.journalUnreadable), isTrue);
    expect(report.issues, hasLength(1));
    print('[DEV12-D4B1] JOURNAL_CORRUPT_FAIL_CLOSED_PASS');
  });

  test('external source is flagged and original remains untouched', () async {
    final original = File('${sandbox.path}${Platform.pathSeparator}source.bin');
    await task(external: original.path);
    final report = await audit.inspect();
    expect(report.has(OutboundAuditCode.stagingRootMissing), isTrue);
    expect(report.has(OutboundAuditCode.outsideStagingRoot), isTrue);
    expect(await original.length(), 64);
    print('[DEV12-D4B1] EXTERNAL_SOURCE_PROTECTED_PASS');
  });

  test('deleted staging root keeps journal and reports missing source', () async {
    final record = await task();
    await sources.delete(recursive: true);
    final report = await audit.inspect();
    expect(report.has(OutboundAuditCode.stagingRootMissing), isTrue);
    expect(report.has(OutboundAuditCode.sourceMissing), isTrue);
    expect((await journal.load()).single.taskId, record.taskId);
    expect(await sources.exists(), isFalse);
    print('[DEV12-D4B1 FIX1] MISSING_ROOT_AND_SOURCE_REPORTED_PASS');
  });

  test('empty journal and absent staging root are not false alarms', () async {
    await journal.save([]);
    final report = await audit.inspect();
    expect(report.clean, isTrue);
    expect(report.tasksRead, 0);
    expect(await sources.exists(), isFalse);
    print('[DEV12-D4B1 FIX1] EMPTY_ROOT_CLEAN_PASS');
  });

  test('file symlink is never followed to validate a task', () async {
    if (Platform.isWindows) return; // Windows symlink privilege is optional.
    final r = await task();
    final original = File('${sandbox.path}${Platform.pathSeparator}outside.bin');
    await original.writeAsBytes(List<int>.filled(64, 77));
    await File(r.sourcePath).delete();
    await Link(r.sourcePath).create(original.path);
    final report = await audit.inspect();
    expect(report.has(OutboundAuditCode.unsafeSourcePath), isTrue);
    expect(await original.length(), 64);
    print('[DEV12-D4B1] LINK_REJECT_PASS');
  });

  test('queued/active task is not misdiagnosed during file growth', () async {
    final r = await task();
    await File(r.sourcePath).writeAsBytes([1,2,3]);
    final report = await audit.inspect(activeTaskIds: {r.taskId});
    expect(report.has(OutboundAuditCode.sourceSizeChanged), isFalse);
    expect(report.activeTasksSkipped, 1);
    print('[DEV12-D4B1] ACTIVE_TASK_GUARD_PASS');
  });

  test('duplicate source references are flagged without deletion', () async {
    final first = await task();
    final second = OutboundResumeRecord(taskId: folderB,
      peerFingerprint: first.peerFingerprint,
      sourcePath: first.sourcePath, fileName: first.fileName,
      fileBytes: first.fileBytes, fileSha256: first.fileSha256,
      createdUtc: first.createdUtc, status: first.status);
    await journal.save([first, second]);
    final report = await audit.inspect();
    expect(report.has(OutboundAuditCode.duplicateSource), isTrue);
    expect(await File(first.sourcePath).exists(), isTrue);
    print('[DEV12-D4B1] DUPLICATE_SOURCE_SAFE_PASS');
  });
}
