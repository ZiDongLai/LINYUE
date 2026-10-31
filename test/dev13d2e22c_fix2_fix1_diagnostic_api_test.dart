import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/nearlink_service.dart';

void main() {
  group('DEV13D2E22-C FIX2 FIX1: diagnostic logging API', () {
    test('public logDiagnostic records diagnostics without starting network', () {
      final service = NearLinkService(
        deviceName: 'Diagnostic API Test',
        allowLegacyFileTransfer: false,
      );
      var notifications = 0;
      service.addListener(() => notifications++);
      try {
        expect(service.running, isFalse);
        service.logDiagnostic('设备发现检查：等待网络');
        expect(service.logs, hasLength(1));
        expect(service.logs.first, contains('设备发现检查：等待网络'));
        expect(notifications, 1);
        expect(service.running, isFalse);
        expect(service.peers, isEmpty);
        expect(service.allowLegacyFileTransfer, isFalse);
      } finally {
        service.dispose();
      }
    });

    test('diagnostic messages use existing bounded 40-entry log', () {
      final service = NearLinkService(deviceName: 'Log Limit Test');
      try {
        for (var i = 0; i < 45; i++) {
          service.logDiagnostic('check-$i');
        }
        expect(service.logs, hasLength(40));
        expect(service.logs.first, contains('check-44'));
        expect(service.logs.last, contains('check-5'));
      } finally {
        service.dispose();
      }
    });
  });
}
