import 'dart:convert';

/// Discovery-only metadata from an unsigned local /health endpoint.
/// NEVER treat this as a paired identity or permission to transfer.
class NetworkHealthCandidate {
  const NetworkHealthCandidate({required this.id, required this.name});
  final String id;
  final String name;
}

class LanInterfaceSnapshot {
  const LanInterfaceSnapshot({
    required this.address,
    required this.prefixLength,
  });
  final String address;
  final int prefixLength;
}

/// Active probes are limited to private IPv4 addresses explicitly saved by
/// the user or hosts inside small, directly connected private LAN subnets.
/// Discovery results are only locators; they never grant trust or access.
class DiscoveryActiveProbePolicy {
  DiscoveryActiveProbePolicy._();

  static const int maxTargets = 8;
  static const int maxSubnetHosts = 1022;

  static bool isPrivateLanIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final values = <int>[];
    for (final part in parts) {
      if (part.isEmpty || (part.length > 1 && part.startsWith('0')))
        return false;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
      values.add(value);
    }
    if (values[3] == 0 || values[3] == 255) return false;
    return values[0] == 10 ||
        (values[0] == 172 && values[1] >= 16 && values[1] <= 31) ||
        (values[0] == 192 && values[1] == 168);
  }

  static List<String> unicastTargets(Iterable<String> peers) {
    final result = <String>[];
    final seen = <String>{};
    for (final raw in peers) {
      final ip = raw.trim();
      if (!isPrivateLanIp(ip) || !seen.add(ip)) continue;
      result.add(ip);
      if (result.length == maxTargets) break;
    }
    return result;
  }

  /// Expand only small RFC1918 interfaces for a bounded /health discovery
  /// pass. The limit is global across interfaces; wide networks are skipped.
  /// UDP and saved-IP discovery remain available there. This reveals app
  /// endpoints only, never trust.
  static List<String> subnetTargets(
    Iterable<LanInterfaceSnapshot> interfaces, {
    int maxHosts = maxSubnetHosts,
  }) {
    final targetLimit = maxHosts.clamp(0, maxSubnetHosts);
    if (targetLimit == 0) return const [];
    final targets = <String>[];
    final seen = <String>{};
    for (final interface in interfaces) {
      final local = _parseIpv4(interface.address);
      final prefix = interface.prefixLength;
      if (local == null || prefix < 20 || prefix > 30 || !_isRfc1918(local)) {
        continue;
      }
      final hostCount = (1 << (32 - prefix)) - 2;
      if (hostCount <= 0 || hostCount > maxHosts) continue;
      final mask = (0xffffffff << (32 - prefix)) & 0xffffffff;
      final network = local & mask;
      final broadcast = network | (~mask & 0xffffffff);
      for (var candidate = network + 1; candidate < broadcast; candidate++) {
        if (candidate == local || !seen.add(_formatIpv4(candidate))) continue;
        targets.add(_formatIpv4(candidate));
        if (targets.length >= targetLimit) return targets;
      }
    }
    return targets;
  }

  static int? _parseIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return null;
    var result = 0;
    for (final part in parts) {
      if (part.isEmpty || (part.length > 1 && part.startsWith('0')))
        return null;
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return null;
      result = (result << 8) | octet;
    }
    return result;
  }

  static bool _isRfc1918(int address) {
    final first = (address >> 24) & 0xff;
    final second = (address >> 16) & 0xff;
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }

  static String _formatIpv4(int address) =>
      '${(address >> 24) & 0xff}.${(address >> 16) & 0xff}.'
      '${(address >> 8) & 0xff}.${address & 0xff}';

  static NetworkHealthCandidate? parseHealthResponse(
    String response, {
    required String ip,
    required String selfId,
  }) {
    if (!isPrivateLanIp(ip) || response.length > 4096) return null;
    try {
      final value = jsonDecode(response);
      if (value is! Map<String, dynamic> || value['protocol'] != 'nearlink/0.1')
        return null;
      final id = value['id'];
      // The current discovery service uses randomHex(12) for deviceId.
      if (id is! String ||
          !RegExp(r'^[0-9a-f]{24}$').hasMatch(id) ||
          id == selfId)
        return null;
      final rawName = value['name'];
      final display = rawName is String
          ? rawName.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').trim()
          : '';
      final name = display.isEmpty
          ? '局域网设备 $ip'
          : display.substring(0, display.length > 60 ? 60 : display.length);
      return NetworkHealthCandidate(id: id, name: name);
    } catch (_) {
      return null;
    }
  }
}
