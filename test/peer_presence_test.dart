import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/peer_presence.dart';
import 'package:nearlink/services/nearlink_service.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17, 12);
  test('missing a few broadcasts does not immediately mark device offline', () {
    expect(peerRecentlySeen(now.subtract(const Duration(seconds: 15)), now), isTrue);
    expect(peerRecentlySeen(now.subtract(const Duration(seconds: 45)), now), isTrue);
    expect(peerRecentlySeen(now.subtract(const Duration(seconds: 46)), now), isFalse);
  });

  test('a stale discovered peer is retained for reconnection, then expires', () {
    expect(peerExpired(now.subtract(const Duration(seconds: 46)), now), isFalse);
    expect(peerExpired(now.subtract(const Duration(seconds: 120)), now), isFalse);
    expect(peerExpired(now.subtract(const Duration(seconds: 121)), now), isTrue);
  });

  test('manually added peer is treated separately from broadcast freshness', () {
    final p = NearPeer(id: 'manual:192.168.1.2', name: 'Manual', ip: '192.168.1.2',
        port: transferPort, seenAt: now.subtract(const Duration(days: 10)));
    expect(p.isManual, isTrue);
    expect(p.isStale, isFalse); // Not a proof that IP is online.
  });

  test('automatic peer reflects lack of recent signals', () {
    final p = NearPeer(id: 'peer-a', name: 'Phone', ip: '192.168.1.3',
        port: transferPort, seenAt: DateTime.now().subtract(const Duration(seconds: 60)));
    expect(p.isManual, isFalse);
    expect(p.isStale, isTrue);
  });
}
