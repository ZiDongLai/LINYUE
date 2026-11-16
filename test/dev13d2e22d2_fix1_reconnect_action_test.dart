import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// UI wiring regression guard. The full platform popup/handshake must still be
/// checked manually on Windows and Android; this file does not fake a network.
void main() {
  final mainSource = File('lib/main.dart').readAsStringSync();

  test('direct retry button bypasses the nested three-dot popup', () {
    expect(mainSource, contains("'重新认证'"));
    expect(mainSource, contains('_DeviceManagerSelection('));
    expect(mainSource, contains("action: 'reconnect',"));
    expect(mainSource, contains('onPressed: () => Navigator.of(dialogContext).pop('));
  });

  test('three-dot actions defer until popup route is dismissed', () {
    expect(mainSource, contains('WidgetsBinding.instance.addPostFrameCallback((_) {'));
    expect(mainSource, contains('if (!dialogContext.mounted) return;'));
    expect(mainSource, contains('_DeviceManagerSelection('));
    expect(mainSource, contains('action: action,'));
  });

  test('all retry paths call the existing signed identity handshake', () {
    expect(mainSource, contains("if (selected.action == 'reconnect')"));
    expect(mainSource, contains('await _reconnectManagedPeer(peer);'));
    expect(mainSource, contains('pairing.tryResume(remoteIp: peer.ip)'));
    expect(mainSource, contains('设备重连：签名验证成功'));
    expect(mainSource, contains('设备重连：签名验证失败'));
  });

  test('manager does not show stale generic prompt after verified identity', () {
    expect(mainSource, contains('本次已通过签名验证 · 发送时仍会复核'));
    expect(mainSource, contains('最近重新认证失败 · 请检查网络和身份'));
    expect(mainSource, contains('_verifiedFingerprints[_peerKey(peer)]'));
    expect(mainSource, contains('PeerManagementPolicy.displayStatus('));
  });

  test('manual addresses do not grant trust by themselves', () {
    expect(mainSource, contains('对端签名身份与已登记设备不匹配'));
    expect(mainSource, contains('未能重新确认原设备的签名身份'));
  });
}
