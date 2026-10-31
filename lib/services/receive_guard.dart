/// Incoming offer guard for the existing v0.1.x LAN test transport.
/// This is rate limiting, NOT authentication or encryption.
enum ReceiveDecision { prompt, paused, blocked }
enum ReceiveChoice { accept, decline, block }

class ReceiveGuard {
  ReceiveGuard({
    this.maxDeclines = 3,
    this.window = const Duration(minutes: 10),
    this.cooldown = const Duration(minutes: 10),
  });

  final int maxDeclines;
  final Duration window;
  final Duration cooldown;
  bool receivingEnabled = true;
  final Map<String, List<DateTime>> _declines = <String, List<DateTime>>{};
  final Map<String, DateTime> _blockedUntil = <String, DateTime>{};

  ReceiveDecision check(String sourceIp, {DateTime? at}) {
    final now = at ?? DateTime.now();
    _clean(now);
    if (!receivingEnabled) return ReceiveDecision.paused;
    final until = _blockedUntil[sourceIp];
    if (until != null && now.isBefore(until)) return ReceiveDecision.blocked;
    return ReceiveDecision.prompt;
  }

  void noteDecline(String sourceIp, {DateTime? at}) {
    final now = at ?? DateTime.now();
    _clean(now);
    final events = _declines.putIfAbsent(sourceIp, () => <DateTime>[]);
    events.add(now);
    if (events.length >= maxDeclines) block(sourceIp, at: now);
  }

  void noteAccepted(String sourceIp) {
    _declines.remove(sourceIp);
  }

  void block(String sourceIp, {DateTime? at}) {
    final now = at ?? DateTime.now();
    _blockedUntil[sourceIp] = now.add(cooldown);
    _declines.remove(sourceIp);
  }

  int get blockedCount {
    _clean(DateTime.now());
    return _blockedUntil.length;
  }

  void clearBlocks() {
    _blockedUntil.clear();
    _declines.clear();
  }

  void _clean(DateTime now) {
    _blockedUntil.removeWhere((_, until) => !now.isBefore(until));
    _declines.removeWhere((_, events) {
      events.removeWhere((event) => now.difference(event) >= window);
      return events.isEmpty;
    });
  }
}
