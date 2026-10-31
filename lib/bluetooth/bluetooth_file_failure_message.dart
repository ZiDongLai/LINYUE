/// Short UI feedback only. Native exception details stay in test diagnostics.
/// Both a local PlatformException and the peer's bounded file-error are handled.
String bluetoothFileFailureMessage(Object error) {
  final text = '$error'.toLowerCase();
  if (text.contains('结果未确认') ||
      text.contains('结果核对') ||
      text.contains('result unknown')) {
    return '文件结果未确认，请核对结果；不会重复发送或改用局域网。';
  }
  if (text.contains('enospc') ||
      text.contains('disk full') ||
      text.contains('no space') ||
      text.contains('空间不足')) {
    return '接收设备存储空间不足，请腾出空间后重新发送。';
  }
  if (text.contains('eacces') ||
      text.contains('eperm') ||
      text.contains('permission denied') ||
      text.contains('权限受限')) {
    return '接收设备保存权限受限，文件未完成保存。请保留诊断后重试。';
  }
  if (text.contains('sha-256') ||
      text.contains('sha256') ||
      text.contains('完整性校验')) {
    return '文件完整性校验未通过，请重新发送。';
  }
  if (text.contains('超时') || text.contains('timeout')) {
    return '未及时收到文件完成确认，请检查连接后重新发送。';
  }
  if (text.contains('断开') ||
      text.contains('closed') ||
      text.contains('disconnect') ||
      text.contains('会话')) {
    return '蓝牙连接已中断或会话失效，请重新连接后发送。';
  }
  return '文件未确认保存成功，请检查接收设备并重新发送；详细原因见测试与诊断。';
}
