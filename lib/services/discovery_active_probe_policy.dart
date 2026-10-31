import 'dart:convert';

/// Discovery-only metadata from an unsigned local /health endpoint.
/// NEVER treat this as a paired identity or permission to transfer.
class NetworkHealthCandidate {
  const NetworkHealthCandidate({required this.id, required this.name});
  final String id;
  final String name;
}

/// Only contacts the exact private IPv4 addresses already saved/seen by the
/// user. There is no subnet enumeration, scan or extra pairing shortcut.
class DiscoveryActiveProbePolicy {
  DiscoveryActiveProbePolicy._();

  static const int maxTargets = 8;

  static bool isPrivateLanIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final values = <int>[];
    for (final part in parts) {
      if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return false;
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

  static NetworkHealthCandidate? parseHealthResponse(String response,
      {required String ip, required String selfId}) {
    if (!isPrivateLanIp(ip) || response.length > 4096) return null;
    try {
      final value = jsonDecode(response);
      if (value is! Map<String, dynamic> ||
          value['protocol'] != 'nearlink/0.1') return null;
      final id = value['id'];
      // The current discovery service uses randomHex(12) for deviceId.
      if (id is! String || !RegExp(r'^[0-9a-f]{24}$').hasMatch(id) ||
          id == selfId) return null;
      final rawName = value['name'];
      final display = rawName is String
          ? rawName.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').trim()
          : '';
      final name = display.isEmpty ? '局域网设备 $ip'
          : display.substring(0, display.length > 60 ? 60 : display.length);
      return NetworkHealthCandidate(id: id, name: name);
    } catch (_) {
      return null;
    }
  }
}
