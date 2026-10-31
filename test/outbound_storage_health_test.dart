import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/outbound_resume_controller.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';
import 'package:nearlink/security/outbound_storage_health.dart';

const fingerprint = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  late Directory root;
  late Directory private;
  late Directory sources;
  late OutboundResumeController controller;
  late OutboundStorageHealthInspector inspector;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linyue_dev11b1_');
    private = Directory('${root.path}${Platform.pathSeparator}private');
    sources = Directory('${private.path}${Platform.pathSeparator}sources');
    controller = OutboundResumeController(
      journal: OutboundResumeJournal(private, minBytes: 1, maxBytes: 8192),
      sourcesDirectory: sources, maxStagedBytes: 4000,
    );
    inspector = OutboundStorageHealthInspector(controller);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<OutboundResumeRecord> add([int size = 1024]) => controller.prepare(
    source: Stream<List<int>>.value(List<int>.filled(size, 17)),
    name: 'sample.bin', expectedBytes: size, peerFingerprint: fingerprint,
  );

  test('fresh install with no staging folder is healthy', () async {
    final report = await inspector.inspect();
    expect(report.recordedTasks, 0);
    expect(report.orphanFolders, 0);
    expect(report.scanComplete, true);
    expect(report.hasProblems, false);
    expect(await sources.exists(), false); // read-only
  });

  test('valid private source counted without mutation', () async {
    final record = await add();
    final report = await inspector.inspect();
    expect(report.recordedTasks, 1);
    expect(report.recordedBytes, 1024);
    expect(report.measuredStagingBytes, 1024);
    expect(report.orphanFolders, 0);
    expect(report.hasProblems, false);
    expect(await File(record.sourcePath).length(), 1024);
    expect((await controller.load()).single.taskId, record.taskId);
  });

  test('missing journal-listed source is reported, not deleted', () async {
    final record = await add();
    await File(record.sourcePath).delete();
    final report = await inspector.inspect();
    expect(report.missingSources, 1);
    expect((await controller.load()).length, 1);
  });

  test('size mismatch is visible without changing source', () async {
    final record = await add();
    await File(record.sourcePath).writeAsBytes([1, 2, 3]);
    final report = await inspector.inspect();
    expect(report.sizeMismatchSources, 1);
    expect(await File(record.sourcePath).length(), 3);
  });

  test('unlisted private 32-hex folder is candidate orphan only', () async {
    final folder = Directory('${sources.path}${Platform.pathSeparator}${'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}');
    await folder.create(recursive: true);
    final file = File('${folder.path}${Platform.pathSeparator}unlisted.dat');
    await file.writeAsBytes(List<int>.filled(44, 7));
    final report = await inspector.inspect();
    expect(report.orphanFolders, 1);
    expect(report.orphanBytes, 44);
    expect(await file.length(), 44); // no auto cleanup
  });

  test('sibling unrecognized file is only flagged, not traversed', () async {
    await sources.create(recursive: true);
    final unknown = File('${sources.path}${Platform.pathSeparator}owner.txt');
    await unknown.writeAsString('do not delete');
    final report = await inspector.inspect();
    expect(report.unknownEntries, 1);
    expect(await unknown.readAsString(), 'do not delete');
  });

  test('expired task is counted; source remains', () async {
    final record = await add();
    final old = OutboundResumeRecord(taskId: record.taskId,
      peerFingerprint: record.peerFingerprint,
      sourcePath: record.sourcePath, fileName: record.fileName,
      fileBytes: record.fileBytes, fileSha256: record.fileSha256,
      createdUtc: DateTime.now().toUtc().subtract(const Duration(hours: 25)),
      status: record.status);
    await controller.journal.save([old]);
    final report = await inspector.inspect();
    expect(report.expiredTasks, 1);
    expect(await File(old.sourcePath).exists(), true);
  });

  test('journal corruption raises error without deleting staging', () async {
    final record = await add();
    await File('${private.path}${Platform.pathSeparator}'
      '.linyue_outbound_resume_a.json').writeAsString('corrupted');
    await File('${private.path}${Platform.pathSeparator}'
      '.linyue_outbound_resume_b.json').writeAsString('corrupted');
    await expectLater(inspector.inspect(), throwsStateError);
    expect(await File(record.sourcePath).exists(), true);
  });

  test('approaching application quota is not device disk free', () async {
    await add(3500);
    final report = await inspector.inspect();
    expect(report.nearingQuota, true);
    expect(report.hasProblems, true);
    expect(report.stagingQuotaBytes, 4000);
  });

  test('symlink folder is not followed', () async {
    if (Platform.isWindows) return; // privileges vary on Windows
    final external = Directory('${root.path}${Platform.pathSeparator}external');
    await external.create();
    await File('${external.path}${Platform.pathSeparator}note').writeAsString('secret');
    await sources.create(recursive: true);
    final link = Link('${sources.path}${Platform.pathSeparator}${'cccccccccccccccccccccccccccccccc'}');
    await link.create(external.path);
    final report = await inspector.inspect();
    expect(report.unknownEntries, 1);
    expect(report.measuredStagingBytes, 0);
    expect(await File('${external.path}${Platform.pathSeparator}note').exists(), true);
  });
}
