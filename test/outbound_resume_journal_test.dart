import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';

const peerA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const peerB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late Directory sandbox;
  late Directory local;
  late OutboundResumeJournal store;
  late File source;
  late OutboundResumeRecord task;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('linyue_e1_');
    local = Directory('${sandbox.path}${Platform.pathSeparator}app_support');
    source = File('${sandbox.path}${Platform.pathSeparator}video.bin');
    await source.writeAsBytes(List<int>.generate(4096, (n) => n % 251), flush: true);
    store = OutboundResumeJournal(local, minBytes: 1, maxBytes: 8192);
    task = await store.inspectNewSource(file: source, peerFingerprint: peerA);
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('record has stable task ID, source hash and fingerprint', () async {
    expect(RegExp(r'^[a-f0-9]{32}$').hasMatch(task.taskId), isTrue);
    expect(task.peerFingerprint, peerA);
    expect(task.fileSha256.length, 64);
    expect(task.fileBytes, 4096);
    expect(task.fileName, 'video.bin');
    expect(task.sourcePath, source.absolute.path);
  });

  test('journal survives a new instance, preserving the same resume ID', () async {
    await store.save([task.withStatus(OutboundResumeStatus.sending)]);
    final other = OutboundResumeJournal(local, minBytes: 1, maxBytes: 8192);
    final loaded = await other.load();
    expect(loaded.single.taskId, task.taskId);
    expect(loaded.single.status, OutboundResumeStatus.sending);
    final interrupted = loaded.single.withStatus(OutboundResumeStatus.interrupted);
    await other.save([interrupted]);
    expect((await store.load()).single.taskId, task.taskId);
    expect((await store.load()).single.status, OutboundResumeStatus.interrupted);
  });

  test('recovery requires the exact trusted device fingerprint', () async {
    expect(await store.checkForRestore(task,
      trustedFingerprints: {peerA}), OutboundRestoreCheck.ready);
    expect(await store.checkForRestore(task,
      trustedFingerprints: {peerB}), OutboundRestoreCheck.peerUntrusted);
  });

  test('same-size tampering of original source prevents restoration', () async {
    await source.writeAsBytes(List<int>.filled(4096, 99), flush: true);
    expect(await store.checkForRestore(task, trustedFingerprints: {peerA}),
      OutboundRestoreCheck.sourceChanged);
  });

  test('missing source cannot be treated as a resumable file', () async {
    await source.delete();
    expect(await store.checkForRestore(task, trustedFingerprints: {peerA}),
      OutboundRestoreCheck.sourceMissing);
  });

  test('record expires with receiver checkpoint retention', () async {
    expect(await store.checkForRestore(task, trustedFingerprints: {peerA},
      now: task.createdUtc.add(const Duration(hours: 25))),
      OutboundRestoreCheck.expired);
  });

  test('latest snapshot corruption falls back to previous good slot', () async {
    await store.save([task]); // gen 0 -> a
    await store.save([task.withStatus(OutboundResumeStatus.sending)]); // gen 1 -> b
    final b = File('${local.path}${Platform.pathSeparator}.linyue_outbound_resume_b.json');
    await b.writeAsString('{corrupt', flush: true);
    final original = await OutboundResumeJournal(local, minBytes: 1, maxBytes: 8192).load();
    expect(original.single.status, OutboundResumeStatus.pending);
    expect(original.single.taskId, task.taskId);
  });

  test('two corrupt journal slots fail closed rather than silently drop jobs', () async {
    await store.save([task]);
    await store.save([task.withStatus(OutboundResumeStatus.sending)]);
    for (final key in ['a', 'b']) {
      await File('${local.path}${Platform.pathSeparator}.linyue_outbound_resume_$key.json')
        .writeAsString('invalid json', flush: true);
    }
    await expectLater(store.load(), throwsStateError);
  });

  test('save rejects duplicate IDs and never replaces the old snapshot', () async {
    await store.save([task]);
    await expectLater(store.save([task, task]), throwsStateError);
    expect((await store.load()).length, 1);
  });

  test('no ability to substitute filename or traverse source path', () async {
    final json = task.toJson();
    json['path'] = '../untrusted.bin';
    expect(() => OutboundResumeRecord.fromJson(json, minBytes: 1, maxBytes: 8192),
        throwsFormatException);
    final changed = task.toJson();
    changed['name'] = 'different.bin';
    expect(() => OutboundResumeRecord.fromJson(changed, minBytes: 1, maxBytes: 8192),
        throwsFormatException);
  });

  test('local JSON checksum detects unintentional edits', () async {
    await store.save([task]);
    final a = File('${local.path}${Platform.pathSeparator}.linyue_outbound_resume_a.json');
    final data = jsonDecode(await a.readAsString()) as Map<String, dynamic>;
    (data['tasks'] as List).first['peer'] = peerB;
    await a.writeAsString(jsonEncode(data), flush: true);
    await expectLater(store.load(), throwsStateError);
  });

  test('completed tasks can be removed, without deleting user files', () async {
    await store.save([task]);
    await store.save([]);
    expect(await store.load(), isEmpty);
    expect(await source.exists(), isTrue);
  });
}
