import 'dart:convert';

/// D4-B3: classify discovery datagrams for diagnostics without changing trust.
/// The classifier never adds peers, authenticates identities, or authorizes
/// transfers. It only distinguishes why a UDP packet is or is not a hello.
enum DiscoveryPacketKind {
  malformedJson,
  nonObjectJson,
  protocolMismatch,
  typeMismatch,
  selfPacket,
  sameIdOtherAddress,
  invalidId,
  invalidName,
  invalidPort,
  validHello,
}

class DiscoveryPacketClassification {
  const DiscoveryPacketClassification(this.kind, {this.body});

  final DiscoveryPacketKind kind;
  final Map<String, dynamic>? body;

  /// Matches the existing service's trace timing: a hello with valid protocol
  /// fields counts as a hello before the separate 128-character ID guard.
  bool get isProtocolValidHello => kind == DiscoveryPacketKind.validHello;

  String get label => switch (kind) {
        DiscoveryPacketKind.malformedJson => '拒绝：JSON/UTF-8 解析失败',
        DiscoveryPacketKind.nonObjectJson => '拒绝：JSON 顶层不是对象',
        DiscoveryPacketKind.protocolMismatch => '拒绝：协议版本不匹配',
        DiscoveryPacketKind.typeMismatch => '拒绝：消息类型不是 hello',
        DiscoveryPacketKind.selfPacket => '忽略：设备 ID 与本机相同',
        DiscoveryPacketKind.sameIdOtherAddress =>
          '忽略：同 ID 来自非已知本机地址，疑似冲突（须核实网卡变化）',
        DiscoveryPacketKind.invalidId => '拒绝：设备 ID 不是字符串',
        DiscoveryPacketKind.invalidName => '拒绝：设备名称不是字符串',
        DiscoveryPacketKind.invalidPort => '拒绝：端口无效',
        DiscoveryPacketKind.validHello => '有效 hello',
      };
}

class DiscoveryPacketClassifier {
  DiscoveryPacketClassifier._();

  static const int maxDeviceIdLength = 128;

  static DiscoveryPacketClassification classify(
    List<int> datagram, {
    required String expectedProtocol,
    required String selfId,
    String? sourceIp,
    Set<String>? localAddresses,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(datagram));
    } catch (_) {
      return const DiscoveryPacketClassification(
        DiscoveryPacketKind.malformedJson,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return const DiscoveryPacketClassification(
        DiscoveryPacketKind.nonObjectJson,
      );
    }
    final body = decoded;
    if (body['protocol'] != expectedProtocol) {
      return DiscoveryPacketClassification(
        DiscoveryPacketKind.protocolMismatch,
        body: body,
      );
    }
    if (body['type'] != 'hello') {
      return DiscoveryPacketClassification(
        DiscoveryPacketKind.typeMismatch,
        body: body,
      );
    }
    if (body['id'] == selfId) {
      return DiscoveryPacketClassification(
        sourceIp != null && localAddresses != null &&
                !localAddresses.contains(sourceIp)
            ? DiscoveryPacketKind.sameIdOtherAddress
            : DiscoveryPacketKind.selfPacket,
        body: body,
      );
    }
    if (body['id'] is! String) {
      return DiscoveryPacketClassification(
        DiscoveryPacketKind.invalidId,
        body: body,
      );
    }
    if (body['name'] is! String) {
      return DiscoveryPacketClassification(
        DiscoveryPacketKind.invalidName,
        body: body,
      );
    }
    final rawPort = body['port'];
    if (rawPort is! int || rawPort < 1 || rawPort > 65535) {
      return DiscoveryPacketClassification(
        DiscoveryPacketKind.invalidPort,
        body: body,
      );
    }
    return DiscoveryPacketClassification(
      DiscoveryPacketKind.validHello,
      body: body,
    );
  }
}
