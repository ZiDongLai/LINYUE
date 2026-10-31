import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/authenticated_peer_binding_policy.dart';
import 'package:nearlink/services/manual_peer_target_store.dart';

void main() {
  group('E22-C FIX1 manual peer target persistence', () {
    late Directory temp;
    late ManualPeerTargetStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('linyue_manual_targets_');
      store = ManualPeerTargetStore(directory: temp);
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('persists unique private LAN IPv4 targets only', () async {
      await store.save([
        '192.168.1.6',
        ' 192.168.1.6 ',
        '10.0.0.8',
        '127.0.0.1',
        '8.8.8.8',
        '192.168.1.999',
      ]);
      expect(await store.load(), ['10.0.0.8', '192.168.1.6']);
    });

    test('corrupt primary falls back to backup without deleting it', () async {
      await temp.create(recursive: true);
      final primary = File('${temp.path}${Platform.pathSeparator}targets.json');
      final backup = File('${primary.path}.bak');
      await primary.writeAsString('{not-json');
      await backup.writeAsString(jsonEncode(['192.168.1.6', '8.8.8.8']));

      expect(await store.load(), ['192.168.1.6']);
      expect(await primary.exists(), isTrue);
      expect(await backup.exists(), isTrue);
    });

    test('corrupt target data never clears other app data or invents an IP', () async {
      await temp.create(recursive: true);
      final primary = File('${temp.path}${Platform.pathSeparator}targets.json');
      await primary.writeAsString('{broken');
      expect(await store.load(), isEmpty);
      expect(await primary.exists(), isTrue);
    });

    test('bounded address list prevents unbounded locator growth', () async {
      final ips = List<String>.generate(40, (i) => '192.168.1.${i + 1}');
      await store.save(ips);
      expect((await store.load()).length, ManualPeerTargetStore.maxTargets);
    });

    test('concurrent saves serialize and leave one complete valid snapshot', () async {
      await Future.wait([
        store.save(['192.168.1.6']),
        store.save(['10.0.0.8', '192.168.1.9']),
      ]);
      expect(await store.load(), ['10.0.0.8', '192.168.1.9']);
    });
  });

  group('E22-C FIX1 authenticated conversation binding', () {
    test('missing discovery card can be represented by a manual locator', () {
      expect(AuthenticatedPeerBindingPolicy.shouldCreateManualLocator(
        knownPeerIps: const ['192.168.1.2'],
        authenticatedRemoteIp: '192.168.1.6',
      ), isTrue);
    });

    test('existing discovered/manual peer at same IP is reused', () {
      expect(AuthenticatedPeerBindingPolicy.shouldCreateManualLocator(
        knownPeerIps: const ['192.168.1.6'],
        authenticatedRemoteIp: '192.168.1.6',
      ), isFalse);
    });

    test('pairing may select the endpoint when there is no active conversation', () {
      expect(AuthenticatedPeerBindingPolicy.shouldSelectPeer(
        activePeerIp: null,
        remoteIp: '192.168.1.6',
      ), isTrue);
    });

    test('pairing for another IP never steals the active conversation', () {
      expect(AuthenticatedPeerBindingPolicy.shouldSelectPeer(
        activePeerIp: '192.168.1.2',
        remoteIp: '192.168.1.6',
      ), isFalse);
    });
  });
}
