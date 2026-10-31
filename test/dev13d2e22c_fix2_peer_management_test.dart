import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/nearlink_service.dart';
import 'package:nearlink/services/peer_management_policy.dart';

void main() {
  group('E22-C FIX2: remove list entries, never pairing grants', () {
    test('Manual address may be removed without network verification', () {
      expect(PeerManagementPolicy.canRemoveFromList(
          isManual: true, isStale: false, lastReconnectFailed: false), isTrue);
    });
    test('Healthy discovery cannot be discarded accidentally', () {
      expect(PeerManagementPolicy.canRemoveFromList(
          isManual: false, isStale: false, lastReconnectFailed: false), isFalse);
    });
    test('Stale discovered peer is removable', () {
      expect(PeerManagementPolicy.canRemoveFromList(
          isManual: false, isStale: true, lastReconnectFailed: false), isTrue);
    });
    test('Failed signed reconnect allows explicit list dismissal', () {
      expect(PeerManagementPolicy.canRemoveFromList(
          isManual: false, isStale: false, lastReconnectFailed: true), isTrue);
    });
    test('Manual address status does not say connected', () {
      expect(PeerManagementPolicy.displayStatus(
          isManual: true, isStale: false, lastReconnectFailed: false),
          contains('未证明在线'));
    });
    test('Discovered peer status does not say cryptographically paired', () {
      expect(PeerManagementPolicy.displayStatus(
          isManual: false, isStale: false, lastReconnectFailed: false),
          contains('仍需签名认证'));
    });
    test('Failed address explicitly exposes removal guidance', () {
      expect(PeerManagementPolicy.displayStatus(
          isManual: true, isStale: false, lastReconnectFailed: true),
          contains('重连失败'));
    });
    test('Removing manual peer is in-memory only, even without start()', () {
      final service = NearLinkService(deviceName: 'FIX2 Test', allowLegacyFileTransfer: false);
      service.addManualPeer('192.168.1.1');
      expect(service.peers.length, 1);
      expect(service.removeDisplayedPeer(
          peerId: 'manual:192.168.1.1', ip: '192.168.1.2'), isFalse);
      expect(service.peers.length, 1);
      expect(service.removeDisplayedPeer(
          peerId: 'manual:192.168.1.1', ip: '192.168.1.1'), isTrue);
      expect(service.peers, isEmpty);
      expect(service.removeDisplayedPeer(
          peerId: 'manual:192.168.1.1', ip: '192.168.1.1'), isFalse);
      service.dispose();
    });
    test('Peer removal never enables legacy plaintext transfer', () {
      final service = NearLinkService(deviceName: 'FIX2 Test', allowLegacyFileTransfer: false);
      service.addManualPeer('192.168.1.23');
      service.removeDisplayedPeer(peerId: 'manual:192.168.1.23', ip: '192.168.1.23');
      expect(service.allowLegacyFileTransfer, isFalse);
      service.dispose();
    });
  });
}
