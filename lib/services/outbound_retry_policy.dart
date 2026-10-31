/// LINYUE DEV13D2E19-A
/// Pure, fail-closed advice for showing a restart/retry action.
///
/// This policy does not authorize a transfer by itself. The caller MUST
/// authenticate the peer again, verify the durable source via
/// OutboundResumeController.verify, and reuse the original task ID through
/// the existing secure file channel immediately before sending. Do not use
/// display names, IP addresses, or cached UI state as authorization.
import '../security/outbound_resume_journal.dart';

/// A user's retry button is available only for [ready].
/// Every other decision is explanatory, not a permission to delete a file.
enum OutboundRetryDecision {
  ready,
  journalUnavailable,
  cleanupInProgress,
  taskPendingCleanup,
  expired,
  invalidTimestamp,
  alreadyQueued,
  waitingForQueue,
  awaitingPeerAuthentication,
  wrongPeer,
  awaitingSourceVerification,
  sourceExpired,
  sourceMissing,
  sourceChanged,
  sourcePeerUntrusted,
  alreadyAttemptedAutomatically,
}

class OutboundRetryAssessment {
  const OutboundRetryAssessment(this.decision, this.userMessage);

  final OutboundRetryDecision decision;
  final String userMessage;
  bool get canOfferRetry => decision == OutboundRetryDecision.ready;
}

class OutboundRetryContext {
  const OutboundRetryContext({
    required this.record,
    required this.nowUtc,
    this.maxAge = const Duration(hours: 24),
    this.journalHealthy = false,
    this.cleanupInProgress = false,
    this.alreadyQueued = false,
    this.queueBusy = false,
    this.authenticatedFingerprint,
    this.sourceCheck,
    this.attemptedAutomaticallyThisRun = false,
    this.userInitiated = false,
  });

  final OutboundResumeRecord record;
  final DateTime nowUtc;
  final Duration maxAge;
  /// True only when the full journal and storage audit are healthy.
  final bool journalHealthy;
  final bool cleanupInProgress;
  final bool alreadyQueued;
  final bool queueBusy;
  /// Fingerprint from a *freshly authenticated* cryptographic peer proof.
  final String? authenticatedFingerprint;
  /// A fresh OutboundResumeController.verify result for the exact record.
  final OutboundRestoreCheck? sourceCheck;
  final bool attemptedAutomaticallyThisRun;
  /// True only for explicit user action, not for unattended polling.
  final bool userInitiated;
}

class OutboundRetryPolicy {
  const OutboundRetryPolicy();

  OutboundRetryAssessment assess(OutboundRetryContext context) {
    if (!context.journalHealthy) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.journalUnavailable, '恢复记录尚未安全核对；不要删除或重建任务。');
    }
    if (context.cleanupInProgress) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.cleanupInProgress, '正在清理恢复暂存记录，请稍后再检查。');
    }
    if (context.record.status == OutboundResumeStatus.cleanupPending) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.taskPendingCleanup, '此任务已经进入清理阶段，不可再次发送。');
    }
    if (context.maxAge <= Duration.zero) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.invalidTimestamp, '恢复期限配置无效，已阻止重试。');
    }
    final now = context.nowUtc.toUtc();
    final age = now.difference(context.record.createdUtc.toUtc());
    if (age < const Duration(minutes: -5)) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.invalidTimestamp, '设备时间或恢复记录异常，请先检查时间设置。');
    }
    if (age >= context.maxAge) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.expired, '恢复记录已经超时；请重新选择原文件发送。');
    }
    if (context.alreadyQueued) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.alreadyQueued, '任务已经在队列中，无需重复添加。');
    }
    if (context.queueBusy) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.waitingForQueue, '当前发送队列忙碌，待当前任务完成后再试。');
    }
    if (context.attemptedAutomaticallyThisRun && !context.userInitiated) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.alreadyAttemptedAutomatically,
        '本次启动已尝试自动恢复；请手动确认后再试。');
    }
    final fingerprint = context.authenticatedFingerprint;
    if (fingerprint == null || fingerprint.isEmpty) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.awaitingPeerAuthentication,
        '正在等待原接收设备完成认证；不能仅凭 IP 或设备名称重试。');
    }
    if (fingerprint != context.record.peerFingerprint) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.wrongPeer, '当前设备身份与原接收设备不一致，已阻止重试。');
    }
    final source = context.sourceCheck;
    if (source == null) {
      return const OutboundRetryAssessment(
        OutboundRetryDecision.awaitingSourceVerification, '请先核对暂存文件大小、摘要和恢复记录。');
    }
    switch (source) {
      case OutboundRestoreCheck.ready:
        return const OutboundRetryAssessment(
          OutboundRetryDecision.ready, '原始设备与暂存文件已通过预检查，可发起安全续传。');
      case OutboundRestoreCheck.expired:
        return const OutboundRetryAssessment(
          OutboundRetryDecision.sourceExpired, '暂存源文件已超期，请重新选择原文件。');
      case OutboundRestoreCheck.peerUntrusted:
        return const OutboundRetryAssessment(
          OutboundRetryDecision.sourcePeerUntrusted, '来源校验未通过设备认证，禁止重试。');
      case OutboundRestoreCheck.sourceMissing:
        return const OutboundRetryAssessment(
          OutboundRetryDecision.sourceMissing, '暂存源文件不存在，请重新选择原文件。');
      case OutboundRestoreCheck.sourceChanged:
        return const OutboundRetryAssessment(
          OutboundRetryDecision.sourceChanged, '暂存源文件校验失败，禁止沿用原续传任务。');
    }
  }
}
