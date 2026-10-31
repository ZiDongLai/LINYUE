import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/windows_mini_window_bridge.dart';
import 'package:nearlink/services/windows_mini_window_preferences.dart';

const sample = MiniWindowSnapshot(
  x: -350, y: 70, width: 450, height: 680,
  pinned: true, preset: 'medium',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nearlink/mini_window');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('three window size presets and last geometry share one HWND', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'enterMini') {
        final args = call.arguments as Map;
        expect(args['preset'], 'medium');
        expect(args['x'], -350);
        expect(args['width'], 450);
      }
      if (call.method == 'resizeMini') {
        expect((call.arguments as Map)['preset'], 'small');
      }
      return true;
    });
    final bridge = WindowsMiniWindowBridge(channel: channel, isWindows: true);
    expect(await bridge.enterMini(saved: sample), isTrue);
    expect(await bridge.resizeMini('small'), isTrue);
    expect(await bridge.setTopmost(false), isTrue);
    expect(await bridge.restoreMain(), isTrue);
    expect(calls, ['enterMini', 'resizeMini', 'setTopmost', 'restoreMain']);
  });

  test('mismatched preset never passes an old rectangle to native', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      expect(args['preset'], 'large');
      expect(args.containsKey('x'), isFalse);
      return true;
    });
    final bridge = WindowsMiniWindowBridge(channel: channel, isWindows: true);
    expect(await bridge.enterMini(preset: 'large', saved: sample), isTrue);
  });

  test('unsupported size and Android reject native commands', () async {
    var called = 0;
    messenger.setMockMethodCallHandler(channel, (_) async { called++; return true; });
    final mobile = WindowsMiniWindowBridge(channel: channel, isWindows: false);
    expect(await mobile.enterMini(), isFalse);
    expect(await mobile.resizeMini('large'), isFalse);
    expect(await mobile.getSnapshot(), isNull);
    final desktop = WindowsMiniWindowBridge(channel: channel, isWindows: true);
    expect(await desktop.resizeMini('untrusted'), isFalse);
    expect(called, 0);
  });

  test('native state must explicitly confirm valid geometry and mode', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'mini': true, ...sample.toJson(),
    });
    final bridge = WindowsMiniWindowBridge(channel: channel, isWindows: true);
    expect(await bridge.getSnapshot(), sample);
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'mini': false, ...sample.toJson(),
    });
    expect(await bridge.getSnapshot(), isNull);
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'mini': true, 'x': 20, 'y': 20, 'width': 2,
      'height': 500, 'pinned': true, 'preset': 'medium',
    });
    expect(await bridge.getSnapshot(), isNull);
  });

  test('geometry preferences persist with chosen preset and pin', () async {
    final dir = await Directory.systemTemp.createTemp('linyue-mini-c1-');
    addTearDown(() async { if (await dir.exists()) await dir.delete(recursive: true); });
    final prefs = MiniWindowPreferences(dir);
    expect((await prefs.load()).preset, 'medium');
    final value = MiniWindowPreference(preset: 'medium', saved: sample);
    await prefs.save(value);
    final second = MiniWindowPreferences(dir);
    expect(await second.load(), value);
    expect((await second.load()).pinned, true);
  });

  test('invalid, oversized and corrupt preference files fail closed', () async {
    final dir = await Directory.systemTemp.createTemp('linyue-mini-bad-');
    addTearDown(() async { if (await dir.exists()) await dir.delete(recursive: true); });
    final file = File('${dir.path}${Platform.pathSeparator}mini_window_v1.json');
    await file.writeAsString('{ broken json');
    final prefs = MiniWindowPreferences(dir);
    expect((await prefs.load()).saved, isNull);
    await file.writeAsString('X' * 5000);
    expect((await prefs.load()).preset, 'medium');
    await file.writeAsString('{"version":1,"preset":"evil","saved":null}');
    expect((await prefs.load()).preset, 'medium');
  });

  test('backup can recover committed preference after an interrupted swap', () async {
    final dir = await Directory.systemTemp.createTemp('linyue-mini-backup-');
    addTearDown(() async { if (await dir.exists()) await dir.delete(recursive: true); });
    final prefs = MiniWindowPreferences(dir);
    await prefs.save(MiniWindowPreference(preset: 'medium', saved: sample));
    await prefs.save(const MiniWindowPreference(preset: 'small'));
    final current = File('${dir.path}${Platform.pathSeparator}mini_window_v1.json');
    await current.writeAsString('broken');
    final recovered = await prefs.load();
    expect(recovered.preset, 'medium');
    expect(recovered.saved, sample);
  });

  test('main window and auth context are not reinitialized by mini UI', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('WindowsMiniChatSessionCoordinator _miniCoordinator'));
    expect(main, contains('Future<void> _persistWindowsMiniPlacement()'));
    expect(main, contains('Timer.periodic(const Duration(seconds: 2)'));
    expect(main, contains('onSelected: _resizeWindowsMiniChat'));
    expect(main, contains('_miniCoordinator.close()'));
    final native = File('windows/runner/mini_chat_window_control.h').readAsStringSync();
    expect(native, contains('MonitorFromRect(requested, MONITOR_DEFAULTTONEAREST)'));
    expect(native, contains('HWND_NOTOPMOST'));
    expect(native, contains('getMiniState'));
  });
}
