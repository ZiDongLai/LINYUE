import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/discovery_active_probe_policy.dart';
import 'package:nearlink/services/discovery_warmup_policy.dart';
import 'package:nearlink/services/nearlink_service.dart';
import 'package:nearlink/services/same_platform_connection_policy.dart';

const String _me = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _other = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  group('E22-D3 discovery and authentication final guards', () {
    test('warmup is bounded and normal broadcast is still present', () {
      expect(DiscoveryWarmupPolicy.warmupDelays.length, 2);
      expect(DiscoveryWarmupPolicy.warmupDelays.first,
          const Duration(milliseconds: 350));
      expect(DiscoveryWarmupPolicy.replyCooldown,
          const Duration(seconds: 12));
      final serviceSource = File('lib/services/nearlink_service.dart')
          .readAsStringSync();
      expect(serviceSource, contains('const Duration(seconds: 3)'));
      expect(serviceSource, contains('发现诊断：启动至首次发现'));
    });

    test('received discoveries cannot trigger unbounded reply storms', () {
      final throttle = DiscoveryReplyThrottle();
      final now = DateTime.utc(2026, 10, 21, 0, 0);
      expect(throttle.allow('192.168.1.6', now), isTrue);
      expect(throttle.allow('192.168.1.6',
          now.add(const Duration(seconds: 5))), isFalse);
      expect(throttle.allow('192.168.1.6',
          now.add(const Duration(seconds: 12))), isTrue);
      throttle.clear();
      expect(throttle.allow('192.168.1.6',
          now.add(const Duration(seconds: 13))), isTrue);
    });

    test('saved address probing is bounded, deduplicated and LAN only', () {
      final targets = DiscoveryActiveProbePolicy.unicastTargets([
        '192.168.1.6', '192.168.1.6', '10.1.2.3',
        '8.8.8.8', '127.0.0.1', '169.254.1.4',
        '192.168.1.255', '192.168.1.0',
      ]);
      expect(targets, ['192.168.1.6', '10.1.2.3']);
      expect(DiscoveryActiveProbePolicy.unicastTargets(
          List.generate(40, (i) => '192.168.2.${i + 1}')).length, 8);
    });

    test('unsigned /health is discoverable but never verifies signed identity', () {
      final response = jsonEncode({
        'protocol': 'nearlink/0.1',
        'id': '0123456789abcdef01234567',
        'name': 'Android · 我的手机',
      });
      final hint = DiscoveryActiveProbePolicy.parseHealthResponse(
        response, ip: '192.168.1.6', selfId: 'fedcba9876543210fedcba98',
      );
      expect(hint, isNotNull);
      expect(hint!.name, 'Android · 我的手机');
      final decision = SamePlatformConnectionPolicy.evaluate(
        const SamePlatformPeerCandidate(
          localFingerprint: _me, remoteIp: '192.168.1.6',
          reachable: true, enrolledFingerprint: _other,
          authenticatedFingerprint: null,
          encryptedChannelReady: false,
          authenticatedProtocolConfirmed: false,
        ),
      );
      expect(decision.outcome, PeerPreflightOutcome.pairingRequired);
      expect(decision.mayAttemptSecureOperation, isFalse);
    });

    test('self and malformed unsigned devices are ignored', () {
      final response = jsonEncode({
        'protocol': 'nearlink/0.1', 'id': '0123456789abcdef01234567',
      });
      expect(DiscoveryActiveProbePolicy.parseHealthResponse(response,
        ip: '192.168.1.6', selfId: '0123456789abcdef01234567'), isNull);
      expect(DiscoveryActiveProbePolicy.parseHealthResponse(response,
        ip: '8.8.8.8', selfId: 'fedcba9876543210fedcba98'), isNull);
    });

    test('saved manual address is a display hint not signed trust', () {
      final service = NearLinkService(deviceName: 'E22-D3 test');
      addTearDown(service.dispose);
      service.addManualPeer('192.168.1.6');
      expect(service.peers.single.isManual, isTrue);
      expect(service.removeDisplayedPeer(
        peerId: 'manual:192.168.1.6', ip: '192.168.1.6'), isTrue);
      expect(service.peers, isEmpty);
      service.logDiagnostic('E22-D3 guard verified');
      expect(service.logs.first, contains('E22-D3 guard verified'));
    });

    test('a verified signed identity still requires an encrypted channel', () {
      const candidate = SamePlatformPeerCandidate(
        localFingerprint: _me, remoteIp: '192.168.1.6',
        reachable: true, enrolledFingerprint: _other,
        authenticatedFingerprint: _other,
        encryptedChannelReady: false,
        authenticatedProtocolConfirmed: false,
      );
      expect(SamePlatformConnectionPolicy.evaluate(candidate).outcome,
          PeerPreflightOutcome.encryptedChannelNotReady);
    });

    test('current device manager retains real reconnect action and UI feedback', () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(source, contains('重新认证'));
      expect(source, contains('pairing.tryResume(remoteIp: peer.ip)'));
      expect(source, contains('设备重连：签名验证成功'));
      expect(source, contains('本次已通过签名验证 · 发送时仍会复核'));
    });
  });
}
