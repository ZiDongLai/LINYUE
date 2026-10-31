import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/discovery_active_probe_policy.dart';
import 'package:nearlink/services/nearlink_service.dart';

void main() {
  group('E22-D2 saved-IP discovery (never authorizes trust)', () {
    test('private LAN targets are deduplicated and bounded', () {
      expect(DiscoveryActiveProbePolicy.unicastTargets([
        '192.168.1.6', '192.168.1.6', ' 10.1.1.3 ', '172.20.3.9',
      ]), ['192.168.1.6', '10.1.1.3', '172.20.3.9']);
      final all = List.generate(30, (i) => '192.168.1.${i + 1}');
      expect(DiscoveryActiveProbePolicy.unicastTargets(all).length, 8);
    });

    test('public, loopback, link-local and malformed IPs are never probed', () {
      final targets = DiscoveryActiveProbePolicy.unicastTargets([
        '8.8.8.8', '127.0.0.1', '169.254.1.1', '0.0.0.0',
        '192.168.1.255', '192.168.1.0', '192.168.1.999',
        '192.168.01.6', '172.32.1.3', '192.168.1.6',
      ]);
      expect(targets, ['192.168.1.6']);
    });

    test('health payload is only accepted as untrusted discovery metadata', () {
      final data = jsonEncode({
        'protocol': 'nearlink/0.1',
        'id': 'aaaaaaaaaaaaaaaaaaaaaaaa',
        'name': 'Android · 我的手机',
      });
      final candidate = DiscoveryActiveProbePolicy.parseHealthResponse(data,
        ip: '192.168.1.6', selfId: 'bbbbbbbbbbbbbbbbbbbbbbbb');
      expect(candidate?.id, 'aaaaaaaaaaaaaaaaaaaaaaaa');
      expect(candidate?.name, 'Android · 我的手机');
    });

    test('self, wrong protocol, invalid identity are rejected', () {
      final data = jsonEncode({
        'protocol': 'nearlink/0.1', 'id': 'aaaaaaaaaaaaaaaaaaaaaaaa',
      });
      expect(DiscoveryActiveProbePolicy.parseHealthResponse(data,
        ip: '192.168.1.6', selfId: 'aaaaaaaaaaaaaaaaaaaaaaaa'), isNull);
      expect(DiscoveryActiveProbePolicy.parseHealthResponse(
        '{"protocol":"wrong","id":"${'aaaaaaaaaaaaaaaaaaaaaaaa'}"}',
        ip: '192.168.1.6', selfId: 'bbbbbbbbbbbbbbbbbbbbbbbb'), isNull);
      expect(DiscoveryActiveProbePolicy.parseHealthResponse(
        '{"protocol":"nearlink/0.1","id":"name-only"}',
        ip: '192.168.1.6', selfId: 'bbbbbbbbbbbbbbbbbbbbbbbb'), isNull);
      expect(DiscoveryActiveProbePolicy.parseHealthResponse(data,
        ip: '8.8.8.8', selfId: 'bbbbbbbbbbbbbbbbbbbbbbbb'), isNull);
    });

    test('invalid JSON and oversized /health are safely ignored', () {
      expect(DiscoveryActiveProbePolicy.parseHealthResponse('{broken',
        ip: '192.168.1.6', selfId: 'bbbbbbbbbbbbbbbbbbbbbbbb'), isNull);
      expect(DiscoveryActiveProbePolicy.parseHealthResponse('x' * 4097,
        ip: '192.168.1.6', selfId: 'bbbbbbbbbbbbbbbbbbbbbbbb'), isNull);
    });

    test('older peers without name use an unverified fallback label', () {
      final data = jsonEncode({'protocol': 'nearlink/0.1', 'id': 'aaaaaaaaaaaaaaaaaaaaaaaa'});
      expect(DiscoveryActiveProbePolicy.parseHealthResponse(data,
        ip: '192.168.1.6', selfId: 'bbbbbbbbbbbbbbbbbbbbbbbb')?.name,
        '局域网设备 192.168.1.6');
    });

    test('existing NearLink manual-peer and log API remain intact', () {
      final service = NearLinkService(deviceName: 'E22-D2 test');
      service.addManualPeer('192.168.1.6');
      service.logDiagnostic('重连操作测试');
      expect(service.peers.single.isManual, isTrue);
      expect(service.logs.first, contains('重连操作测试'));
      service.dispose();
    });
  });
}
