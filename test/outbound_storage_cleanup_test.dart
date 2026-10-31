import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/outbound_resume_controller.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';

const fingerprint = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  late Directory root;
  late Directory staging;
  late OutboundResumeController controller;
  late DateTime clock;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linyue_dev11a_');
    staging = Directory('${root.path}${Platform.pathSeparator}private'
      '${Platform.pathSeparator}sources');
    controller = OutboundResumeController(
      journal: OutboundResumeJournal(staging.parent,
        minBytes: 1, maxBytes: 8192, maxAge: const Duration(hours: 24)),
      sourcesDirectory: staging, maxStagedBytes: 20000);
    clock = DateTime.now().toUtc();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<OutboundResumeRecord> stage(String name, {int bytes = 1024}) =>
    controller.prepare(source: Stream<List<int>>.value(List<int>.filled(bytes, 42)),
      name: name, expectedBytes: bytes, peerFingerprint: fingerprint);

  OutboundResumeRecord age(OutboundResumeRecord record, {int hours = 26}) =>
    OutboundResumeRecord(taskId: record.taskId,
      peerFingerprint: record.peerFingerprint,
      sourcePath: record.sourcePath, fileName: record.fileName,
      fileBytes: record.fileBytes, fileSha256: record.fileSha256,
      createdUtc: clock.subtract(Duration(hours: hours)),
      status: record.status);

  test('expired staged source is removed and journal is pruned', () async {
    final item = age(await stage('old.mp4'));
    await controller.journal.save([item]);
    final outcome = await controller.cleanupExpired(now: clock);
    expect(outcome.removedTasks, 1);
    expect(outcome.deletedFiles, 1);
    expect(outcome.freedBytes, 1024);
    expect(await File(item.sourcePath).exists(), false);
    expect(await controller.load(), isEmpty);
  });

  test('fresh staging sources are retained', () async {
    final item = await stage('fresh.mp4');
    final outcome = await controller.cleanupExpired(now: DateTime.now().toUtc());
    expect(outcome.removedTasks, 0);
    expect(await File(item.sourcePath).exists(), true);
    expect((await controller.load()).single.taskId, item.taskId);
  });

  test('task at exactly 24 hours is not expired', () async {
    final item = age(await stage('boundary.mp4'), hours: 24);
    await controller.journal.save([item]);
    final result = await controller.cleanupExpired(now: clock);
    expect(result.removedTasks, 0);
    expect(await File(item.sourcePath).exists(), true);
  });

  test('protected expired queued/active ID cannot be removed', () async {
    final item = age(await stage('busy.mp4'));
    await controller.journal.save([item]);
    final result = await controller.cleanupExpired(now: clock,
      protectedTaskIds: {item.taskId});
    expect(result.removedTasks, 0);
    expect(await File(item.sourcePath).exists(), true);
  });

  test('external user original is never removed even if journal references it', () async {
    final outside = File('${root.path}${Platform.pathSeparator}user.mov');
    await outside.writeAsBytes(List<int>.filled(1024, 66));
    final seen = await controller.journal.inspectNewSource(
      file: outside, peerFingerprint: fingerprint);
    await controller.journal.save([age(seen)]);
    final result = await controller.cleanupExpired(now: clock);
    expect(result.skippedTasks, 1);
    expect(result.removedTasks, 0);
    expect(await outside.exists(), true);
  });

  test('unrelated sibling in private random folder is not removed', () async {
    final item = age(await stage('film.mov'));
    await controller.journal.save([item]);
    final sibling = File('${File(item.sourcePath).parent.path}'
        '${Platform.pathSeparator}important.txt');
    await sibling.writeAsString('do not delete');
    final result = await controller.cleanupExpired(now: clock);
    expect(result.removedTasks, 1);
    expect(await sibling.readAsString(), 'do not delete');
    expect(await sibling.parent.exists(), true);
  });

  test('missing private source removes only stale journal entry', () async {
    final item = age(await stage('missing.mov'));
    await controller.journal.save([item]);
    await File(item.sourcePath).delete();
    final result = await controller.cleanupExpired(now: clock);
    expect(result.removedTasks, 1);
    expect(result.deletedFiles, 0);
    expect(await controller.load(), isEmpty);
  });

  test('cleanup is idempotent, without deleting fresh files', () async {
    final old = age(await stage('old.mov'));
    final fresh = await stage('new.mov');
    await controller.journal.save([old, fresh]);
    final first = await controller.cleanupExpired(now: clock);
    final second = await controller.cleanupExpired(now: clock);
    expect(first.removedTasks, 1);
    expect(second.removedTasks, 0);
    expect(await File(fresh.sourcePath).exists(), true);
  });

  test('corrupt both journal slots: fail closed, do not delete', () async {
    final item = age(await stage('old.mov'));
    await controller.journal.save([item]);
    final parent = controller.journal.directory;
    await File('${parent.path}${Platform.pathSeparator}'
        '.linyue_outbound_resume_a.json').writeAsString('broken');
    await File('${parent.path}${Platform.pathSeparator}'
        '.linyue_outbound_resume_b.json').writeAsString('broken');
    await expectLater(controller.cleanupExpired(now: clock), throwsStateError);
    expect(await File(item.sourcePath).exists(), true);
  });

  test('source symlink is refused, its outside target remains', () async {
    if (Platform.isWindows) return; // Creating symlinks may require elevation.
    final item = age(await stage('old.mov'));
    await controller.journal.save([item]);
    final original = File(item.sourcePath);
    final outside = File('${root.path}${Platform.pathSeparator}target.mov');
    await outside.writeAsBytes(List<int>.filled(1024, 77));
    await original.delete();
    await Link(original.path).create(outside.path);
    final result = await controller.cleanupExpired(now: clock);
    expect(result.skippedTasks, 1);
    expect(await outside.length(), 1024);
    expect(await Link(original.path).exists(), true);
  });
}
