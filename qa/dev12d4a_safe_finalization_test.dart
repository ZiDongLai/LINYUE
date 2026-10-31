// DEV12-D4A: exact-file finalization safety regression (tiny temp fixtures).
// Does NOT send network traffic or delete files outside a temporary sandbox.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/outbound_resume_controller.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';

const _peerA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peerB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late Directory sandbox;
  late Directory staging;
  late OutboundResumeController controller;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('linyue_dev12d4a_');
    staging = Directory('${sandbox.path}${Platform.pathSeparator}private'
        '${Platform.pathSeparator}sources');
    controller = OutboundResumeController(
      journal: OutboundResumeJournal(staging.parent, minBytes: 1, maxBytes: 8192),
      sourcesDirectory: staging, maxStagedBytes: 20000,
    );
  });
  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<OutboundResumeRecord> stage(String name, {int bytes = 1024}) =>
      controller.prepare(source: Stream<List<int>>.value(List<int>.filled(bytes, 42)),
          name: name, expectedBytes: bytes, peerFingerprint: _peerA);

  test('completed source is removed and journal freed, original untouched', () async {
    final original = File('${sandbox.path}${Platform.pathSeparator}original.bin');
    await original.writeAsBytes(List<int>.filled(1024, 86));
    final saved = await stage('completed.bin');
    expect(await File(saved.sourcePath).exists(), isTrue);
    await controller.forget(saved);
    expect(await File(saved.sourcePath).exists(), isFalse);
    expect(await original.length(), 1024);
    expect(await controller.load(), isEmpty);
    print('[DEV12-D4A] COMPLETE_EXACT_FILE_PASS');
  });

  test('sibling in same private folder is NEVER recursively deleted', () async {
    final saved = await stage('finished.bin');
    final sibling = File('${File(saved.sourcePath).parent.path}'
        '${Platform.pathSeparator}keep.txt');
    await sibling.writeAsString('keep this');
    await controller.forget(saved);
    expect(await sibling.readAsString(), 'keep this');
    expect(await sibling.parent.exists(), isTrue);
    expect(await File(saved.sourcePath).exists(), isFalse);
    print('[DEV12-D4A] SIBLING_RETAINED_PASS');
  });

  test('mismatched caller cannot delete journal-selected file', () async {
    final saved = await stage('valid.bin');
    final forged = OutboundResumeRecord(
      taskId: saved.taskId, peerFingerprint: _peerB,
      sourcePath: saved.sourcePath, fileName: saved.fileName,
      fileBytes: saved.fileBytes, fileSha256: saved.fileSha256,
      createdUtc: saved.createdUtc, status: saved.status,
    );
    await expectLater(controller.forget(forged), throwsStateError);
    expect(await File(saved.sourcePath).exists(), isTrue);
    expect((await controller.load()).single.taskId, saved.taskId);
    print('[DEV12-D4A] RECORD_MISMATCH_REJECT_PASS');
  });

  test('external original in journal cannot be deleted by forget', () async {
    final outside = File('${sandbox.path}${Platform.pathSeparator}user_original.mp4');
    await outside.writeAsBytes(List<int>.filled(2048, 63));
    final saved = await controller.journal.inspectNewSource(
        file: outside, peerFingerprint: _peerA);
    await controller.journal.save([saved]);
    await expectLater(controller.forget(saved), throwsStateError);
    expect(await outside.length(), 2048);
    expect((await controller.load()).single.taskId, saved.taskId);
    print('[DEV12-D4A] EXTERNAL_ORIGINAL_PROTECTED_PASS');
  });

  test('stale repeat forget does not delete another file', () async {
    final saved = await stage('finished.bin');
    await controller.forget(saved);
    final spare = File('${sandbox.path}${Platform.pathSeparator}spare.bin');
    await spare.writeAsBytes([1, 2, 3]);
    await controller.forget(saved); // stale duplicate call is a no-op
    expect(await spare.readAsBytes(), [1, 2, 3]);
    print('[DEV12-D4A] REPEAT_FORGET_SAFE_PASS');
  });

  test('two journal records referring to one private file fail closed', () async {
    final saved = await stage('shared.bin');
    final second = OutboundResumeRecord(
      taskId: 'cccccccccccccccccccccccccccccccc',
      peerFingerprint: saved.peerFingerprint,
      sourcePath: saved.sourcePath,
      fileName: saved.fileName, fileBytes: saved.fileBytes,
      fileSha256: saved.fileSha256, createdUtc: saved.createdUtc,
      status: saved.status,
    );
    await controller.journal.save([saved, second]);
    await expectLater(controller.forget(saved), throwsStateError);
    expect(await File(saved.sourcePath).exists(), isTrue);
    expect((await controller.load()).length, 2);
    print('[DEV12-D4A] SHARED_SOURCE_REJECT_PASS');
  });

  test('symlink source never follows a target on supported platforms', () async {
    if (Platform.isWindows) return; // Windows symlink creation needs privileges.
    final saved = await stage('link.bin');
    final outside = File('${sandbox.path}${Platform.pathSeparator}outside.bin');
    await outside.writeAsBytes([21, 22, 23]);
    await File(saved.sourcePath).delete();
    await Link(saved.sourcePath).create(outside.path);
    await expectLater(controller.forget(saved), throwsStateError);
    expect(await outside.readAsBytes(), [21, 22, 23]);
    expect((await controller.load()).single.taskId, saved.taskId);
    print('[DEV12-D4A] SYMLINK_REJECT_PASS');
  });
}
