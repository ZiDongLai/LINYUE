import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/nearlink_service.dart';

void main() {
  test('legacy plaintext upload is disabled by default and in production', () {
    final defaultService = NearLinkService(deviceName: 'default');
    final productionService = NearLinkService(
      deviceName: 'DEV9B', allowLegacyFileTransfer: false);
    try {
      expect(defaultService.allowLegacyFileTransfer, isFalse);
      expect(productionService.allowLegacyFileTransfer, isFalse);
      // A two-device test is still needed to verify POST /offer rejects
      // legacy clients without creating a receive confirmation dialog.
    } finally {
      defaultService.dispose();
      productionService.dispose();
    }
  });
}
