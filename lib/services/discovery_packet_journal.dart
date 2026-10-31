import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// D4-B4 diagnostics only. None of these unsigned fields confer trust or
/// change the discovery parser's acceptance/peer update policy.
const discoveryDiagnosticBuild = 'D4-B6.2-20261022.1';

String discoveryShortHash(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 12);

class DiscoveryWirePacket {
  DiscoveryWirePacket(this.bytes, this.sequence, this.senderUs);
  final List<int> bytes;
  final int sequence;
  final int senderUs;
  String get hash => sha256.convert(bytes).toString();
}

class DiscoveryReceipt {
  DiscoveryReceipt(this.hash, this.sourceIp, this.sourcePort, this.length,
      this.receivedUs, this.duplicate);
  final String hash;
  final String sourceIp;
  final int sourcePort;
  final int length;
  final int receivedUs;
  final bool duplicate;
  final Map<String, Object?> metadata = {};
}

class DiscoveryPacketJournal {
  DiscoveryPacketJournal({required this.platform, required String deviceId,
    required this.emit, this.enabled = true, String? sessionId,
    int Function()? nowUs, this.eventLimit = 256, this.cacheLimit = 256})
      : deviceTag = discoveryShortHash(deviceId),
        session = sessionId ?? _randomSession(),
        _nowUs = nowUs ?? _startClock();

  static int Function() _startClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsedMicroseconds;
  }

  static String _randomSession() {
    final random = Random.secure();
    return List.generate(12, (_) => random.nextInt(256)
        .toRadixString(16).padLeft(2, '0')).join();
  }

  final String platform;
  final String deviceTag;
  final String session;
  final bool enabled;
  final void Function(Map<String, Object?>) emit;
  final int Function() _nowUs;
  final int eventLimit;
  final int cacheLimit;
  final _seen = <String>{};
  final _associations = <String, String>{};
  final _records = <Map<String, Object?>>[];
  final _counts = <String, int>{};
  final _pendingUi = <String, DiscoveryReceipt>{};
  final _uiRecorded = <String>{};
  int run = 0;
  int _sequence = 0;
  int _emitted = 0;
  int _suppressed = 0;
  int _sinkFailures = 0;

  List<Map<String, Object?>> get records => List.unmodifiable(_records);
  bool get hasPendingUi => _pendingUi.isNotEmpty;

  void startRun() {
    run++;
    _emitted = 0;
    _suppressed = 0;
    _sinkFailures = 0;
    _records.clear();
    _counts.clear();
    _pendingUi.clear();
    _uiRecorded.clear();
    event('start', {'utc_anchor': DateTime.now().toUtc().toIso8601String()});
  }

  void event(String event, Map<String, Object?> fields, {bool summary = false}) {
    if (!enabled) return;
    _counts.update(event, (n) => n + 1, ifAbsent: () => 1);
    if (!summary && _emitted >= eventLimit) {
      _suppressed++;
      return;
    }
    if (!summary) _emitted++;
    final record = Map<String, Object?>.unmodifiable({
      'build': discoveryDiagnosticBuild, 'event': event, 'platform': platform,
      'sid': session, 'run': run, 'us': _nowUs(), 'device': deviceTag, ...fields,
    });
    _records.add(record);
    if (_records.length > eventLimit + 8) _records.removeAt(0);
    try {
      emit(record);
    } catch (_) {
      // A debugger/log collector failure must not change LAN behavior.
      _sinkFailures++;
    }
  }

  void summary(String reason) => event('summary', {
    'reason': reason, 'suppressed': _suppressed, 'counts': Map.of(_counts),
    'dedup_cache': _seen.length, 'sink_failures': _sinkFailures,
  }, summary: true);

  /// Each physical send gets different bytes, even when destinations differ.
  DiscoveryWirePacket prepare(Map<String, Object?> hello) {
    final sequence = ++_sequence;
    final us = _nowUs();
    if (!enabled) {
      return DiscoveryWirePacket(utf8.encode(jsonEncode(hello)), sequence, us);
    }
    final diagnostic = <String, Object?>{
      'v': 1, 's': session, 'r': run, 'q': sequence, 'u': us, 'n': 0,
    };
    final body = {...hello, '_d4': diagnostic};
    var bytes = utf8.encode(jsonEncode(body));
    while (diagnostic['n'] != bytes.length) {
      diagnostic['n'] = bytes.length;
      bytes = utf8.encode(jsonEncode(body));
    }
    return DiscoveryWirePacket(bytes, sequence, us);
  }

  void sent(DiscoveryWirePacket packet, {required String target,
      required int port, required String bindAddress, required int localPort,
      int? returned, String? error, required bool listening}) => event('tx', {
    'stage': 'C', 'ps': session, 'pr': run, 'q': packet.sequence,
    'pu': packet.senderUs, 'h': packet.hash, 'type': 'hello',
    'dst': target, 'dp': port, 'n': packet.bytes.length,
    'bind': bindAddress, 'local_port': localPort,
    'egress_ip': 'unknown_os_selected', 'egress_interface': 'unknown_os_selected',
    'listening': listening, 'returned': returned,
    'accepted': returned == packet.bytes.length, 'error': error,
  });

  DiscoveryReceipt receive(List<int> bytes, String sourceIp, int sourcePort,
      {Map<String, Object?> context = const {}}) {
    final hash = sha256.convert(bytes).toString();
    final key = '$sourceIp:$sourcePort:$hash';
    final duplicate = _seen.contains(key);
    _seen.remove(key);
    _seen.add(key);
    if (_seen.length > cacheLimit) _seen.remove(_seen.first);
    final receipt = DiscoveryReceipt(hash, sourceIp, sourcePort, bytes.length,
        _nowUs(), duplicate);
    receipt.metadata.addAll(context);
    event('rx', {..._receiptFields(receipt), 'stage': 'D'});
    return receipt;
  }

  /// An absent/bad/unknown extension must never reject an otherwise valid hello.
  void annotate(DiscoveryReceipt receipt, Map<String, dynamic>? body) {
    receipt.metadata['sender_device'] = body?['id'] is String
        ? discoveryShortHash(body!['id'] as String) : null;
    receipt.metadata['type'] = body?['type'] == 'hello' ? 'hello' : 'other_or_unknown';
    receipt.metadata['old_session'] = 'unknown_requires_sender_journal';
    if (body == null || !body.containsKey('_d4')) {
      receipt.metadata['diag'] = 'absent';
      receipt.metadata['complete'] = 'unknown_no_declared_length';
      return;
    }
    final d = body['_d4'];
    if (d is! Map<String, dynamic> || d['v'] != 1) {
      receipt.metadata['diag'] = 'invalid_or_unsupported';
      receipt.metadata['complete'] = 'unknown';
      return;
    }
    bool integer(Object? v) => v is int && v >= 0 && v <= 9007199254740991;
    if (d['s'] is! String || !RegExp(r'^[0-9a-f]{24}$').hasMatch(d['s'] as String) ||
        !integer(d['r']) || (d['r'] as int) < 1 || !integer(d['q']) ||
        (d['q'] as int) < 1 || !integer(d['u']) || !integer(d['n']) ||
        (d['n'] as int) > 65535) {
      receipt.metadata['diag'] = 'invalid_fields';
      receipt.metadata['complete'] = 'unknown';
      return;
    }
    receipt.metadata.addAll({
      'diag': 'v1', 'ps': d['s'], 'pr': d['r'], 'q': d['q'], 'pu': d['u'],
      'sender_session_matches_local': d['s'] == session,
      'declared_n': d['n'],
      'complete': d['n'] == receipt.length ? 'declared_length_matches' : 'declared_length_mismatch',
    });
    final association = '${receipt.sourceIp}:${receipt.sourcePort}:${d['s']}:${d['r']}:${d['q']}';
    final previous = _associations.remove(association);
    receipt.metadata['tuple_conflict'] = previous != null && previous != receipt.hash;
    _associations[association] = receipt.hash;
    if (_associations.length > cacheLimit) _associations.remove(_associations.keys.first);
    if (d['s'] == session && (d['r'] as int) < run) {
      receipt.metadata['old_session'] = 'declared_previous_local_run';
    }
  }

  Map<String, Object?> _receiptFields(DiscoveryReceipt r) => {
    'h': r.hash, 'src': r.sourceIp, 'sp': r.sourcePort, 'n': r.length,
    'rx_us': r.receivedUs, 'duplicate': r.duplicate, ...r.metadata,
  };

  void result(DiscoveryReceipt receipt, {required String reason,
    required bool protocolCompatible, required bool remoteHello,
    required String peerUpdate, String? error}) {
    _counts.update('reason:$reason', (n) => n + 1, ifAbsent: () => 1);
    event('rx_result', {..._receiptFields(receipt), 'stage': 'E/F/G',
      'reason': reason, 'protocol_compatible': protocolCompatible,
      'remote_hello': remoteHello, 'peer_update': peerUpdate, 'error': error,
      'identity': 'discovery_fields_only_not_signature',
    });
  }

  void awaitUi(String peerId, DiscoveryReceipt receipt) {
    if (!_uiRecorded.contains(peerId) && _pendingUi.length < 32) {
      _pendingUi[peerId] = receipt;
    }
  }

  void uiSnapshot(Set<String> peerIds) {
    for (final id in _pendingUi.keys.toList()) {
      final receipt = _pendingUi.remove(id)!;
      if (!peerIds.contains(id)) continue;
      _uiRecorded.add(id);
      event('ui_frame', {..._receiptFields(receipt), 'stage': 'G',
        'surface': 'owner_frame_peer_snapshot', 'visual_confirmation': 'not_observed',
      });
    }
  }
}

