import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/discovery_active_probe_policy.dart';
import 'package:nearlink/services/lan_interface_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nearlink/network_discovery');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native prefixes feed bounded subnet discovery and reject invalid rows',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getInterfaces');
        return [
          {'address': '192.168.4.2', 'prefixLength': 30},
          {'address': '8.8.8.8', 'prefixLength': 24},
          {'address': '10.0.0.1', 'prefixLength': 8},
          {'address': 123, 'prefixLength': 24},
          {'address': '192.168.1.1', 'prefixLength': '24'},
          null,
        ];
      });
      final interfaces = await loadLanInterfaces();
      expect(interfaces, hasLength(3));
      expect(DiscoveryActiveProbePolicy.subnetTargets(interfaces), [
        '192.168.4.1',
      ]);
    },
    skip: !(Platform.isWindows || Platform.isAndroid),
  );

  test('no active interfaces produces no subnet probes', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await loadLanInterfaces(), isEmpty);
  }, skip: !(Platform.isWindows || Platform.isAndroid));

  test(
    'native failure reaches the service fallback instead of inventing a subnet',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'NETWORK_INTERFACES');
      });
      await expectLater(loadLanInterfaces(), throwsA(isA<PlatformException>()));
    },
    skip: !(Platform.isWindows || Platform.isAndroid),
  );
}
