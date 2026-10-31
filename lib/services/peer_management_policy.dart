/// DEV13D2E22-C FIX2 — only LOCAL list management.
/// Neither presence nor an IP grants authentication or file-send permission.
abstract final class PeerManagementPolicy {
  static bool canRemoveFromList({
    required bool isManual,
    required bool isStale,
    required bool lastReconnectFailed,
  }) => isManual || isStale || lastReconnectFailed;

  static String displayStatus({
    required bool isManual,
    required bool isStale,
    required bool lastReconnectFailed,
  }) {
    if (lastReconnectFailed) return '最近重连失败 · 可移除本机列表';
    if (isManual) return '保存的手动地址 · 未证明在线';
    if (isStale) return '自动发现 · 暂时离线';
    return '自动发现 · 最近可达（仍需签名认证）';
  }
}
