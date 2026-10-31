// DEV12-D4B2: synthetic, isolated staging fixtures; never touches real app data.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/outbound_resume_controller.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';
import 'package:nearlink/security/outbound_consistency_audit.dart';

const String trusted =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String folderId = '11111111111111111111111111111111';

void main() {
  late Directory sandbox;
  late Directory privateDir;
  late Directory sources;
  late OutboundResumeJournal journal;
  late OutboundResumeController controller;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('linyue_dev12d4b2_');
    privateDir = Directory('${sandbox.path}${Platform.pathSeparator}private');
    sources = Directory('${privateDir.path}${Platform.pathSeparator}sources');
    journal = OutboundResumeJournal(privateDir, minBytes: 1, maxBytes: 4096);
    controller = OutboundResumeController(journal: journal,
        sourcesDirectory: sources, maxStagedBytes: 8192);
  });
  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<OutboundResumeRecord> stage([String name = 'source.bin']) async {
    return controller.prepare(
      source: Stream<List<int>>.value(List<int>.filled(100, 7)),
      name: name, expectedBytes: 100, peerFingerprint: trusted);
  }

  Future<OutboundResumeController> reopened() async {
    return OutboundResumeController(
      journal: OutboundResumeJournal(privateDir, minBytes: 1,
        maxBytes: 4096), sourcesDirectory: sources, maxStagedBytes: 8192);
  }

  test('cleanup writes intent and removes ONLY exact source', () async {
    final r = await stage();
    final unrelated = File('${File(r.sourcePath).parent.path}'
      '${Platform.pathSeparator}keep.txt');
    await unrelated.writeAsString('not a transfer source');
    await controller.forget(r);
    expect(await File(r.sourcePath).exists(), isFalse);
    expect(await unrelated.readAsString(), 'not a transfer source');
    expect(await journal.load(), isEmpty);
    print('[DEV12-D4B2] EXACT_CLEANUP_PASS');
  });

  test('restart replays intent saved just BEFORE deleting source', () async {
    final r = await stage();
    await journal.save([r.withStatus(OutboundResumeStatus.cleanupPending)]);
    final restart = await reopened();
    expect(await restart.verify(r.withStatus(OutboundResumeStatus.cleanupPending),
      authenticatedFingerprint: trusted), OutboundRestoreCheck.sourceMissing);
    final report = await restart.reconcileCleanupIntents();
    expect(report.completed, 1);
    expect(report.failed, 0);
    expect(await File(r.sourcePath).exists(), isFalse);
    expect(await journal.load(), isEmpty);
    print('[DEV12-D4B2] CRASH_BEFORE_DELETE_REPLAY_PASS');
  });

  test('restart after file deletion but BEFORE journal save finalizes', () async {
    final r = await stage();
    await journal.save([r.withStatus(OutboundResumeStatus.cleanupPending)]);
    await File(r.sourcePath).delete();
    final restart = await reopened();
    final result = await restart.reconcileCleanupIntents();
    expect(result.completed, 1);
    expect(await journal.load(), isEmpty);
    final again = await restart.reconcileCleanupIntents();
    expect(again.completed, 0);
    print('[DEV12-D4B2] DELETE_BEFORE_JOURNAL_RECOVERED_PASS');
  });

  test('unsafe external path never deletes or clears intent', () async {
    final outside = File('${sandbox.path}${Platform.pathSeparator}user.bin');
    await outside.writeAsBytes(List<int>.filled(100, 19));
    final r = await journal.inspectNewSource(file: outside,
      peerFingerprint: trusted);
    await journal.save([r.withStatus(OutboundResumeStatus.cleanupPending)]);
    final result = await (await reopened()).reconcileCleanupIntents();
    expect(result.failed, 1);
    expect(await outside.length(), 100);
    expect((await journal.load()).single.status,
      OutboundResumeStatus.cleanupPending);
    print('[DEV12-D4B2] EXTERNAL_PATH_FAIL_CLOSED_PASS');
  });

  test('shared source paths never authorize deletion on restart', () async {
    final r = await stage();
    final duplicate = OutboundResumeRecord(taskId:
      '22222222222222222222222222222222',
      peerFingerprint: trusted, sourcePath: r.sourcePath,
      fileName: r.fileName, fileBytes: r.fileBytes,
      fileSha256: r.fileSha256, createdUtc: r.createdUtc,
      status: OutboundResumeStatus.pending);
    await journal.save([r.withStatus(OutboundResumeStatus.cleanupPending),
      duplicate]);
    final result = await (await reopened()).reconcileCleanupIntents();
    expect(result.failed, 1);
    expect(await File(r.sourcePath).exists(), isTrue);
    expect((await journal.load()).length, 2);
    print('[DEV12-D4B2] SHARED_SOURCE_REFUSE_PASS');
  });

  test('ordinary resume cannot overwrite cleanup intent', () async {
    final r = await stage();
    await journal.save([r.withStatus(OutboundResumeStatus.cleanupPending)]);
    await expectLater(controller.mark(r, OutboundResumeStatus.sending),
      throwsStateError);
    expect((await journal.load()).single.status,
      OutboundResumeStatus.cleanupPending);
    print('[DEV12-D4B2] CLEANUP_INTENT_LOCK_PASS');
  });

  test('bad journal fails closed and cannot delete private source', () async {
    final r = await stage();
    // Corrupt BOTH journal slots; cannot silently fall back to an empty list.
    await journal.save([r.withStatus(OutboundResumeStatus.cleanupPending)]);
    final files = await privateDir.list().where((entity) =>
      entity.path.endsWith('.json')).toList();
    for (final item in files) {
      await File(item.path).writeAsString('broken');
    }
    await expectLater((await reopened()).reconcileCleanupIntents(),
      throwsA(isA<StateError>()));
    expect(await File(r.sourcePath).exists(), isTrue);
    print('[DEV12-D4B2] CORRUPT_JOURNAL_REJECT_PASS');
  });

  test('read-only audit flags missing source not silent recovery', () async {
    final r = await stage();
    await File(r.sourcePath).delete();
    final report = await OutboundConsistencyAudit(journal: journal,
      sourcesDirectory: sources).inspect();
    expect(report.has(OutboundAuditCode.sourceMissing), isTrue);
    expect((await journal.load()).single.taskId, r.taskId);
    print('[DEV12-D4B2] STARTUP_AUDIT_BLOCK_PASS');
  });

  test('old pending and interrupted journal records remain readable', () async {
    final r = await stage();
    await journal.save([r.withStatus(OutboundResumeStatus.interrupted)]);
    expect((await (await reopened()).load()).single.status,
      OutboundResumeStatus.interrupted);
    expect(await File(r.sourcePath).length(), 100);
    print('[DEV12-D4B2] LEGACY_STATUS_COMPAT_PASS');
  });
}
