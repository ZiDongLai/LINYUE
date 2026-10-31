import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/windows_mini_chat_session_coordinator.dart';

MiniChatOwnerSnapshot verified({
  String peer = 'android-verified-id',
  String fingerprint = 'sha256:registered-fingerprint',
  bool discovered = true,
  bool secure = true,
  bool enrolled = true,
  bool history = true,
  bool busy = false,
  int queue = 0,
}) => MiniChatOwnerSnapshot(
      peerId: peer,
      peerLabel: 'Android · 我的手机',
      authenticatedFingerprint: fingerprint,
      peerDiscovered: discovered,
      encryptedChannelReady: secure,
      identityEnrolled: enrolled,
      textHistoryAvailable: history,
      textSendBusy: busy,
      queuedFileCount: queue,
    );

void main() {
  test('closed and disconnected by default, not a second connection', () {
    final coordinator = WindowsMiniChatSessionCoordinator();
    expect(coordinator.phase, MiniChatViewPhase.closed);
    expect(coordinator.owner.hasAuthenticatedRecipient, isFalse);
    expect(coordinator.issueTextTicket(), isNull);
    expect(coordinator.issueFileTicket(), isNull);
    coordinator.dispose();
  });

  test('mini mode is Windows-only', () {
    final c = WindowsMiniChatSessionCoordinator();
    expect(c.open(isWindows: false), isFalse);
    expect(c.phase, MiniChatViewPhase.closed);
    expect(c.open(isWindows: true), isTrue);
    expect(c.phase, MiniChatViewPhase.visible);
    c.dispose();
  });

  test('discovery name alone cannot authorize a send', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(const MiniChatOwnerSnapshot(
      peerId: 'discovered-peer', peerLabel: 'Android · 我的手机',
      authenticatedFingerprint: null, peerDiscovered: true,
      encryptedChannelReady: true, identityEnrolled: false,
      textHistoryAvailable: true,
    ));
    expect(c.owner.hasAuthenticatedRecipient, isFalse);
    expect(c.issueTextTicket(), isNull);
    expect(c.issueFileTicket(), isNull);
    c.dispose();
  });

  test('vault enrollment and ready authenticated channel both required', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(verified(enrolled: false));
    expect(c.issueFileTicket(), isNull);
    c.publishOwnerSnapshot(verified(secure: false));
    expect(c.issueFileTicket(), isNull);
    c.publishOwnerSnapshot(verified(discovered: false));
    expect(c.issueFileTicket(), isNull);
    c.publishOwnerSnapshot(verified(fingerprint: '  '));
    expect(c.issueFileTicket(), isNull);
    c.publishOwnerSnapshot(verified());
    expect(c.issueFileTicket(), isNotNull);
    c.dispose();
  });

  test('text requires healthy encrypted history, files do not', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(verified(history: false));
    expect(c.issueTextTicket(), isNull);
    expect(c.issueFileTicket(), isNotNull);
    c.dispose();
  });

  test('busy text guard never marks message sendable', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(verified(busy: true));
    expect(c.issueTextTicket(), isNull);
    expect(c.issueFileTicket(), isNotNull);
    c.dispose();
  });

  test('authenticated send tickets are current in an unchanged session', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(verified());
    final text = c.issueTextTicket();
    final file = c.issueFileTicket();
    expect(c.validateTextTicket(text), isTrue);
    expect(c.validateFileTicket(file), isTrue);
    c.publishOwnerSnapshot(verified(queue: 5));
    expect(c.validateTextTicket(text), isTrue);
    expect(c.owner.queuedFileCount, 5);
    c.dispose();
  });

  test('switching peer invalidates in-flight action tickets', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(verified());
    final old = c.issueTextTicket();
    c.publishOwnerSnapshot(verified(peer: 'another-peer',
        fingerprint: 'sha256:another-enrolled-identity'));
    expect(c.validateTextTicket(old), isFalse);
    expect(c.issueTextTicket(), isNotNull);
    c.dispose();
  });

  test('same discovery ID with a different fingerprint is a new identity', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(verified());
    final old = c.issueFileTicket();
    c.publishOwnerSnapshot(verified(fingerprint: 'sha256:changed-key'));
    expect(c.validateFileTicket(old), isFalse);
    c.dispose();
  });

  test('disconnect and reconnect invalidate pre-disconnect permission', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(verified());
    final old = c.issueTextTicket();
    c.publishOwnerSnapshot(verified(secure: false));
    expect(c.validateTextTicket(old), isFalse);
    c.publishOwnerSnapshot(verified());
    expect(c.validateTextTicket(old), isFalse);
    expect(c.issueTextTicket(), isNotNull);
    c.dispose();
  });

  test('mini panel minimize/restore does not mutate shared parent state', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    final source = verified(queue: 3);
    c.publishOwnerSnapshot(source);
    final old = c.issueFileTicket();
    c.minimize();
    expect(c.phase, MiniChatViewPhase.minimized);
    expect(c.issueFileTicket(), isNull);
    expect(c.owner, same(source));
    expect(c.restore(isWindows: true), isTrue);
    expect(c.validateFileTicket(old), isFalse);
    expect(c.issueFileTicket(), isNotNull);
    c.dispose();
  });

  test('closing panel does not clear identity or pending transfers', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(verified(queue: 6));
    final token = c.issueFileTicket();
    c.close();
    expect(c.phase, MiniChatViewPhase.closed);
    expect(c.owner.queuedFileCount, 6);
    expect(c.owner.hasAuthenticatedRecipient, isTrue);
    expect(c.validateFileTicket(token), isFalse);
    c.dispose();
  });

  test('changing text-history health invalidates pending send', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(verified());
    final token = c.issueTextTicket();
    c.publishOwnerSnapshot(verified(history: false));
    expect(c.validateTextTicket(token), isFalse);
    c.publishOwnerSnapshot(verified());
    expect(c.validateTextTicket(token), isFalse);
    c.dispose();
  });

  test('listeners receive view and parent updates but not artificial sends', () {
    final c = WindowsMiniChatSessionCoordinator();
    var updates = 0;
    c.addListener(() => updates++);
    c.open(isWindows: true);
    c.publishOwnerSnapshot(verified());
    c.minimize();
    c.restore(isWindows: true);
    c.close();
    expect(updates, 5);
    c.dispose();
  });
}
