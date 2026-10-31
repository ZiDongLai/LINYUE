import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/discovery_packet_diagnostics.dart';
import 'package:nearlink/services/discovery_packet_journal.dart';

const _remoteId = '0123456789abcdef01234567';
const _selfId = 'fedcba9876543210fedcba98';
const _session = 'aaaaaaaaaaaaaaaaaaaaaaaa';
Map<String, Object?> hello() => {
  'protocol': 'nearlink/0.1', 'type': 'hello', 'id': _remoteId,
  'name': 'Android · 手机 / Windows', 'port': 46729,
};
DiscoveryPacketClassification classify(List<int> bytes, {String self = _selfId}) =>
    DiscoveryPacketClassifier.classify(bytes,
        expectedProtocol: 'nearlink/0.1', selfId: self);
DiscoveryPacketJournal journal({String id = _remoteId, String? sid = _session,
    int limit = 256, int cache = 256, bool enabled = true}) =>
    DiscoveryPacketJournal(platform: 'test', deviceId: id, sessionId: sid,
      enabled: enabled, eventLimit: limit, cacheLimit: cache, emit: (_) {});

void main() {
  test('B5 receive context links raw event and read index without changing bytes', () {
    final j = journal()..startRun();
    final packet = j.prepare(hello());
    final r = j.receive(packet.bytes, '127.0.0.1', 46728,
      context: {'ev': 7, 'socket_run': 1, 'read_index': 2});
    expect(j.records.last['ev'], 7);
    expect(j.records.last['read_index'], 2);
    expect(r.hash, packet.hash);
    j.annotate(r, classify(packet.bytes).body);
    expect(r.metadata['sender_session_matches_local'], isTrue);
    expect(r.metadata['complete'], 'declared_length_matches');
    expect(classify(packet.bytes).kind, DiscoveryPacketKind.validHello);
  });
  test('optional JSON fields pass the unchanged production classifier', () {
    final j = journal()..startRun();
    final packet = j.prepare(hello());
    final body = jsonDecode(utf8.decode(packet.bytes)) as Map<String, dynamic>;
    expect(classify(packet.bytes).kind, DiscoveryPacketKind.validHello);
    expect(body['protocol'], 'nearlink/0.1');
    expect(body['port'], 46729);
    expect(body['_d4']['n'], packet.bytes.length);
    expect(body['_d4']['s'], _session);
    expect(body['_d4']['q'], packet.sequence);
    expect(body['_d4']['u'], packet.senderUs);
  });

  test('every physical send preparation has a different sequence and digest', () {
    final j = journal()..startRun();
    final broadcast = j.prepare(hello());
    final unicast = j.prepare(hello());
    expect(unicast.sequence, broadcast.sequence + 1);
    expect(unicast.hash, isNot(broadcast.hash));
  });

  test('stop/start runs preserve application session and sequence uniqueness', () {
    final j = journal()..startRun();
    final old = j.prepare(hello());
    j.startRun();
    final current = j.prepare(hello());
    expect(j.session, _session);
    expect(j.run, 2);
    expect(current.sequence, old.sequence + 1);
    expect(current.hash, isNot(old.hash));
    expect(journal(sid: null).session, isNot(journal(sid: null).session));
  });

  test('legacy without diagnostics remains valid and age is explicitly unknown', () {
    final j = journal()..startRun();
    final bytes = utf8.encode(jsonEncode(hello()));
    final r = j.receive(bytes, '192.168.1.6', 46728);
    j.annotate(r, classify(bytes).body);
    expect(classify(bytes).isProtocolValidHello, isTrue);
    expect(r.metadata['diag'], 'absent');
    expect(r.metadata['old_session'], 'unknown_requires_sender_journal');
    expect(r.metadata['complete'], 'unknown_no_declared_length');
  });

  for (final bad in [null, 'bad', {'v': 99}, {'v': 1, 's': '\nsecret'},
    {'v': 1, 's': _session, 'r': 1, 'q': -1, 'u': 0, 'n': 200}]) {
    test('bad or unsupported optional extension is ignored safely: $bad', () {
      final bytes = utf8.encode(jsonEncode({...hello(), '_d4': bad}));
      final j = journal()..startRun();
      final r = j.receive(bytes, '192.168.1.6', 46728);
      final result = classify(bytes);
      j.annotate(r, result.body);
      expect(result.kind, DiscoveryPacketKind.validHello);
      expect(r.metadata['diag'], isNot('v1'));
      expect(jsonEncode(j.records), isNot(contains('\nsecret')));
    });
  }

  test('TX and RX match by session/run/sequence AND exact payload SHA256', () {
    final sender = journal()..startRun();
    final receiver = journal(id: _selfId, sid: 'bbbbbbbbbbbbbbbbbbbbbbbb')..startRun();
    final packet = sender.prepare(hello());
    sender.sent(packet, target: '255.255.255.255', port: 46728,
      bindAddress: '0.0.0.0', localPort: 46728, returned: packet.bytes.length, listening: true);
    final receipt = receiver.receive(packet.bytes, '192.168.1.6', 46728);
    receiver.annotate(receipt, classify(packet.bytes).body);
    receiver.result(receipt, reason: 'valid_hello', protocolCompatible: true,
      remoteHello: true, peerUpdate: 'added');
    final tx = sender.records.last;
    final rx = receiver.records.last;
    for (final field in ['ps', 'pr', 'q', 'pu', 'h', 'n']) {
      expect(rx[field], tx[field]);
    }
    expect(rx['complete'], 'declared_length_matches');
    expect(rx['src'], '192.168.1.6');
    expect(rx['sp'], 46728);
    expect(rx['sender_device'], discoveryShortHash(_remoteId));
    expect(jsonEncode(rx), isNot(contains(_remoteId)));
  });

  test('duplicate observations are exact bytes, not merely repeated IDs', () {
    final j = journal()..startRun();
    final a = j.prepare(hello());
    final b = j.prepare(hello());
    expect(j.receive(a.bytes, '192.168.1.6', 46728).duplicate, isFalse);
    expect(j.receive(a.bytes, '192.168.1.6', 46728).duplicate, isTrue);
    expect(j.receive(b.bytes, '192.168.1.6', 46728).duplicate, isFalse);
    expect(j.receive(a.bytes, '192.168.1.6', 46727).duplicate, isFalse);
  });

  test('random remote session cannot be ordered without sender evidence', () {
    final sender = journal()..startRun();
    final receiver = journal(sid: 'bbbbbbbbbbbbbbbbbbbbbbbb')..startRun();
    for (final sid in ['aaaaaaaaaaaaaaaaaaaaaaaa', 'cccccccccccccccccccccccc']) {
      final packet = journal(sid: sid)..startRun();
      final bytes = packet.prepare(hello()).bytes;
      final r = receiver.receive(bytes, '192.168.1.6', 46728);
      receiver.annotate(r, classify(bytes).body);
      expect(r.metadata['old_session'], 'unknown_requires_sender_journal');
    }
    final old = sender.prepare(hello());
    sender.startRun();
    final r = sender.receive(old.bytes, '192.168.1.6', 46728);
    sender.annotate(r, classify(old.bytes).body);
    expect(r.metadata['old_session'], 'declared_previous_local_run');
  });

  test('length inconsistency and reused tuple are diagnosable, not trust gates', () {
    final j = journal()..startRun();
    final packet = j.prepare(hello());
    final r1 = j.receive(packet.bytes, '192.168.1.6', 46728);
    j.annotate(r1, classify(packet.bytes).body);
    final changed = jsonDecode(utf8.decode(packet.bytes)) as Map<String, dynamic>;
    changed['name'] = 'Changed and longer than before';
    final badBytes = utf8.encode(jsonEncode(changed));
    final r2 = j.receive(badBytes, '192.168.1.6', 46728);
    j.annotate(r2, classify(badBytes).body);
    expect(r2.hash, isNot(r1.hash));
    expect(r2.metadata['tuple_conflict'], isTrue);
    expect(r2.metadata['complete'], 'declared_length_mismatch');
    expect(classify(badBytes).isProtocolValidHello, isTrue);
  });

  test('local send failure cannot imply peer receipt', () {
    final j = journal()..startRun();
    final packet = j.prepare(hello());
    j.sent(packet, target: '255.255.255.255', port: 46728,
      bindAddress: '0.0.0.0', localPort: 46728, error: 'SocketException:10051', listening: true);
    expect(j.records.last['accepted'], isFalse);
    expect(j.records.where((e) => e['event'] == 'rx'), isEmpty);
  });

  test('raw receive and failed JSON parsing are separate events', () {
    final j = journal()..startRun();
    for (final bytes in [[0xff], utf8.encode('{"protocol":'), utf8.encode('[]')]) {
      final r = j.receive(bytes, '192.168.1.6', 46728);
      expect(j.records.last['event'], 'rx');
      final result = classify(bytes);
      j.annotate(r, result.body);
      j.result(r, reason: result.kind.name, protocolCompatible: false,
        remoteHello: false, peerUpdate: 'filtered');
      expect(j.records.last['remote_hello'], isFalse);
      expect(j.records.last['reason'], isNot('valid_hello'));
    }
  });

  test('event volume and dedup memory are bounded; summary preserves omissions', () {
    final j = journal(limit: 8, cache: 4)..startRun();
    for (var i = 0; i < 50; i++) {
      final r = j.receive([i], '192.168.1.6', 46728);
      j.result(r, reason: 'malformedJson', protocolCompatible: false,
        remoteHello: false, peerUpdate: 'filtered');
    }
    expect(j.records.length, 8);
    j.summary('test');
    expect(j.records.last['suppressed'], greaterThan(0));
    expect(j.records.last['dedup_cache'], 4);
    expect((j.records.last['counts'] as Map)['reason:malformedJson'], 50);
  });

  test('disabled diagnostics produce the unchanged legacy shape', () {
    final j = journal(enabled: false)..startRun();
    expect(jsonDecode(utf8.decode(j.prepare(hello()).bytes)), hello());
    expect(j.records, isEmpty);
  });

  test('failed log sink does not throw into the discovery service', () {
    final j = DiscoveryPacketJournal(platform: 'test', deviceId: _selfId,
      emit: (_) => throw StateError('collector closed'))..startRun();
    final packet = j.prepare(hello());
    final receipt = j.receive(packet.bytes, '192.168.1.6', 46728);
    j.annotate(receipt, classify(packet.bytes).body);
    j.result(receipt, reason: 'valid_hello', protocolCompatible: true,
      remoteHello: true, peerUpdate: 'added');
    j.summary('test');
    expect(j.records.last['sink_failures'], greaterThan(0));
  });
}
