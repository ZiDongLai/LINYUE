import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/discovery_probe_batch.dart';
import 'package:nearlink/services/discovery_active_probe_policy.dart';
import 'package:nearlink/services/discovery_latency_trace.dart';

void main() {
  group('E22-D4B saved IP fast probe', () {
    test('3 simultaneous probes, never 4; late first entry does not block later', () async {
      final gates = <String, Completer<void>>{};
      final entered = <String>[];
      final run = DiscoveryProbeBatch.run(
        ['old1','old2','healthy','old4'], (ip) {
          entered.add(ip);
          return (gates[ip] = Completer<void>()).future;
        });
      // async workers begin immediately, up to the bounded parallel limit.
      expect(entered, ['old1', 'old2', 'healthy']);
      gates['healthy']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(entered, ['old1', 'old2', 'healthy', 'old4']);
      gates['old1']!.complete();
      gates['old2']!.complete();
      gates['old4']!.complete();
      await run;
    });

    test('failed address does not prevent later probes', () async {
      final visited = <String>[];
      await DiscoveryProbeBatch.run(['bad1','good2','good3','good4'],
        (ip) async {
          visited.add(ip);
          if (ip == 'bad1') throw const SocketException('offline');
        });
      expect(visited.toSet(), {'bad1','good2','good3','good4'});
    });

    test('empty and few targets perform no extra requests', () async {
      var calls = 0;
      await DiscoveryProbeBatch.run([], (_) async { calls++; });
      expect(calls, 0);
      await DiscoveryProbeBatch.run(['192.168.1.6'], (_) async { calls++; });
      expect(calls, 1);
    });

    test('only saved, private, bounded targets reach scheduler', () async {
      final allowed = DiscoveryActiveProbePolicy.unicastTargets(
        ['192.168.1.6', '192.168.1.6', '8.8.8.8', '10.0.0.3']);
      final probed = <String>[];
      await DiscoveryProbeBatch.run(allowed, (ip) async { probed.add(ip); });
      expect(probed.toSet(), {'192.168.1.6','10.0.0.3'});
    });

    test('source has total per-IP budget, signed trust untouched', () {
      final source = File('lib/services/nearlink_service.dart').readAsStringSync();
      expect(source, contains('await DiscoveryProbeBatch.run(pending'));
      expect(source, contains('Duration(milliseconds: 3000)'));
      expect(source, contains('timeout(remaining())'));
      expect(source, contains('p.isManual && p.ip == ip'));
      expect(source, contains('尚需签名认证'));
      expect(source, contains('const Duration(seconds: 3)'));
      expect(source, isNot(contains('permissionToTransfer = true')));
    });

    test('UDP and health discovery never become signed identity', () {
      final trace = DiscoveryLatencyTrace();
      trace.onPeerVisible(100, via: DiscoveryTraceSource.healthProbe);
      expect(trace.summary(200), contains('未认证'));
    });
  });
}
