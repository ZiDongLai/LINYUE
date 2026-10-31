/// E22-D1: bounded discovery warm-up; this does not grant pairing trust.
///
/// A freshly started peer may miss the other peer's very first UDP packet
/// while the Wi-Fi interface is waking or the OS socket is being registered.
/// A couple of early retransmissions improve the chance of first contact,
/// while the existing slower periodic announce remains the steady-state path.
class DiscoveryWarmupPolicy {
  DiscoveryWarmupPolicy._();

  static const warmupDelays = <Duration>[
    Duration(milliseconds: 350),
    Duration(milliseconds: 1400),
  ];

  static const replyCooldown = Duration(seconds: 12);
  static const maxReplySources = 32;
}

/// Limits best-effort responses to *valid* received LAN discovery packets.
/// It is deliberately not a trust/identity gate and must never authorize a
/// file transfer, signed pairing or text acknowledgement.
class DiscoveryReplyThrottle {
  DiscoveryReplyThrottle({
    this.cooldown = DiscoveryWarmupPolicy.replyCooldown,
    this.maxSources = DiscoveryWarmupPolicy.maxReplySources,
  }) : assert(maxSources > 0);

  final Duration cooldown;
  final int maxSources;
  final Map<String, DateTime> _lastReplyBySource = {};

  bool allow(String sourceIp, DateTime now) {
    if (sourceIp.isEmpty) return false;
    final previous = _lastReplyBySource[sourceIp];
    if (previous != null &&
        !now.isBefore(previous) &&
        now.difference(previous) < cooldown) {
      return false;
    }
    // Bounded memory, even when packets claim many bogus device identifiers.
    if (!_lastReplyBySource.containsKey(sourceIp) &&
        _lastReplyBySource.length >= maxSources) {
      _lastReplyBySource.remove(_lastReplyBySource.keys.first);
    }
    _lastReplyBySource.remove(sourceIp);
    _lastReplyBySource[sourceIp] = now;
    return true;
  }

  void clear() => _lastReplyBySource.clear();
}
