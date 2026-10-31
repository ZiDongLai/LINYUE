import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/windows_mini_window_bridge.dart';
import 'package:nearlink/services/windows_mini_chat_session_coordinator.dart';

MiniChatOwnerSnapshot owner({
  String peerId = 'verified-android',
  String fingerprint = 'sha256:real-verified-identity',
  bool encrypted = true,
  bool history = true,
}) => MiniChatOwnerSnapshot(
  peerId: peerId,
  peerLabel: 'Android · 我的手机',
  authenticatedFingerprint: fingerprint,
  peerDiscovered: true,
  encryptedChannelReady: encrypted,
  identityEnrolled: true,
  textHistoryAvailable: history,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nearlink/mini_window');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('Android cannot invoke native Windows window commands', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return true;
    });
    final bridge = WindowsMiniWindowBridge(channel: channel, isWindows: false);
    expect(await bridge.enterMini(), isFalse);
    expect(await bridge.setTopmost(true), isFalse);
    expect(await bridge.restoreMain(), isFalse);
    expect(calls, 0);
  });

  test('native compact window and topmost have explicit ACKs', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (message) async {
      calls.add(message.method);
      if (message.method == 'setTopmost') {
        expect((message.arguments as Map)['enabled'], true);
      }
      return true;
    });
    final bridge = WindowsMiniWindowBridge(channel: channel, isWindows: true);
    expect(await bridge.enterMini(), isTrue);
    expect(await bridge.setTopmost(true), isTrue);
    expect(await bridge.restoreMain(), isTrue);
    expect(calls, ['enterMini', 'setTopmost', 'restoreMain']);
  });

  test('failure, no registration, or absent platform never imply success', () async {
    final bridge = WindowsMiniWindowBridge(channel: channel, isWindows: true);
    expect(await bridge.enterMini(), isFalse);
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    expect(await bridge.enterMini(), isFalse);
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'native_window_failed');
    });
    expect(await bridge.restoreMain(), isFalse);
  });

  test('mini mode cannot authorize sending before authenticated owner', () {
    final c = WindowsMiniChatSessionCoordinator();
    expect(c.open(isWindows: true), isTrue);
    expect(c.issueTextTicket(), isNull);
    c.publishOwnerSnapshot(owner(encrypted: false));
    expect(c.issueTextTicket(), isNull);
    c.publishOwnerSnapshot(owner(history: false));
    expect(c.issueTextTicket(), isNull);
    c.publishOwnerSnapshot(owner());
    expect(c.validateTextTicket(c.issueTextTicket()), isTrue);
    c.dispose();
  });

  test('switching device invalidates draft and picker tickets', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(owner());
    final oldText = c.issueTextTicket();
    final oldFile = c.issueFileTicket();
    c.publishOwnerSnapshot(owner(
      peerId: 'other-peer', fingerprint: 'sha256:other-verified-identity'));
    expect(c.validateTextTicket(oldText), isFalse);
    expect(c.validateFileTicket(oldFile), isFalse);
    c.dispose();
  });

  test('returning to full mode invalidates mini-sending permission', () {
    final c = WindowsMiniChatSessionCoordinator()..open(isWindows: true);
    c.publishOwnerSnapshot(owner());
    final ticket = c.issueTextTicket();
    expect(ticket, isNotNull);
    c.close();
    expect(c.validateTextTicket(ticket), isFalse);
    expect(c.issueTextTicket(), isNull);
    c.dispose();
  });
}
