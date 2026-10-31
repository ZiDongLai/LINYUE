import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/nearlink_service.dart';
import 'package:nearlink/services/discovery_packet_diagnostics.dart';
import 'package:nearlink/services/discovery_packet_journal.dart';

Future<void> until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition() && clock.elapsed < const Duration(seconds: 3)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: 'Expected real socket event within 3s');
}

void main() {
  test('same ID distinguishes local loopback from a possible remote collision', () {
    final bytes = utf8.encode(jsonEncode({
      'protocol': protocolVersion, 'type': 'hello', 'id': 'self',
      'name': 'peer', 'port': transferPort,
    }));
    DiscoveryPacketClassification classify(String ip) =>
        DiscoveryPacketClassifier.classify(bytes,
          expectedProtocol: protocolVersion, selfId: 'self', sourceIp: ip,
          localAddresses: {'192.168.1.8'});
    expect(classify('192.168.1.8').kind, DiscoveryPacketKind.selfPacket);
    expect(classify('192.168.1.6').kind,
        DiscoveryPacketKind.sameIdOtherAddress);
    expect(classify('192.168.1.6').isProtocolValidHello, isFalse);
    expect(classify('192.168.1.6').label, contains('疑似冲突'));
  });

  test('real UDP parsing, list updates, refresh and restart retain HTTP probing', () async {
    final service = NearLinkService(deviceName: 'socket regression');
    final sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final health = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    health.listen((request) async {
      requests++;
      request.response.write(jsonEncode({
        'protocol': protocolVersion, 'id': 'remote-device',
      }));
      await request.response.close();
    });
    addTearDown(() async {
      sender.close();
      await health.close(force: true);
      await service.stop();
      service.dispose();
    });
    void send(List<int> data) => sender.send(
        data, InternetAddress.loopbackIPv4, discoveryPort);
    List<int> hello(String id) => utf8.encode(jsonEncode({
      'protocol': protocolVersion, 'type': 'hello', 'id': id,
      'name': 'Android / Windows protocol', 'port': health.port,
    }));

    await service.start();
    await until(() => service.logs.any((l) => l.contains('本机 IPv4')));
    send(hello(service.deviceId));
    send(utf8.encode('{"protocol":'));
    send([0xff]);
    send(utf8.encode(jsonEncode({'protocol': 'incompatible', 'type': 'hello'})));
    await until(() => service.logs.any((l) => l.contains('协议版本不匹配')));
    expect(service.peers.where((p) => p.id == service.deviceId ||
        p.id == 'remote-device'), isEmpty);
    expect(service.logs.any((l) => l.contains('本机来源=true')), isTrue);
    send(hello('remote-device'));
    await until(() => service.peers.any((p) => p.id == 'remote-device'));
    final remote = service.peers.singleWhere((p) => p.id == 'remote-device');
    expect(remote.ip, '127.0.0.1');
    expect(remote.port, health.port);
    service.refreshPeers();
    await until(() => requests > 0);
    await service.stop();
    expect(service.peers, isEmpty);
    expect(service.running, isFalse);

    await service.start();
    send(hello('remote-device'));
    await until(() => service.peers.any((p) => p.id == 'remote-device'));
    final before = requests;
    service.refreshPeers();
    await until(() => requests > before);
  });

  test('concurrent startup calls share one bound service', () async {
    final service = NearLinkService(deviceName: 'startup regression');
    addTearDown(() async { await service.stop(); service.dispose(); });
    await Future.wait([service.start(), service.start()]);
    expect(service.running, isTrue);
  });

  test('D4B4 real UDP correlates remote, duplicate, legacy, hidden and invalid packets', () async {
    final service = NearLinkService(deviceName: 'D4B4 socket regression');
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sender = DiscoveryPacketJournal(platform: 'remote-test',
      deviceId: '0123456789abcdef01234567', emit: (_) {})..startRun();
    addTearDown(() async {
      socket.close();
      await service.stop();
      service.dispose();
    });
    final hello = <String, Object?>{
      'protocol': protocolVersion, 'type': 'hello',
      'id': '0123456789abcdef01234567', 'name': 'Remote B4', 'port': transferPort,
    };
    await service.start();
    final packet = sender.prepare(hello);
    void send(List<int> bytes) => socket.send(bytes, InternetAddress.loopbackIPv4, discoveryPort);
    Map<String, Object?>? decision(String hash, {bool duplicate = false}) {
      final matches = service.discoveryPacketEvents.where((e) =>
        e['event'] == 'rx_result' && e['h'] == hash && e['duplicate'] == duplicate);
      return matches.isEmpty ? null : matches.last;
    }
    send(packet.bytes);
    await until(() => decision(packet.hash) != null);
    expect(decision(packet.hash)?['q'], packet.sequence);
    expect(decision(packet.hash)?['ps'], sender.session);
    expect(decision(packet.hash)?['sp'], socket.port);
    expect(decision(packet.hash)?['peer_update'], 'added');
    expect(decision(packet.hash)?['remote_hello'], isTrue);
    final receiveDecision = decision(packet.hash)!;
    final rawEvent = service.discoveryPacketEvents.firstWhere((e) =>
      e['event'] == 'socket_event' && e['ev'] == receiveDecision['ev']);
    expect(rawEvent['kind'], RawSocketEvent.read.toString());
    expect(rawEvent['same_active_socket'], isTrue);
    expect(receiveDecision['sender_session_matches_local'], isFalse);
    await until(() => service.discoveryPacketEvents.any((e) =>
      e['event'] == 'drain_end' && e['ev'] == receiveDecision['ev']));
    final drained = service.discoveryPacketEvents.firstWhere((e) =>
      e['event'] == 'drain_end' && e['ev'] == receiveDecision['ev']);
    expect(drained['reason'], 'receive_returned_null');
    expect(drained['packets'], greaterThanOrEqualTo(1));
    expect(rawEvent['us'] as int, lessThanOrEqualTo(receiveDecision['rx_us'] as int));
    expect(service.discoveryPacketEvents.any((e) => e['event'] == 'listener_register'), isTrue);
    service.recordDiscoveryUiFrame(service.peers);
    expect(service.discoveryPacketEvents.any((e) =>
      e['event'] == 'ui_frame' && e['h'] == packet.hash), isTrue);

    send(packet.bytes);
    await until(() => decision(packet.hash, duplicate: true) != null);
    expect(decision(packet.hash, duplicate: true)?['peer_update'], 'refreshed');
    expect(service.peers.where((p) => p.id == hello['id']).length, 1);
    expect(service.removeDisplayedPeer(peerId: hello['id']! as String,
      ip: '127.0.0.1', allowFailedConnection: true), isTrue);
    final hidden = sender.prepare(hello);
    send(hidden.bytes);
    await until(() => decision(hidden.hash) != null);
    expect(decision(hidden.hash)?['reason'], 'locally_hidden');
    service.refreshPeers();
    final legacy = utf8.encode(jsonEncode(hello));
    send(legacy);
    await until(() => service.peers.any((p) => p.id == hello['id']));
    expect(service.discoveryPacketEvents.any((e) =>
      e['event'] == 'rx_result' && e['diag'] == 'absent' && e['remote_hello'] == true), isTrue);
    send(utf8.encode('{"protocol":'));
    await until(() => service.discoveryPacketEvents.any((e) =>
      e['event'] == 'rx_result' && e['reason'] == 'malformedJson'));
    final events = service.discoveryPacketEvents;
    expect(events.any((e) => e['event'] == 'tx' && e['dp'] == discoveryPort &&
      e['local_port'] == discoveryPort && e['accepted'] == true), isTrue);
    expect(events.any((e) => e['event'] == 'rx_result' && e['reason'] == 'selfPacket'), isTrue);
    final oldRun = events.firstWhere((e) => e['event'] == 'service_ready')['run'];
    await service.stop();
    await until(() => service.discoveryPacketEvents.any((e) =>
      e['event'] == 'listener_done' && e['socket_run'] == oldRun));
    expect(service.discoveryPacketEvents.any((e) =>
      e['event'] == 'socket_close_requested' && e['via'] == 'stop'), isTrue);
    await service.start();
    expect(service.discoveryPacketEvents.firstWhere((e) => e['event'] == 'service_ready')['run'],
      (oldRun! as int) + 1);
  });

  test('stop requested during startup releases both protocol ports', () async {
    final service = NearLinkService(deviceName: 'stop during start');
    addTearDown(service.dispose);
    final starting = service.start();
    final stopping = service.stop();
    await starting;
    await stopping;
    expect(service.running, isFalse);
    final udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, discoveryPort, reuseAddress: false);
    final tcp = await HttpServer.bind(InternetAddress.anyIPv4, transferPort);
    udp.close();
    await tcp.close(force: true);
  });

  test('dispose cancels queued startup without reopening a listener', () async {
    final service = NearLinkService(deviceName: 'dispose during start');
    final starting = service.start();
    service.dispose();
    await starting;
    expect(service.running, isFalse);
    await expectLater(service.start(), throwsStateError);
    final udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, discoveryPort, reuseAddress: false);
    final tcp = await HttpServer.bind(InternetAddress.anyIPv4, transferPort);
    udp.close();
    await tcp.close(force: true);
  });
}
