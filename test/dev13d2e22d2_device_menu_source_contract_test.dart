import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Structural regression guard. This is NOT a substitute for dual-device
/// verification of actual Windows/Android popup and signed handshake.
void main() {
  test('manager returns selected intent after dialog dismissal', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('await showDialog<_DeviceManagerSelection>('));
    expect(source, contains("_DeviceManagerSelection(action: action,"));
    expect(source, contains("if (selected.action == 'reconnect')"));
    expect(source, contains('await _reconnectManagedPeer(peer);'));
  });

  test('signed reconnect announces progress and outcomes', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains(r'正在核验 ${peer.name} 的签名身份'));
    expect(source, contains('设备重连：签名验证成功'));
    expect(source, contains('设备重连：签名验证失败'));
    expect(source, contains('pairing.tryResume(remoteIp: peer.ip)'));
  });
}
