import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/discovery_latency_trace.dart';

void main() {
  group('E22-D4A discovery timing (diagnostic only)', () {
    test('tracks first broadcast attempts separately from successful sends', () {
      final t = DiscoveryLatencyTrace();
      t.onBroadcast(5, accepted: false);
      t.onBroadcast(350, accepted: true);
      t.onBroadcast(1400, accepted: true);
      expect(t.firstBroadcastAttemptMs, 5);
      expect(t.firstBroadcastSuccessMs, 350);
      expect(t.broadcastAttempts, 3);
      expect(t.broadcastAccepted, 2);
    });

    test('separates any UDP packet from validated hello and display', () {
      final t = DiscoveryLatencyTrace();
      t.onDatagram(1800);
      t.onDatagram(2050);
      t.onValidHello(2050);
      t.onPeerVisible(2060, via: DiscoveryTraceSource.udpHello);
      t.onPeerVisible(8000, via: DiscoveryTraceSource.healthProbe);
      expect(t.firstDatagramMs, 1800);
      expect(t.firstValidHelloMs, 2050);
      expect(t.firstVisiblePeerMs, 2060);
      expect(t.firstVisibleSource, DiscoveryTraceSource.udpHello);
      expect(t.datagramsSeen, 2);
    });

    test('health discovery remains separate from signed identity', () {
      final t = DiscoveryLatencyTrace();
      t.onBroadcast(4, accepted: true);
      t.onPeerVisible(500, via: DiscoveryTraceSource.healthProbe);
      final s = t.summary(800);
      expect(s, contains('TCP健康探测'));
      expect(s, contains('未认证'));
      expect(s, contains('首个UDP包未发生'));
    });

    test('counters do not accept negative timestamps', () {
      final t = DiscoveryLatencyTrace();
      t.onBroadcast(-1, accepted: true);
      t.onDatagram(-1);
      t.onValidHello(-1);
      t.onPeerVisible(-1, via: DiscoveryTraceSource.udpHello);
      expect(t.broadcastAttempts, 0);
      expect(t.datagramsSeen, 0);
      expect(t.firstVisiblePeerMs, isNull);
    });

    test('service only adds observation and retains established protocol', () {
      final src = File('lib/services/nearlink_service.dart').readAsStringSync();
      expect(src, contains("import 'discovery_latency_trace.dart';"));
      expect(src, contains('const Duration(seconds: 3)'));
      expect(src, contains("'protocol': protocolVersion"));
      expect(src, contains("'type': 'hello'"));
      expect(src, contains("'发现诊断：启动至首次发现"));
      expect(src, contains("_emitDiscoveryTrace('首次设备 UDP 广播')"));
      expect(src, contains("_emitDiscoveryTrace('首次设备 TCP 健康探测')"));
      expect(src, contains('for (final timer in _discoveryTraceTimers) {'));
      expect(src, contains('timer.cancel();'));
      expect(src, isNot(contains('permissionToTransfer = true')));
    });
  });
}
