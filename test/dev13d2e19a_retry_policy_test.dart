import 'package:flutter_test/flutter_test.dart';
import '../lib/security/outbound_resume_journal.dart';
import '../lib/services/outbound_retry_policy.dart';

void main() {
  final now = DateTime.utc(2026, 10, 20, 10);
  final peer = List<String>.filled(64, 'a').join();
  OutboundResumeRecord record({
    OutboundResumeStatus status = OutboundResumeStatus.interrupted,
    DateTime? created,
    String? fingerprint,
  }) => OutboundResumeRecord(
    taskId: List<String>.filled(32, 'b').join(),
    peerFingerprint: fingerprint ?? peer,
    sourcePath: '/private/test/data.bin',
    fileName: 'data.bin',
    fileBytes: 21 * 1024 * 1024,
    fileSha256: List<String>.filled(64, 'c').join(),
    createdUtc: created ?? now.subtract(const Duration(minutes: 10)),
    status: status,
  );
  OutboundRetryContext context({
    OutboundResumeRecord? value,
    bool healthy = true,
    bool cleaning = false,
    bool queued = false,
    bool busy = false,
    String? authenticated,
    bool hasAuthenticatedPeer = true,
    OutboundRestoreCheck? source = OutboundRestoreCheck.ready,
    bool attempted = false,
    bool manual = false,
  }) => OutboundRetryContext(
    record: value ?? record(),
    nowUtc: now,
    journalHealthy: healthy,
    cleanupInProgress: cleaning,
    alreadyQueued: queued,
    queueBusy: busy,
    authenticatedFingerprint: hasAuthenticatedPeer ? (authenticated ?? peer) : null,
    sourceCheck: source,
    attemptedAutomaticallyThisRun: attempted,
    userInitiated: manual,
  );

  const policy = OutboundRetryPolicy();
  OutboundRetryDecision result(OutboundRetryContext c) => policy.assess(c).decision;

  test('only a healthy verified matching source can display retry', () {
    expect(result(context()), OutboundRetryDecision.ready);
    expect(policy.assess(context()).canOfferRetry, isTrue);
  });

  test('fail closed without verified durable journal', () {
    expect(result(context(healthy: false)), OutboundRetryDecision.journalUnavailable);
    expect(policy.assess(context(healthy: false)).canOfferRetry, isFalse);
  });

  test('never retry cleanupPending records or during cleanup', () {
    expect(result(context(value: record(status: OutboundResumeStatus.cleanupPending))),
      OutboundRetryDecision.taskPendingCleanup);
    expect(result(context(cleaning: true)), OutboundRetryDecision.cleanupInProgress);
  });

  test('never retry expired or future timestamp records', () {
    expect(result(context(value: record(created: now.subtract(const Duration(hours: 24))))),
      OutboundRetryDecision.expired);
    expect(result(context(value: record(created: now.add(const Duration(minutes: 6))))),
      OutboundRetryDecision.invalidTimestamp);
  });

  test('do not queue duplicates or race an active queue', () {
    expect(result(context(queued: true)), OutboundRetryDecision.alreadyQueued);
    expect(result(context(busy: true)), OutboundRetryDecision.waitingForQueue);
  });

  test('after automatic attempt a user must explicitly retry', () {
    expect(result(context(attempted: true)),
      OutboundRetryDecision.alreadyAttemptedAutomatically);
    expect(result(context(attempted: true, manual: true)), OutboundRetryDecision.ready);
  });

  test('an IP, name, or unauthenticated peer cannot authorize retry', () {
    expect(result(context(hasAuthenticatedPeer: false)),
      OutboundRetryDecision.awaitingPeerAuthentication);
    expect(result(context(authenticated: List<String>.filled(64, 'd').join())), OutboundRetryDecision.wrongPeer);
  });

  test('source integrity verification is mandatory', () {
    expect(result(context(source: null)), OutboundRetryDecision.awaitingSourceVerification);
    expect(result(context(source: OutboundRestoreCheck.sourceMissing)),
      OutboundRetryDecision.sourceMissing);
    expect(result(context(source: OutboundRestoreCheck.sourceChanged)),
      OutboundRetryDecision.sourceChanged);
    expect(result(context(source: OutboundRestoreCheck.peerUntrusted)),
      OutboundRetryDecision.sourcePeerUntrusted);
    expect(result(context(source: OutboundRestoreCheck.expired)),
      OutboundRetryDecision.sourceExpired);
  });

  test('a policy decision has no write, deletion, or transfer side effects', () {
    final initial = record();
    final snapshot = initial.toJson();
    final a = policy.assess(context(value: initial));
    expect(a.canOfferRetry, isTrue);
    expect(initial.toJson(), snapshot);
    // The policy only returns advice. E19-B must reauthenticate and reverify.
  });
}
