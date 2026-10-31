import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/discovery_warmup_policy.dart';
import 'package:nearlink/services/nearlink_service.dart';

void main() {
  group('E22-D1 safe warm-up', () {
    test('early packets are bounded, increasing and much earlier than 3 s', () {
      final times = DiscoveryWarmupPolicy.warmupDelays;
      expect(times.length, 2);
      expect(times.first, greaterThan(Duration.zero));
      for (var i = 1; i < times.length; i++) {
        expect(times[i], greaterThan(times[i - 1]));
      }
      expect(times.last, lessThan(const Duration(seconds: 3)));
    });

    test('first reply allowed, repeat limited by source IP', () {
      final gate = DiscoveryReplyThrottle();
      final now = DateTime.utc(2026, 10, 21);
      expect(gate.allow('192.168.1.8', now), isTrue);
      expect(gate.allow('192.168.1.8', now.add(const Duration(seconds: 2))), isFalse);
      expect(gate.allow('192.168.1.8', now.add(const Duration(seconds: 12))), isTrue);
    });

    test('separate peer IPs can each receive one immediate answer', () {
      final gate = DiscoveryReplyThrottle();
      final now = DateTime.utc(2026, 10, 21);
      expect(gate.allow('192.168.1.8', now), isTrue);
      expect(gate.allow('192.168.1.9', now), isTrue);
      expect(gate.allow('192.168.1.9', now), isFalse);
    });

    test('source tracking bounded against many spoofed names or IDs', () {
      final gate = DiscoveryReplyThrottle(maxSources: 2);
      final now = DateTime.utc(2026, 10, 21);
      expect(gate.allow('192.168.1.8', now), isTrue);
      expect(gate.allow('192.168.1.9', now), isTrue);
      expect(gate.allow('192.168.1.10', now), isTrue);
      // Oldest source was evicted, so its next discovery is allowed.
      expect(gate.allow('192.168.1.8', now), isTrue);
    });

    test('empty sender and clock reset do not bypass throttling', () {
      final gate = DiscoveryReplyThrottle();
      final now = DateTime.utc(2026, 10, 21);
      expect(gate.allow('', now), isFalse);
      expect(gate.allow('192.168.1.8', now), isTrue);
      expect(gate.allow('192.168.1.8', now.subtract(const Duration(seconds: 1))), isTrue);
    });

    test('clear only resets reply throttling', () {
      final gate = DiscoveryReplyThrottle();
      final now = DateTime.utc(2026, 10, 21);
      expect(gate.allow('192.168.1.8', now), isTrue);
      gate.clear();
      expect(gate.allow('192.168.1.8', now), isTrue);
    });

    test('existing IPv4 validation and manual locator API remain', () {
      expect(isValidIpv4('192.168.1.10'), isTrue);
      expect(isValidIpv4('192.168.1.999'), isFalse);
      final service = NearLinkService(deviceName: 'LAN diagnostic');
      service.addManualPeer('192.168.1.10');
      expect(service.peers.single.isManual, isTrue);
      service.dispose();
    });
  });
}
