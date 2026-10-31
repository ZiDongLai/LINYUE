import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/discovery_packet_diagnostics.dart';

void main() {
  const protocol = 'nearlink/0.1';
  final selfId = List<String>.filled(24, 'a').join();

  List<int> bytes(Object? value) => utf8.encode(value is String ? value : jsonEncode(value));

  DiscoveryPacketClassification classify(Object? value) =>
      DiscoveryPacketClassifier.classify(
        bytes(value),
        expectedProtocol: protocol,
        selfId: selfId,
      );

  group('E22-D4B3 UDP hello diagnostics', () {
    test('accepts only a protocol-valid hello with bounded ID length', () {
      final result = classify({
        'protocol': protocol,
        'type': 'hello',
        'id': List<String>.filled(24, 'b').join(),
        'name': 'Android · 我的手机',
        'port': 46729,
      });
      expect(result.kind, DiscoveryPacketKind.validHello);
      expect(result.isProtocolValidHello, isTrue);
      expect(result.body?['port'], 46729);
    });

    test('classifies malformed and non-object packets without throwing', () {
      final malformed = DiscoveryPacketClassifier.classify(
        utf8.encode('{not-json'),
        expectedProtocol: protocol,
        selfId: selfId,
      );
      expect(malformed.kind, DiscoveryPacketKind.malformedJson);
      expect(classify(['a', 'b', 'c']).kind,
          DiscoveryPacketKind.nonObjectJson);
    });

    test('separates protocol and message type mismatches', () {
      expect(classify({'protocol': 'other', 'type': 'hello'}).kind,
          DiscoveryPacketKind.protocolMismatch);
      expect(classify({'protocol': protocol, 'type': 'goodbye'}).kind,
          DiscoveryPacketKind.typeMismatch);
    });

    test('classifies self packets and malformed identity fields', () {
      expect(classify({
        'protocol': protocol,
        'type': 'hello',
        'id': selfId,
      }).kind, DiscoveryPacketKind.selfPacket);
      expect(classify({
        'protocol': protocol,
        'type': 'hello',
        'id': 123,
        'name': 'peer',
        'port': 46729,
      }).kind, DiscoveryPacketKind.invalidId);
      expect(classify({
        'protocol': protocol,
        'type': 'hello',
        'id': List<String>.filled(24, 'b').join(),
        'name': 123,
        'port': 46729,
      }).kind, DiscoveryPacketKind.invalidName);
      expect(classify({
        'protocol': protocol,
        'type': 'hello',
        'id': List<String>.filled(24, 'b').join(),
        'name': 'peer',
        'port': 70000,
      }).kind, DiscoveryPacketKind.invalidPort);
    });

    test('long IDs remain protocol-classified before the service length guard', () {
      final result = classify({
        'protocol': protocol,
        'type': 'hello',
        'id': List<String>.filled(129, 'b').join(),
        'name': 'peer',
        'port': 46729,
      });
      expect(result.kind, DiscoveryPacketKind.validHello);
      expect(result.isProtocolValidHello, isTrue);
      final source = File('lib/services/nearlink_service.dart').readAsStringSync();
      expect(source, contains('id.length > DiscoveryPacketClassifier.maxDeviceIdLength'));
      expect(source, contains('拒绝：设备 ID 超过 128 字符'));
    });

    test('service logs packet source and first valid hello with bounded samples', () {
      final source = File('lib/services/nearlink_service.dart').readAsStringSync();
      expect(source, contains("import 'discovery_packet_diagnostics.dart';"));
      expect(source, contains('DiscoveryPacketClassifier.classify('));
      expect(source, contains('_maxUdpDiagnosticSamples = 10'));
      expect(source, contains('D4B3 UDP 包诊断'));
      expect(source, contains('D4B3 首个协议有效 hello'));
      expect(source, contains('D4B3 hello 广播发送'));
      expect(source, contains('本地 send 返回'));
      expect(source, contains('D4B3 hello 单播响应'));
      expect(source, contains("_emitDiscoveryTrace('首次设备 UDP 广播')"));
      expect(source, contains('const Duration(seconds: 3)'));
      expect(source, isNot(contains('permissionToTransfer = true')));
    });
  });
}
