import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/discovery_probe_batch.dart';
import 'package:nearlink/services/discovery_active_probe_policy.dart';
import 'package:nearlink/services/discovery_latency_trace.dart';
import 'package:nearlink/services/nearlink_service.dart';

void main() {
  group('E22-D4B saved IP fast probe', () {
    test(
      '3 simultaneous probes, never 4; late first entry does not block later',
      () async {
        final gates = <String, Completer<void>>{};
        final entered = <String>[];
        final run = DiscoveryProbeBatch.run(
          ['old1', 'old2', 'healthy', 'old4'],
          (ip) {
            entered.add(ip);
            return (gates[ip] = Completer<void>()).future;
          },
        );
        // async workers begin immediately, up to the bounded parallel limit.
        expect(entered, ['old1', 'old2', 'healthy']);
        gates['healthy']!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(entered, ['old1', 'old2', 'healthy', 'old4']);
        gates['old1']!.complete();
        gates['old2']!.complete();
        gates['old4']!.complete();
        await run;
      },
    );

    test('failed address does not prevent later probes', () async {
      final visited = <String>[];
      await DiscoveryProbeBatch.run(['bad1', 'good2', 'good3', 'good4'], (
        ip,
      ) async {
        visited.add(ip);
        if (ip == 'bad1') throw const SocketException('offline');
      });
      expect(visited.toSet(), {'bad1', 'good2', 'good3', 'good4'});
    });

    test('empty and few targets perform no extra requests', () async {
      var calls = 0;
      await DiscoveryProbeBatch.run([], (_) async {
        calls++;
      });
      expect(calls, 0);
      await DiscoveryProbeBatch.run(['192.168.1.6'], (_) async {
        calls++;
      });
      expect(calls, 1);
    });

    test('only saved, private, bounded targets reach scheduler', () async {
      final allowed = DiscoveryActiveProbePolicy.unicastTargets([
        '192.168.1.6',
        '192.168.1.6',
        '8.8.8.8',
        '10.0.0.3',
      ]);
      final probed = <String>[];
      await DiscoveryProbeBatch.run(allowed, (ip) async {
        probed.add(ip);
      });
      expect(probed.toSet(), {'192.168.1.6', '10.0.0.3'});
    });

    test(
      'small private LAN subnets enumerate hosts but skip wide networks',
      () {
        final targets = DiscoveryActiveProbePolicy.subnetTargets([
          const LanInterfaceSnapshot(
            address: '192.168.20.10',
            prefixLength: 24,
          ),
          const LanInterfaceSnapshot(address: '172.20.0.8', prefixLength: 16),
          const LanInterfaceSnapshot(address: '8.8.8.8', prefixLength: 24),
          const LanInterfaceSnapshot(
            address: '192.168.30.10',
            prefixLength: 31,
          ),
        ]);

        expect(targets, hasLength(253));
        expect(targets, contains('192.168.20.1'));
        expect(targets, contains('192.168.20.254'));
        expect(targets, isNot(contains('192.168.20.10')));
        expect(targets, isNot(contains('172.20.0.1')));
        expect(targets, isNot(contains('8.8.8.8')));
      },
    );

    test('a /22 subnet excludes network, broadcast and local addresses', () {
      final targets = DiscoveryActiveProbePolicy.subnetTargets([
        const LanInterfaceSnapshot(address: '10.4.0.7', prefixLength: 22),
      ]);

      expect(targets, hasLength(1021));
      expect(targets, contains('10.4.0.1'));
      expect(targets, contains('10.4.3.254'));
      expect(targets, isNot(contains('10.4.0.0')));
      expect(targets, isNot(contains('10.4.3.255')));
      expect(targets, isNot(contains('10.4.0.7')));
    });

    test('subnet target count and duplicate interfaces stay bounded', () {
      final targets = DiscoveryActiveProbePolicy.subnetTargets([
        const LanInterfaceSnapshot(address: '10.1.2.3', prefixLength: 22),
        const LanInterfaceSnapshot(address: '10.1.2.3', prefixLength: 22),
        const LanInterfaceSnapshot(address: '10.1.4.1', prefixLength: 22),
      ]);

      expect(targets.length, 1022);
      expect(targets.toSet(), hasLength(targets.length));
      expect(targets.length, lessThanOrEqualTo(1022));
    });

    test('service starts one automatic local subnet discovery pass', () async {
      var interfaceReads = 0;
      final service = NearLinkService(
        deviceName: 'LAN discovery startup',
        lanInterfaceProvider: () async {
          interfaceReads++;
          return const [];
        },
      );
      addTearDown(service.dispose);

      await service.start();
      await Future<void>.delayed(Duration.zero);

      expect(interfaceReads, 1);
      await service.stop();
    });

    test('source has total per-IP budget, signed trust untouched', () {
      final source = File(
        'lib/services/nearlink_service.dart',
      ).readAsStringSync();
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
