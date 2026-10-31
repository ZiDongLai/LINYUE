/// DEV13D2E19-C: isolated, non-destructive recovery regression tests.
/// Every file and journal is created under a unique OS temporary directory.
/// No real application storage, chat database, gallery or transfer record is read.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../lib/security/outbound_resume_controller.dart';
import '../lib/security/outbound_resume_journal.dart';
import '../lib/services/outbound_retry_policy.dart';
import '../lib/services/outbound_resume_task_presentation.dart';

void main() {
  const peer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const otherPeer = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const length = 64 * 1024;

  late Directory sandbox;
  late Directory sourceDirectory;
  late OutboundResumeJournal journal;
  late OutboundResumeController controller;
  late List<int> originalBytes;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('linyue_e19c_isolated_');
    sourceDirectory = Directory('${sandbox.path}${Platform.pathSeparator}staged');
    journal = OutboundResumeJournal(
      Directory('${sandbox.path}${Platform.pathSeparator}journal'),
      minBytes: 1,
      maxBytes: 1024 * 1024,
    );
    controller = OutboundResumeController(
      journal: journal,
      sourcesDirectory: sourceDirectory,
      maxStagedBytes: 512 * 1024,
    );
    originalBytes = List<int>.generate(length, (index) => (index * 43 + 19) % 256);
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  Future<OutboundResumeRecord> prepare() async {
    return controller.prepare(
      source: Stream<List<int>>.value(originalBytes),
      name: 'E19C_isolated.bin',
      expectedBytes: originalBytes.length,
      peerFingerprint: peer,
    );
  }

  test('interrupted task survives controller/journal recreation with same ID and source bytes', () async {
    final record = await prepare();
    await controller.mark(record, OutboundResumeStatus.interrupted);
    final freshJournal = OutboundResumeJournal(journal.directory,
        minBytes: journal.minBytes, maxBytes: journal.maxBytes);
    final restarted = OutboundResumeController(
        journal: freshJournal, sourcesDirectory: sourceDirectory);
    final restored = await restarted.load();
    expect(restored, hasLength(1));
    expect(restored.single.taskId, record.taskId);
    expect(restored.single.peerFingerprint, peer);
    expect(restored.single.status, OutboundResumeStatus.interrupted);
    expect(await File(restored.single.sourcePath).readAsBytes(), originalBytes);
    expect(await restarted.verify(restored.single, authenticatedFingerprint: peer),
        OutboundRestoreCheck.ready);
    expect((await restarted.load()).single.taskId, record.taskId,
        reason: 'read-only restart must not duplicate the task');
  });

  test('wrong authenticated identity cannot use source or remove durable record', () async {
    final record = await prepare();
    expect(await controller.verify(record, authenticatedFingerprint: otherPeer),
        OutboundRestoreCheck.peerUntrusted);
    expect(await journal.load(), hasLength(1));
    expect(await File(record.sourcePath).exists(), isTrue);
    final verdict = const OutboundRetryPolicy().assess(OutboundRetryContext(
      record: record,
      nowUtc: DateTime.now().toUtc(),
      journalHealthy: true,
      authenticatedFingerprint: otherPeer,
      sourceCheck: OutboundRestoreCheck.ready,
      userInitiated: true,
    ));
    expect(verdict.decision, OutboundRetryDecision.wrongPeer);
    expect(verdict.canOfferRetry, isFalse);
  });

  test('same-length source mutation is caught by SHA-256 and record is retained', () async {
    final record = await prepare();
    final changed = List<int>.from(originalBytes);
    changed[100] ^= 0xff;
    await File(record.sourcePath).writeAsBytes(changed, flush: true);
    expect(await controller.verify(record, authenticatedFingerprint: peer),
        OutboundRestoreCheck.sourceChanged);
    expect((await journal.load()).single.taskId, record.taskId);
    expect(await File(record.sourcePath).exists(), isTrue,
        reason: 'failed verification must never delete or reset sources');
  });

  test('missing staged source fails closed without silently resetting journal', () async {
    final record = await prepare();
    await File(record.sourcePath).delete(); // ONLY our newly created test fixture
    expect(await controller.verify(record, authenticatedFingerprint: peer),
        OutboundRestoreCheck.sourceMissing);
    expect((await journal.load()).single.taskId, record.taskId);
  });

  test('25-hour record expires with injected clock and stays on disk', () async {
    final record = await prepare();
    final later = record.createdUtc.add(const Duration(hours: 25));
    expect(await journal.checkForRestore(record,
        trustedFingerprints: <String>{peer}, now: later),
        OutboundRestoreCheck.expired);
    final state = const OutboundResumeTaskPresentation().assess(
      record: record,
      nowUtc: later,
      maxAge: journal.maxAge,
      journalHealthy: true,
      cleanupInProgress: false,
      alreadyQueued: false,
      queueBusy: false,
      hasOnlineCandidate: true,
    );
    expect(state.state, ResumeTaskDisplayState.expired);
    expect(state.canCheckAndRetry, isFalse);
    expect(await File(record.sourcePath).exists(), isTrue);
    expect(await journal.load(), hasLength(1));
  });

  test('active send queue and duplicate queued ID never offer retry', () async {
    final record = await prepare();
    final queued = const OutboundRetryPolicy().assess(OutboundRetryContext(
        record: record, nowUtc: DateTime.now().toUtc(),
        journalHealthy: true, alreadyQueued: true, userInitiated: true));
    expect(queued.decision, OutboundRetryDecision.alreadyQueued);
    expect(queued.canOfferRetry, isFalse);
    final busy = const OutboundRetryPolicy().assess(OutboundRetryContext(
        record: record, nowUtc: DateTime.now().toUtc(),
        journalHealthy: true, queueBusy: true, userInitiated: true));
    expect(busy.decision, OutboundRetryDecision.waitingForQueue);
    expect(busy.canOfferRetry, isFalse);
  });

  test('simulated private staging quota exhaustion does not touch existing record', () async {
    final record = await prepare();
    final capped = OutboundResumeController(journal: journal,
      sourcesDirectory: sourceDirectory,
      maxStagedBytes: record.fileBytes + originalBytes.length - 1);
    await expectLater(capped.prepare(
        source: Stream<List<int>>.value(originalBytes),
        name: 'quota_test.bin', expectedBytes: originalBytes.length,
        peerFingerprint: peer), throwsA(isA<StateError>()));
    expect(await journal.load(), hasLength(1));
    expect(await File(record.sourcePath).readAsBytes(), originalBytes);
    // This simulates the application staging QUOTA, not an actual full disk.
  });

  test('incomplete stream staging is rejected and leaves journal intact', () async {
    await expectLater(controller.prepare(
      source: Stream<List<int>>.value(originalBytes.sublist(0, length - 1)),
      name: 'incomplete.bin', expectedBytes: length,
      peerFingerprint: peer,
    ), throwsA(isA<StateError>()));
    expect(await journal.load(), isEmpty);
    if (await sourceDirectory.exists()) {
      expect(await sourceDirectory.list(recursive: true).toList(), isEmpty,
          reason: 'failed test fixture staging must not leave a partial private source');
    }
  });

  test('both journal snapshots corrupted: fail safely and preserve staged source', () async {
    final record = await prepare();
    await controller.mark(record, OutboundResumeStatus.interrupted);
    final slots = await journal.directory.list().where((entity) =>
        entity is File && entity.path.endsWith('.json')).toList();
    expect(slots, hasLength(2));
    for (final slot in slots) {
      await File(slot.path).writeAsString('{corrupt snapshot', flush: true);
    }
    await expectLater(journal.load(), throwsA(isA<StateError>()));
    expect(await File(record.sourcePath).readAsBytes(), originalBytes);
  });

  test('read-only inspection never modifies private source or user original', () async {
    final original = File('${sandbox.path}${Platform.pathSeparator}original_user_copy.bin');
    await original.writeAsBytes(originalBytes, flush: true);
    final record = await prepare();
    final before = await original.readAsBytes();
    await controller.verify(record, authenticatedFingerprint: peer);
    await controller.load();
    const OutboundResumeTaskPresentation().assess(
      record: record, nowUtc: DateTime.now().toUtc(),
      maxAge: const Duration(hours: 24),
      journalHealthy: true, cleanupInProgress: false,
      alreadyQueued: false, queueBusy: false, hasOnlineCandidate: true);
    expect(await original.readAsBytes(), before);
    expect(await File(record.sourcePath).readAsBytes(), originalBytes);
  });
}
