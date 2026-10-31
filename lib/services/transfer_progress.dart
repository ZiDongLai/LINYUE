// DEV10-A: UI presentation of measured transport counters, never fabricated.
// Sending progress counts ciphertext bytes flushed to the local socket, not
// receiver-confirmed bytes.  Only an authenticated receipt marks completion.
import 'dart:math' as math;

enum TransferProgressPhase {
  preparing,
  authenticating,
  awaitingApproval,
  uploading,
  receiving,
  verifying,
  saving,
  completed,
  failed,
}

class TransferProgressInfo {
  const TransferProgressInfo({
    required this.name,
    required this.direction,
    required this.phase,
    required this.totalBytes,
    required this.transferredBytes,
    required this.elapsed,
  });

  final String name;
  final String direction; // 'send' or 'receive'
  final TransferProgressPhase phase;
  final int totalBytes;
  final int transferredBytes;
  final Duration elapsed;

  int get safeBytes => math.min(math.max(0, transferredBytes), math.max(0, totalBytes));
  double? get fraction => totalBytes <= 0 ? null : safeBytes / totalBytes;
  int? get percent => fraction == null ? null : (fraction! * 100).floor();
  double? get speedBytesPerSecond {
    if (safeBytes == 0 || elapsed.inMilliseconds <= 0) return null;
    return safeBytes * 1000 / elapsed.inMilliseconds;
  }
  Duration? get eta {
    final speed = speedBytesPerSecond;
    if (speed == null || speed <= 0 || totalBytes <= 0 || safeBytes >= totalBytes) return null;
    return Duration(milliseconds: ((totalBytes - safeBytes) * 1000 / speed).ceil());
  }
  bool get isBytePhase => phase == TransferProgressPhase.uploading ||
      phase == TransferProgressPhase.receiving;
  String get phaseLabel {
    switch (phase) {
      case TransferProgressPhase.preparing: return '准备文件';
      case TransferProgressPhase.authenticating: return '验证加密会话';
      case TransferProgressPhase.awaitingApproval: return '等待对方确认';
      case TransferProgressPhase.uploading: return '已提交到发送端网络缓冲';
      case TransferProgressPhase.receiving: return '接收中 · 尚待校验';
      case TransferProgressPhase.verifying: return '等待并核对加密回执';
      case TransferProgressPhase.saving: return '正在校验并保存';
      case TransferProgressPhase.completed: return '安全传输完成';
      case TransferProgressPhase.failed: return '传输失败';
    }
  }
}
