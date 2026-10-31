/// LINYUE DEV13D2E19-B: safe, read-only resume task presentation.
/// A visible action offers an authenticated check, NOT permission to send.
/// `ready` is intentionally not exposed here: the send action must run the
/// existing authenticated source verification before enqueueing the original ID.
import '../security/outbound_resume_journal.dart';

enum ResumeTaskDisplayState {
  journalUnavailable,
  cleanupInProgress,
  cleanupPending,
  expired,
  invalidTimestamp,
  queued,
  busy,
  waitingForOriginalPeer,
  needsAuthenticatedVerification,
}

class ResumeTaskPresentation {
  const ResumeTaskPresentation({
    required this.state,
    required this.message,
    required this.canCheckAndRetry,
  });

  final ResumeTaskDisplayState state;
  final String message;
  final bool canCheckAndRetry;
}

class OutboundResumeTaskPresentation {
  const OutboundResumeTaskPresentation();

  ResumeTaskPresentation assess({
    required OutboundResumeRecord record,
    required DateTime nowUtc,
    required Duration maxAge,
    required bool journalHealthy,
    required bool cleanupInProgress,
    required bool alreadyQueued,
    required bool queueBusy,
    required bool hasOnlineCandidate,
  }) {
    if (!journalHealthy) {
      return const ResumeTaskPresentation(
        state: ResumeTaskDisplayState.journalUnavailable,
        message: '恢复日志异常，暂停重试并保留数据',
        canCheckAndRetry: false,
      );
    }
    if (cleanupInProgress) {
      return const ResumeTaskPresentation(
        state: ResumeTaskDisplayState.cleanupInProgress,
        message: '恢复记录清理中，暂不可重试',
        canCheckAndRetry: false,
      );
    }
    if (record.status == OutboundResumeStatus.cleanupPending) {
      return const ResumeTaskPresentation(
        state: ResumeTaskDisplayState.cleanupPending,
        message: '任务已进入清理阶段，禁止重试',
        canCheckAndRetry: false,
      );
    }
    if (maxAge <= Duration.zero) {
      return const ResumeTaskPresentation(
        state: ResumeTaskDisplayState.invalidTimestamp,
        message: '恢复期限配置无效',
        canCheckAndRetry: false,
      );
    }
    final age = nowUtc.toUtc().difference(record.createdUtc.toUtc());
    if (age < const Duration(minutes: -5)) {
      return const ResumeTaskPresentation(
        state: ResumeTaskDisplayState.invalidTimestamp,
        message: '设备时间或恢复记录异常',
        canCheckAndRetry: false,
      );
    }
    if (age >= maxAge) {
      return const ResumeTaskPresentation(
        state: ResumeTaskDisplayState.expired,
        message: '恢复记录已超期，请重新选择原文件',
        canCheckAndRetry: false,
      );
    }
    if (alreadyQueued) {
      return const ResumeTaskPresentation(
        state: ResumeTaskDisplayState.queued,
        message: '该任务已加入发送队列',
        canCheckAndRetry: false,
      );
    }
    if (queueBusy) {
      return const ResumeTaskPresentation(
        state: ResumeTaskDisplayState.busy,
        message: '发送或恢复检查进行中，请稍候',
        canCheckAndRetry: false,
      );
    }
    if (!hasOnlineCandidate) {
      return const ResumeTaskPresentation(
        state: ResumeTaskDisplayState.waitingForOriginalPeer,
        message: '等待原接收设备在线，暂不能验证身份',
        canCheckAndRetry: false,
      );
    }
    return const ResumeTaskPresentation(
      state: ResumeTaskDisplayState.needsAuthenticatedVerification,
      message: '需重新认证原设备并核验暂存文件',
      canCheckAndRetry: true,
    );
  }
}
