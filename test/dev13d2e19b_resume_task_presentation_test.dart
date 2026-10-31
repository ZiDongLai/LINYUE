import 'package:flutter_test/flutter_test.dart';
import '../lib/security/outbound_resume_journal.dart';
import '../lib/services/outbound_resume_task_presentation.dart';

void main() {
  final now = DateTime.utc(2026, 10, 20, 10);
  OutboundResumeRecord record({
    DateTime? createdUtc,
    OutboundResumeStatus status = OutboundResumeStatus.interrupted,
  }) => OutboundResumeRecord(
    taskId: List<String>.filled(32, 'b').join(),
    peerFingerprint: List<String>.filled(64, 'a').join(),
    sourcePath: '/private/staged.bin',
    fileName: 'staged.bin',
    fileBytes: 21 * 1024 * 1024,
    fileSha256: List<String>.filled(64, 'c').join(),
    createdUtc: createdUtc ?? now.subtract(const Duration(minutes: 5)),
    status: status,
  );

  ResumeTaskPresentation presentation({
    OutboundResumeRecord? task,
    bool healthy = true,
    bool cleaning = false,
    bool queued = false,
    bool busy = false,
    bool online = true,
    Duration age = const Duration(hours: 24),
  }) => const OutboundResumeTaskPresentation().assess(
    record: task ?? record(),
    nowUtc: now,
    maxAge: age,
    journalHealthy: healthy,
    cleanupInProgress: cleaning,
    alreadyQueued: queued,
    queueBusy: busy,
    hasOnlineCandidate: online,
  );

  test('online candidate offers check only, never claims verification', () {
    final p = presentation();
    expect(p.state, ResumeTaskDisplayState.needsAuthenticatedVerification);
    expect(p.canCheckAndRetry, isTrue);
    expect(p.message, contains('重新认证'));
  });

  test('bad journal and cleanup block actions without deleting files', () {
    expect(presentation(healthy: false).canCheckAndRetry, isFalse);
    expect(presentation(cleaning: true).state,
        ResumeTaskDisplayState.cleanupInProgress);
    expect(presentation(task: record(status: OutboundResumeStatus.cleanupPending))
        .canCheckAndRetry, isFalse);
  });

  test('24h expiration and abnormal device clock fail closed', () {
    expect(presentation(task: record(createdUtc: now.subtract(const Duration(hours: 24))))
        .state, ResumeTaskDisplayState.expired);
    expect(presentation(task: record(createdUtc: now.add(const Duration(minutes: 6))))
        .state, ResumeTaskDisplayState.invalidTimestamp);
  });

  test('double tap or active queue cannot enqueue again', () {
    expect(presentation(queued: true).state, ResumeTaskDisplayState.queued);
    expect(presentation(busy: true).state, ResumeTaskDisplayState.busy);
  });

  test('no online peer does not imply permission by IP or name', () {
    final p = presentation(online: false);
    expect(p.state, ResumeTaskDisplayState.waitingForOriginalPeer);
    expect(p.canCheckAndRetry, isFalse);
  });

  test('projection has no side effects', () {
    final item = record();
    final snapshot = item.toJson();
    presentation(task: item);
    expect(item.toJson(), snapshot);
  });
}
