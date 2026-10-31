import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('E22-D4B2 startup probe diagnostics', () {
    test('saved IP health probing is scheduled at service startup', () {
      final source = File('lib/services/nearlink_service.dart').readAsStringSync();
      final start = source.indexOf('Future<void> start() async {');
      final end = source.indexOf('void _broadcastHello()', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final startupBody = source.substring(start, end);
      expect(startupBody, contains('_scheduleManualHealthProbe();'));
      expect(startupBody, contains('D4B2: probe already-saved manual IPs immediately'));
    });

    test('no-saved-IP case is explicit and does not claim discovery success', () {
      final source = File('lib/services/nearlink_service.dart').readAsStringSync();
      expect(source, contains('没有已保存的手动 IP；未知设备首次发现仍依赖 UDP 广播'));
      expect(source, contains('未知设备首次发现仍依赖 UDP 广播'));
    });

    test('health probe results are bounded and explicitly unauthenticated', () {
      final source = File('lib/services/nearlink_service.dart').readAsStringSync();
      expect(source, contains('D4B2 探测结果：\$ip'));
      expect(source, contains('_manualProbeFailureLoggedIps.add(ip)'));
      expect(source, contains('_manualProbeSuccessLoggedIps.add(ip)'));
      expect(source, contains('Duration(milliseconds: 3000)'));
      expect(source, contains('timeout(remaining())'));
      expect(source, contains('网络可达（尚未认证）'));
      expect(source, isNot(contains('permissionToTransfer = true')));
    });
  });
}
