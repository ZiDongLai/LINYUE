import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/windows_mini_chat_session_coordinator.dart';
import 'package:nearlink/services/windows_mini_window_bridge.dart';
import 'package:nearlink/services/windows_mini_window_preferences.dart';

MiniChatOwnerSnapshot _verified({
  String peerId = 'android-peer-a',
  String fingerprint = 'sha256:trusted-identity-a',
  bool discovered = true,
  bool ready = true,
  bool enrolled = true,
  bool history = true,
  bool busy = false,
  int pending = 0,
}) => MiniChatOwnerSnapshot(
  peerId: peerId,
  peerLabel: 'Android · 已验证设备',
  authenticatedFingerprint: fingerprint,
  peerDiscovered: discovered,
  encryptedChannelReady: ready,
  identityEnrolled: enrolled,
  textHistoryAvailable: history,
  textSendBusy: busy,
  queuedFileCount: pending,
);

MiniWindowSnapshot _snapshot(String preset, {
  int x = 120,
  int y = 80,
  bool pinned = false,
}) {
  final sizes = <String, List<int>>{
    'small': <int>[370, 560],
    'medium': <int>[450, 680],
    'large': <int>[560, 780],
  };
  final size = sizes[preset]!;
  return MiniWindowSnapshot(
    x: x, y: y, width: size[0], height: size[1],
    pinned: pinned, preset: preset,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nearlink/mini_window');
  final messenger = TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('60 mini open/minimize/restore/close cycles never clear parent queue', () {
    final coordinator = WindowsMiniChatSessionCoordinator();
    coordinator.publishOwnerSnapshot(_verified(pending: 5));
    for (var cycle = 0; cycle < 60; cycle++) {
      expect(coordinator.open(isWindows: true), isTrue);
      final pending = coordinator.issueFileTicket();
      expect(pending, isNotNull);
      coordinator.minimize();
      expect(coordinator.validateFileTicket(pending), isFalse);
      expect(coordinator.issueTextTicket(), isNull);
      expect(coordinator.restore(isWindows: true), isTrue);
      expect(coordinator.validateFileTicket(pending), isFalse);
      expect(coordinator.issueFileTicket(), isNotNull);
      coordinator.close();
      expect(coordinator.issueFileTicket(), isNull);
      expect(coordinator.owner.queuedFileCount, 5);
      expect(coordinator.owner.hasAuthenticatedRecipient, isTrue);
    }
    coordinator.dispose();
  });

  test('connection loss and new cryptographic session revoke stale callbacks', () {
    final coordinator = WindowsMiniChatSessionCoordinator()
      ..open(isWindows: true);
    coordinator.publishOwnerSnapshot(_verified());
    final oldText = coordinator.issueTextTicket();
    final oldFile = coordinator.issueFileTicket();
    coordinator.publishOwnerSnapshot(_verified(ready: false));
    expect(coordinator.canSendText, isFalse);
    expect(coordinator.issueFileTicket(), isNull);
    expect(coordinator.validateTextTicket(oldText), isFalse);
    coordinator.publishOwnerSnapshot(_verified());
    expect(coordinator.validateTextTicket(oldText), isFalse);
    expect(coordinator.validateFileTicket(oldFile), isFalse);
    expect(coordinator.issueTextTicket(), isNotNull);
    coordinator.dispose();
  });

  test('same display peer ID but rotated authenticated key rejects old file', () {
    final coordinator = WindowsMiniChatSessionCoordinator()
      ..open(isWindows: true);
    coordinator.publishOwnerSnapshot(_verified());
    final pickedBeforeAsyncGap = coordinator.issueFileTicket();
    expect(pickedBeforeAsyncGap, isNotNull);
    coordinator.publishOwnerSnapshot(
      _verified(fingerprint: 'sha256:verified-new-key'),
    );
    expect(coordinator.validateFileTicket(pickedBeforeAsyncGap), isFalse);
    expect(coordinator.issueFileTicket(), isNotNull);
    coordinator.dispose();
  });

  test('changing active peer prevents asynchronous picker retarget', () {
    final coordinator = WindowsMiniChatSessionCoordinator()
      ..open(isWindows: true);
    coordinator.publishOwnerSnapshot(_verified());
    final oldTicket = coordinator.issueFileTicket();
    coordinator.publishOwnerSnapshot(_verified(
      peerId: 'android-peer-b',
      fingerprint: 'sha256:trusted-identity-b',
    ));
    expect(coordinator.validateFileTicket(oldTicket), isFalse);
    expect(coordinator.issueFileTicket(), isNotNull);
    coordinator.dispose();
  });

  test('discovery label or disconnected identity never authorizes mini send', () {
    final coordinator = WindowsMiniChatSessionCoordinator()
      ..open(isWindows: true);
    for (final owner in <MiniChatOwnerSnapshot>[
      _verified(discovered: false),
      _verified(ready: false),
      _verified(enrolled: false),
      const MiniChatOwnerSnapshot(
        peerId: 'untrusted', peerLabel: 'Android · 我的手机',
        authenticatedFingerprint: null, peerDiscovered: true,
        encryptedChannelReady: true, identityEnrolled: true,
        textHistoryAvailable: true,
      ),
    ]) {
      coordinator.publishOwnerSnapshot(owner);
      expect(coordinator.issueTextTicket(), isNull);
      expect(coordinator.issueFileTicket(), isNull);
    }
    coordinator.dispose();
  });

  test('history failure blocks text but does not delete queued files', () {
    final coordinator = WindowsMiniChatSessionCoordinator()
      ..open(isWindows: true);
    coordinator.publishOwnerSnapshot(_verified(pending: 3));
    final old = coordinator.issueTextTicket();
    coordinator.publishOwnerSnapshot(_verified(history: false, pending: 3));
    expect(coordinator.validateTextTicket(old), isFalse);
    expect(coordinator.issueTextTicket(), isNull);
    expect(coordinator.issueFileTicket(), isNotNull);
    expect(coordinator.owner.queuedFileCount, 3);
    coordinator.dispose();
  });

  test('file progress updates do not cause duplicate identity generations', () {
    final coordinator = WindowsMiniChatSessionCoordinator()
      ..open(isWindows: true);
    coordinator.publishOwnerSnapshot(_verified());
    final ticket = coordinator.issueFileTicket();
    final generation = coordinator.generation;
    for (var n = 0; n < 80; n++) {
      coordinator.publishOwnerSnapshot(_verified(pending: n % 7));
      expect(coordinator.validateFileTicket(ticket), isTrue);
    }
    expect(coordinator.generation, generation);
    coordinator.dispose();
  });

  test('all three sizes and pin directions reach a single HWND channel', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'setTopmost') {
        expect((call.arguments as Map)['enabled'], isA<bool>());
      }
      return true;
    });
    final bridge = WindowsMiniWindowBridge(channel: channel, isWindows: true);
    expect(await bridge.enterMini(saved: _snapshot('medium', pinned: true)), isTrue);
    for (final preset in <String>['small', 'medium', 'large']) {
      expect(await bridge.resizeMini(preset), isTrue);
    }
    expect(await bridge.setTopmost(true), isTrue);
    expect(await bridge.setTopmost(false), isTrue);
    expect(await bridge.restoreMain(), isTrue);
    expect(calls, <String>[
      'enterMini', 'resizeMini', 'resizeMini', 'resizeMini',
      'setTopmost', 'setTopmost', 'restoreMain',
    ]);
  });

  test('unsupported platform, invalid preset, and lost native plugin fail closed', () async {
    final mobile = WindowsMiniWindowBridge(channel: channel, isWindows: false);
    expect(await mobile.enterMini(), isFalse);
    expect(await mobile.restoreMain(), isFalse);
    final desktop = WindowsMiniWindowBridge(channel: channel, isWindows: true);
    expect(await desktop.resizeMini('unknown'), isFalse);
    expect(await desktop.enterMini(preset: 'unknown'), isFalse);
    // In a Dart test there is no Windows plugin registered.
    expect(await desktop.restoreMain(), isFalse);
    expect(await desktop.getSnapshot(), isNull);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'window-not-available');
    });
    expect(await desktop.enterMini(), isFalse);
    expect(await desktop.getSnapshot(), isNull);
  });

  test('native snapshot while minimized or in main mode is never persisted', () async {
    final bridge = WindowsMiniWindowBridge(channel: channel, isWindows: true);
    messenger.setMockMethodCallHandler(channel, (_) async => <String, Object>{
      'mini': true,
      'pinned': false,
      'preset': 'small',
      // Minimized HWND must omit its offscreen rectangle.
    });
    expect(await bridge.getSnapshot(), isNull);
    // Windows native excludes minimized HWND rectangles entirely, including
    // the offscreen iconic position. Assert its source-level guard below.
    messenger.setMockMethodCallHandler(channel, (_) async => <String, Object>{
      'mini': false, ..._snapshot('medium').toJson(),
    });
    expect(await bridge.getSnapshot(), isNull);
    final native = File('windows/runner/mini_chat_window_control.h')
        .readAsStringSync();
    expect(native, contains('!IsIconic(hwnd)'));
    expect(native, contains('MonitorFromRect(requested, MONITOR_DEFAULTTONEAREST)'));
    expect(native, contains('HWND_NOTOPMOST'));
  });

  test('window UI preferences persist across simulated process restarts', () async {
    final dir = await Directory.systemTemp.createTemp('linyue-e21c2-restarts-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    for (final preset in <String>['small', 'medium', 'large']) {
      final expected = MiniWindowPreference(
        preset: preset,
        saved: _snapshot(preset, x: -120, y: 150, pinned: true),
      );
      await MiniWindowPreferences(dir).save(expected);
      final restarted = await MiniWindowPreferences(dir).load();
      expect(restarted, expected);
      expect(restarted.pinned, isTrue);
    }
    final stored = await File('${dir.path}${Platform.pathSeparator}mini_window_v1.json')
        .readAsString();
    final json = jsonDecode(stored) as Map<String, dynamic>;
    expect(json.keys.toSet(), <String>{'version', 'preset', 'saved'});
    expect(stored, isNot(contains('android-peer-a')));
    expect(stored, isNot(contains('sha256:trusted-identity-a')));
  });

  test('corrupt current preferences recover from valid previous commit', () async {
    final dir = await Directory.systemTemp.createTemp('linyue-e21c2-corrupt-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final store = MiniWindowPreferences(dir);
    await store.save(MiniWindowPreference(
      preset: 'small', saved: _snapshot('small', pinned: true),
    ));
    await store.save(MiniWindowPreference(
      preset: 'large', saved: _snapshot('large'),
    ));
    await File('${dir.path}${Platform.pathSeparator}mini_window_v1.json')
        .writeAsString('not-json', flush: true);
    final recovered = await MiniWindowPreferences(dir).load();
    expect(recovered.preset, 'small');
    expect(recovered.pinned, isTrue);
  });

  test('oversized or foreign schema preferences never block startup', () async {
    final dir = await Directory.systemTemp.createTemp('linyue-e21c2-invalid-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File('${dir.path}${Platform.pathSeparator}mini_window_v1.json');
    final prefs = MiniWindowPreferences(dir);
    await file.writeAsString('a' * 5000, flush: true);
    expect((await prefs.load()).preset, 'medium');
    await file.writeAsString('{"version":999,"preset":"small"}', flush: true);
    expect((await prefs.load()).preset, 'medium');
    await file.writeAsString(
      '{"version":1,"preset":"large","saved":{"x":5,"y":5,'
      '"width":1,"height":1,"pinned":true,"preset":"large"}}',
      flush: true,
    );
    expect((await prefs.load()).saved, isNull);
    expect((await prefs.load()).preset, 'medium');
  });

  test('mini UI only uses original send pipeline and disposes window timer', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('WindowsMiniChatSessionCoordinator _miniCoordinator'));
    expect(main, contains('await _sendInlineText(peer)'));
    expect(main, contains('_queueFiles(peer, selected)'));
    expect(main, contains('_miniCoordinator.validateFileTicket(ticket)'));
    expect(main, contains('_miniPositionPoll?.cancel()'));
    expect(main, contains('_miniCoordinator.dispose()'));
    expect(main, contains('Timer.periodic(const Duration(seconds: 2)'));
    expect(main, contains('LinYueMiniWindow'));
  });
}
