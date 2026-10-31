import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_controller.dart';
import 'bluetooth_connection_ui_test.dart' as ui;
import 'bluetooth_poc_test.dart' as b1;

void main() {
  Future<ui.Setup> setup({
    Duration serviceWait = const Duration(seconds: 18),
  }) async {
    final s = await ui.Setup.make(android: false, serviceWait: serviceWait);
    addTearDown(s.controller.dispose);
    return s;
  }

  test(
    'native pairing, peripheral and adapter failures retain distinct stages',
    () async {
      final s = await setup();
      for (final c in [
        ('Device is not OS-paired', '设备选择', '系统蓝牙设置'),
        ('Unsupported peripheral', '设备选择', '系统外设'),
        ('Bluetooth radio unavailable', '蓝牙适配器', '开启系统蓝牙'),
      ]) {
        await s.controller.prepare();
        s.native.probeError = c.$1;
        await s.controller.connectDevice('112233445566');
        expect(s.controller.phase, BluetoothConnectionPhase.failed);
        expect(s.controller.failedStage, c.$2);
        expect(s.controller.errorHint, contains(c.$3));
        expect(s.transport.starts, 0);
      }
    },
  );

  test(
    'first unassociated phone still requires real screen identity confirmation',
    () async {
      final s = await setup();
      await s.controller.prepare();
      await s.controller.connectDevice('112233445566');
      expect(s.native.serviceQueries, 1);
      expect(s.controller.phase, BluetoothConnectionPhase.chooseIdentity);
      expect(s.transport.starts, 0);
      await s.controller.confirmIdentity('0000');
      expect(s.transport.starts, 0);
      await s.controller.confirmIdentity(s.peer.local.fingerprint);
      expect(s.transport.starts, 1);
      expect(s.controller.authenticated, isFalse);
    },
  );

  test(
    'unknown type keyboard must fail target service check before identity',
    () async {
      final s = await setup();
      s.native.paired = [
        {'id': 'AABBCC7EAD91', 'name': 'Keyboard K380'},
      ];
      s.native.serviceOutcome = 'missing';
      await s.controller.prepare();
      await s.controller.connectDevice('AABBCC7EAD91');
      expect(s.native.serviceQueries, 1);
      expect(s.controller.phase, BluetoothConnectionPhase.failed);
      expect(s.controller.selectedFingerprint, isNull);
      expect(s.transport.starts, 0);
    },
  );

  test(
    'closing a service query twice cannot reopen or create a connection',
    () async {
      final s = await setup();
      await s.controller.prepare();
      s.native.serviceGate = Completer<void>();
      final pending = s.controller.connectDevice('112233445566');
      await Future<void>.delayed(Duration.zero);
      s.controller.leaveSheet();
      s.controller.leaveSheet();
      s.native.serviceGate!.complete();
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(s.transport.stops, 1);
      expect(s.transport.starts, 0);
      expect(s.controller.selectedDeviceId, isNull);
      expect(s.controller.phase, BluetoothConnectionPhase.cancelled);
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.chooseDevice);
    },
  );

  test('keyboard-only snapshot is not a handset or identity target', () async {
    final s = await setup();
    s.native.paired = [
      {'id': 'AABBCC7EAD91', 'name': 'Keyboard K380', 'kind': 'peripheral'},
    ];
    await s.controller.prepare();
    expect(s.controller.phase, BluetoothConnectionPhase.pairingRequired);
    expect(s.controller.devices, isEmpty);
    expect(s.controller.excludedPeripherals, 1);
    await s.controller.connectDevice('AABBCC7EAD91');
    expect(s.native.serviceQueries, 0);
    expect(s.transport.starts, 0);
  });
  test('name Android is not proof of phone or target UUID', () async {
    final s = await setup();
    s.native.paired = [
      {'id': '112233445566', 'name': 'Android Phone', 'kind': 'other'},
    ];
    s.native.serviceOutcome = 'missing';
    await s.controller.prepare();
    await ui.selectAndConfirm(s, '112233445566');
    expect(s.controller.phase, BluetoothConnectionPhase.failed);
    expect(s.controller.failedStage, '目标服务检查');
    expect(s.controller.errorHint, contains('邻跃蓝牙服务'));
    expect(s.transport.starts, 0);
    expect(s.native.nativeStops, 1);
  });
  test(
    'paired phone refresh allows selection only after service succeeds',
    () async {
      final s = await setup();
      s.native.paired = [];
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.pairingRequired);
      s.native.paired = [
        {'id': '112233445566', 'name': '真实手机', 'kind': 'phone'},
      ];
      await s.controller.prepare();
      await ui.selectAndConfirm(s, '112233445566');
      expect(s.native.serviceQueries, 1);
      expect(s.transport.starts, 1);
      expect(s.controller.authenticated, isFalse);
    },
  );
  test('same-name phones remain selectable by full OS identity', () async {
    final s = await setup();
    s.native.paired = [
      {'id': '112233445566', 'name': '手机'},
      {'id': 'AABBCCDDEEFF', 'name': '手机'},
    ];
    await s.controller.prepare();
    expect(s.controller.devices.length, 2);
    await ui.selectAndConfirm(s, 'AABBCCDDEEFF');
    expect(s.transport.device, 'AABBCCDDEEFF');
  });
  test(
    'query cancellation rejects late service success and clears selection',
    () async {
      final s = await setup();
      await s.controller.prepare();
      s.native.serviceGate = Completer<void>();
      final connecting = s.controller.connectDevice('112233445566');
      await Future<void>.delayed(Duration.zero);
      expect(s.controller.phase, BluetoothConnectionPhase.checkingService);
      await s.controller.stop();
      s.native.serviceGate!.complete();
      await connecting;
      expect(s.controller.phase, BluetoothConnectionPhase.cancelled);
      expect(s.controller.selectedDeviceId, isNull);
      expect(s.transport.starts, 0);
    },
  );
  test('duplicate taps cause one query and one connection', () async {
    final s = await setup();
    await s.controller.prepare();
    await Future.wait([
      s.controller.connectDevice('112233445566'),
      s.controller.connectDevice('112233445566'),
    ]);
    await s.controller.confirmIdentity(s.peer.local.fingerprint);
    expect(s.native.serviceQueries, 1);
    expect(s.transport.starts, 1);
  });
  test('service deadline fails closed and permits a clean retry', () async {
    final s = await setup(serviceWait: Duration.zero);
    await s.controller.prepare();
    s.native.serviceOutcome = 'checking';
    await ui.selectAndConfirm(s, '112233445566');
    expect(s.controller.errorHint, contains('超时'));
    expect(s.transport.starts, 0);
    await s.controller.backToDevices();
    s.native.serviceOutcome = 'ready';
    await ui.selectAndConfirm(s, '112233445566');
    expect(s.transport.starts, 1);
  });
  test(
    'service success is never app authentication; auth failure stays failed',
    () async {
      final s = await setup();
      await s.controller.prepare();
      await ui.selectAndConfirm(s, '112233445566');
      s.transport.emit('connected');
      expect(s.controller.phase, BluetoothConnectionPhase.authenticating);
      s.transport.emit('error', error: 'Identity signature rejected');
      expect(s.controller.authenticated, isFalse);
      expect(s.controller.failedStage, '身份认证');
      await s.controller.backToDevices();
      expect(s.controller.phase, BluetoothConnectionPhase.chooseDevice);
      expect(s.controller.devices.length, 1);
    },
  );
  test('authentication timeout is distinct and actionable', () async {
    final s = await setup();
    await s.controller.prepare();
    await ui.selectAndConfirm(s, '112233445566');
    s.transport.emit('error', error: 'Authentication timeout');
    expect(s.controller.errorHint, contains('身份验证超时'));
  });
  test('settings action delegates only on explicit call', () async {
    final s = await setup();
    await s.controller.prepare();
    expect(s.native.settingsRequests, 0);
    await s.controller.openBluetoothSettings();
    expect(s.native.settingsRequests, 1);
    expect(s.transport.starts, 0);
  });

  Future<void> open(WidgetTester t, ui.Setup s) async {
    await t.pumpWidget(ui.testHome(s));
    await t.tap(find.byKey(const Key('connect-device')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('bluetooth-connection-option')));
    await t.pumpAndSettle();
  }

  testWidgets(
    'return from system settings re-enumerates without restarting app',
    (t) async {
      final s = await setup();
      s.native.paired = [];
      await open(t, s);
      await t.ensureVisible(find.byKey(const Key('bluetooth-settings')));
      await t.tap(find.byKey(const Key('bluetooth-settings')));
      await t.pump();
      expect(s.native.settingsRequests, 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      s.native.paired = [
        {'id': '112233445566', 'name': '新配对手机', 'kind': 'phone'},
      ];
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('paired-112233445566')), findsOneWidget);
      expect(s.transport.starts, 0);
    },
  );

  testWidgets(
    'keyboard-only screen explains pairing, offers settings and refresh',
    (t) async {
      final s = await setup();
      s.native.paired = [
        {'id': 'AABBCC7EAD91', 'name': 'Keyboard K380', 'kind': 'peripheral'},
      ];
      await open(t, s);
      expect(find.textContaining('这里只显示已配对设备'), findsOneWidget);
      expect(find.byKey(const Key('bluetooth-settings')), findsOneWidget);
      expect(find.byKey(const ValueKey('paired-AABBCC7EAD91')), findsNothing);
      s.native.paired = [
        {'id': '112233445566', 'name': '我的手机', 'kind': 'phone'},
      ];
      await t.ensureVisible(find.byKey(const Key('bluetooth-refresh')));
      await t.tap(find.byKey(const Key('bluetooth-refresh')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('paired-112233445566')), findsOneWidget);
    },
  );
  testWidgets(
    'identity back preserves device list; close and reopen clear selection',
    (t) async {
      final s = await setup();
      await b1.trust(s.controller.identity, await b1.identity());
      await open(t, s);
      await t.ensureVisible(find.byKey(const ValueKey('paired-112233445566')));
      await t.tap(find.byKey(const ValueKey('paired-112233445566')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('bluetooth-identity-code')), findsOneWidget);
      await t.tap(find.byKey(const Key('bluetooth-back')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('paired-112233445566')), findsOneWidget);
      expect(s.controller.selectedDeviceId, isNull);
      await t.ensureVisible(find.byKey(const ValueKey('paired-112233445566')));
      await t.tap(find.byKey(const ValueKey('paired-112233445566')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('return-chat')));
      await t.pumpAndSettle();
      expect(find.text('原有聊天内容'), findsOneWidget);
      expect(s.controller.selectedDeviceId, isNull);
      await t.tap(find.byKey(const Key('connect-device')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('bluetooth-connection-option')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('paired-112233445566')), findsOneWidget);
      expect(s.native.serviceQueries, 2);
      expect(s.transport.starts, 0);
    },
  );
  test(
    'native source wiring uses uncached fixed UUID and system pairing guidance only',
    () {
      final cpp = File('windows/runner/bluetooth_poc.cpp').readAsStringSync();
      final kotlin = File(
        'android/app/src/main/kotlin/com/nearlink/nearlink/BluetoothPocBridge.kt',
      ).readAsStringSync();
      expect(cpp, contains('BluetoothCacheMode::Uncached'));
      expect(cpp, contains('RfcommServiceId::FromUuid(kService)'));
      expect(
        File('windows/runner/bluetooth_async_wait.h').readAsStringSync(),
        contains('operation.Cancel()'),
      );
      expect(cpp, contains('WaitForBluetoothOperation'));
      expect(cpp, contains('fIssueInquiry=FALSE'));
      expect(kotlin, contains('listenUsingRfcommWithServiceRecord'));
      expect(kotlin, contains('c7941b72-4eb5-4a42-a164-25b100004672'));
      expect(kotlin, contains('Settings.ACTION_BLUETOOTH_SETTINGS'));
    },
  );
}
