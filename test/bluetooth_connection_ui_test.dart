import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_controller.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_sheet.dart';
import 'package:nearlink/bluetooth/bluetooth_transport.dart';
import 'package:nearlink/security/device_identity.dart';

// Share only the B1 in-memory vault fixture; no B1 tests or real sockets run here.
import 'bluetooth_poc_test.dart' as b1;

class WorkflowNative implements BluetoothNative {
  bool permission = true, radio = true, available = true;
  String radioState = 'on';
  bool grantOnRequest = false, statusFails = false;
  List<Map<String, dynamic>> discovered = [];
  int permissionRequests = 0;
  int serviceQueries = 0, settingsRequests = 0, nativeStops = 0;
  String serviceOutcome = 'ready';
  String? probeError;
  Completer<void>? serviceGate;
  List<Map<String, dynamic>> paired = [
    {'id': '112233445566', 'name': '测试手机'},
  ];
  Completer<void>? statusGate;
  @override
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? arguments]) async {
    Object? result;
    if (method == 'status') {
      await statusGate?.future;
      if (statusFails) throw StateError('native status unavailable');
      result = {
        'permission': permission,
        'radio': radio,
        'radioAvailable': available,
        'devices': paired,
      };
    }
    if (method == 'radioStatus') result = radioState;
    if (method == 'scanDevices') result = null;
    if (method == 'scanStatus') {
      result = {
        'scanning': false,
        'devices': [...paired, ...discovered],
      };
    }
    if (method == 'permission') {
      permissionRequests++;
      if (grantOnRequest) permission = true;
    }
    if (method == 'openSettings') settingsRequests++;
    if (method == 'stop') nativeStops++;
    if (method == 'probeService') {
      serviceQueries++;
      if (probeError != null) throw StateError(probeError!);
      result = 1;
    }
    if (method == 'probeStatus') {
      await serviceGate?.future;
      result = {'generation': 1, 'service': serviceOutcome};
    }
    return result as T?;
  }
}

/// This fake tests presentation state, not security or hardware. B1's real
/// cryptography/ACK tests still run separately and its source is unchanged.
class WorkflowTransport extends BluetoothTransport {
  WorkflowTransport({
    required super.identity,
    required super.server,
    required WorkflowNative super.native,
    super.textEnabled,
  });
  int starts = 0, stops = 0;
  bool verified = false, dead = false, failStart = false;
  String? expected, device;
  @override
  bool get authenticated => verified;
  @override
  Future<void> start({
    required String expectedFingerprint,
    String? deviceId,
    bool? serverRole,
  }) async {
    if (active) throw StateError('Already active');
    starts++;
    expected = expectedFingerprint;
    device = deviceId;
    if (failStart) {
      throw StateError('RFCOMM connect/service (Windows error 10060)');
    }
    server = serverRole ?? server;
    state = server ? 'listening' : 'connecting';
    lastError = '';
    notifyListeners();
  }

  void emit(String next, {bool authenticated = false, String error = ''}) {
    state = next;
    verified = authenticated;
    lastError = error;
    if (!dead) notifyListeners();
  }

  @override
  Future<void> disconnect({String? reason}) async {
    stops++;
    state = 'idle';
    verified = false;
    connectedDeviceId = null;
    lastError = reason ?? '';
    if (!dead) notifyListeners();
  }

  @override
  void dispose() {
    dead = true;
    super.dispose();
  }
}

class Setup {
  Setup(this.native, this.transport, this.controller, this.peer);
  final WorkflowNative native;
  final WorkflowTransport transport;
  final BluetoothConnectionController controller;
  final DeviceIdentityManager peer;
  static Future<Setup> make({
    bool android = true,
    bool registered = true,
    Duration serviceWait = const Duration(seconds: 18),
  }) async {
    final local = await b1.identity(), peer = await b1.identity();
    if (registered) await b1.trust(local, peer);
    final native = WorkflowNative();
    final transport = WorkflowTransport(
      identity: local,
      server: android,
      native: native,
    );
    final c = BluetoothConnectionController(
      transport: transport,
      permissionWait: const Duration(milliseconds: 12),
      refreshInterval: const Duration(milliseconds: 1),
      serviceWait: serviceWait,
    );
    return Setup(native, transport, c, peer);
  }
}

// Explicit current-screen confirmation, never inferred from an OS device name.
Future<void> selectAndConfirm(Setup s, String id) async {
  await s.controller.connectDevice(id);
  if (s.controller.phase == BluetoothConnectionPhase.chooseIdentity) {
    await s.controller.confirmIdentity(s.peer.local.fingerprint);
  }
}

Widget testHome(Setup s, {bool debug = true, VoidCallback? onLan}) {
  var bluetooth = false;
  return MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: StatefulBuilder(
      builder: (context, change) => Scaffold(
        body: Column(
          children: [
            DeviceConnectionBar(
              controller: s.controller,
              debugEnabled: debug,
              lanLabel: '局域网聊天 · 已有接收者',
              bluetoothSelected: bluetooth,
              onRouteChanged: (value) => change(() => bluetooth = value),
              onConnect: () async {
                final choice = await showDialog<String>(
                  context: context,
                  builder: (_) => DeviceConnectionSheet(
                    controller: s.controller,
                    debugEnabled: debug,
                    onBluetoothSelected: () => change(() => bluetooth = true),
                  ),
                );
                s.controller.leaveSheet();
                if (choice == 'lan') {
                  change(() => bluetooth = false);
                  onLan?.call();
                }
              },
            ),
            const Expanded(child: Text('原有聊天内容')),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('B2 workflow with existing transport boundary', () {
    Future<Setup> fixture({bool android = true, bool registered = true}) async {
      final s = await Setup.make(android: android, registered: registered);
      addTearDown(s.controller.dispose);
      return s;
    }

    test(
      'Android ready automatically waits; duplicate calls never start twice',
      () async {
        final s = await fixture();
        await Future.wait([s.controller.prepare(), s.controller.prepare()]);
        expect(s.transport.starts, 1);
        expect(s.controller.label, '等待电脑连接');
        expect(s.transport.expected, s.peer.local.fingerprint);
        await s.controller.prepare();
        expect(s.transport.starts, 1);
      },
    );
    test(
      'permission grant is observed before automatically starting',
      () async {
        final s = await fixture();
        s.native.permission = false;
        s.native.grantOnRequest = true;
        await s.controller.prepare(askPermission: true);
        expect(s.native.permissionRequests, 1);
        expect(s.transport.starts, 1);
      },
    );
    test('permission denied never starts or fabricates readiness', () async {
      final s = await fixture();
      s.native.permission = false;
      await s.controller.prepare(askPermission: true);
      expect(s.controller.phase, BluetoothConnectionPhase.permissionRequired);
      expect(s.transport.starts, 0);
    });
    test(
      'Bluetooth off is distinct from permission or pairing failure',
      () async {
        final s = await fixture();
        s.native.radio = false;
        await s.controller.prepare();
        expect(s.controller.phase, BluetoothConnectionPhase.radioOff);
        expect(s.transport.starts, 0);
      },
    );
    test('missing Windows adapter is distinct', () async {
      final s = await fixture(android: false);
      s.native.available = false;
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.unavailable);
    });
    test('no OS-paired device gives guidance, not a synthetic list', () async {
      final s = await fixture();
      s.native.paired = [];
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.pairingRequired);
      expect(s.controller.devices, isEmpty);
      expect(s.transport.starts, 0);
    });
    test('missing LINYUE trust is never replaced by OS pairing', () async {
      final s = await fixture(registered: false);
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.identityRequired);
      expect(s.transport.starts, 0);
    });
    test(
      'multiple registered identities require explicit choice, not name matching',
      () async {
        final s = await fixture();
        final other = await b1.identity();
        await b1.trust(s.controller.identity, other);
        await s.controller.prepare();
        expect(s.controller.phase, BluetoothConnectionPhase.chooseDevice);
        expect(s.transport.starts, 0);
        await s.controller.selectIdentity(other.local.fingerprint);
        expect(s.transport.expected, other.local.fingerprint);
        expect(s.transport.starts, 1);
      },
    );
    test(
      'Windows shows actual paired names/IDs, tapping a device connects once',
      () async {
        final s = await fixture(android: false);
        s.native.paired = [
          {'id': '112233445566', 'name': '同名手机'},
          {'id': 'AABBCCDDEEFF', 'name': '同名手机'},
        ];
        await s.controller.prepare();
        expect(s.controller.phase, BluetoothConnectionPhase.chooseDevice);
        expect(s.controller.devices.map((d) => d.id), [
          '112233445566',
          'AABBCCDDEEFF',
        ]);
        expect(s.transport.starts, 0);
        await Future.wait([
          s.controller.connectDevice('AABBCCDDEEFF'),
          s.controller.connectDevice('AABBCCDDEEFF'),
        ]);
        await s.controller.confirmIdentity(s.peer.local.fingerprint);
        expect(s.transport.device, 'AABBCCDDEEFF');
        expect(s.transport.starts, 1);
      },
    );
    test('unlisted Windows address cannot be selected', () async {
      final s = await fixture(android: false);
      await s.controller.prepare();
      await selectAndConfirm(s, 'not-listed');
      expect(s.transport.starts, 0);
    });
    test(
      'socket connected shows authenticating, never authenticated',
      () async {
        final s = await fixture();
        await s.controller.prepare();
        s.transport.emit('connected');
        expect(s.controller.phase, BluetoothConnectionPhase.authenticating);
        expect(s.controller.authenticated, isFalse);
        expect(s.controller.label, contains('正在验证'));
        s.transport.emit('connected', authenticated: true);
        expect(s.controller.phase, BluetoothConnectionPhase.authenticated);
      },
    );
    test('failed signature does not display connection success', () async {
      final s = await fixture();
      await s.controller.prepare();
      s.transport.emit(
        'error',
        error: 'Protocol rejected: Identity signature rejected',
      );
      expect(s.controller.phase, BluetoothConnectionPhase.failed);
      expect(s.controller.authenticated, isFalse);
      expect(s.controller.errorHint, contains('身份验证未通过'));
    });
    test('peer disconnection has distinct state and can retry', () async {
      final s = await fixture();
      await s.controller.prepare();
      s.transport.emit('error', error: 'Native disconnect: Peer disconnected');
      expect(s.controller.phase, BluetoothConnectionPhase.disconnected);
      await s.controller.prepare();
      expect(s.transport.starts, 2);
      expect(s.controller.phase, BluetoothConnectionPhase.waiting);
    });
    test('native service failure gives actionable hint and retry', () async {
      final s = await fixture(android: false);
      s.transport.failStart = true;
      await s.controller.prepare();
      await selectAndConfirm(s, '112233445566');
      expect(s.controller.phase, BluetoothConnectionPhase.failed);
      expect(s.controller.errorHint, contains('超时'));
      s.transport.failStart = false;
      await s.controller.prepare();
      await selectAndConfirm(s, '112233445566');
      expect(s.transport.starts, 2);
    });
    test('stop waiting releases native and says user cancelled', () async {
      final s = await fixture();
      await s.controller.prepare();
      await s.controller.stop();
      expect(s.controller.phase, BluetoothConnectionPhase.cancelled);
      expect(s.transport.active, isFalse);
      expect(s.transport.stops, 1);
    });
    test(
      'cancel preparation invalidates late permission/status completion',
      () async {
        final s = await fixture();
        s.native.statusGate = Completer<void>();
        final preparation = s.controller.prepare();
        await Future<void>.delayed(Duration.zero);
        await s.controller.stop();
        s.native.statusGate!.complete();
        await preparation;
        expect(s.transport.starts, 0);
        expect(s.controller.phase, BluetoothConnectionPhase.cancelled);
      },
    );
    test(
      'closing preparation cancels it, but returning from waiting preserves link',
      () async {
        final s = await fixture();
        s.native.statusGate = Completer<void>();
        final preparation = s.controller.prepare();
        s.controller.leaveSheet();
        s.native.statusGate!.complete();
        await preparation;
        expect(s.transport.starts, 0);
        s.native.statusGate = null;
        await s.controller.prepare();
        s.controller.leaveSheet();
        expect(s.controller.phase, BluetoothConnectionPhase.waiting);
        expect(s.transport.stops, 0);
      },
    );
    test('status failure is explicit, not pairing success', () async {
      final s = await fixture();
      s.native.statusFails = true;
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.failed);
      expect(s.transport.starts, 0);
    });
    test(
      'radio state unknown is retained as unknown rather than true',
      () async {
        final s = await fixture(android: false);
        s.native.radioState = 'unknown (denied)';
        await s.controller.prepare();
        expect(s.controller.radioDetail, contains('unknown'));
        expect(s.controller.phase, BluetoothConnectionPhase.chooseDevice);
      },
    );
  });

  group('B2 main header and compact sheet', () {
    testWidgets(
      'visible connection button opens distinct LAN and Bluetooth choices',
      (tester) async {
        final s = await Setup.make();
        addTearDown(s.controller.dispose);
        await tester.pumpWidget(testHome(s));
        expect(find.byKey(const Key('connect-device')), findsOneWidget);
        expect(find.text('蓝牙'), findsOneWidget);
        await tester.tap(find.byKey(const Key('connect-device')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('lan-connection-option')), findsOneWidget);
        expect(
          find.byKey(const Key('bluetooth-connection-option')),
          findsOneWidget,
        );
      },
    );
    testWidgets(
      'LAN choice invokes existing behavior, never starts Bluetooth',
      (tester) async {
        final s = await Setup.make();
        addTearDown(s.controller.dispose);
        var lan = 0;
        await tester.pumpWidget(
          testHome(
            s,
            onLan: () {
              lan++;
            },
          ),
        );
        await tester.tap(find.byKey(const Key('connect-device')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('lan-connection-option')));
        await tester.pumpAndSettle();
        expect(lan, 1);
        expect(s.transport.starts, 0);
      },
    );
    testWidgets(
      'Android automatically waits without UUID/role input and return keeps status',
      (tester) async {
        final s = await Setup.make();
        addTearDown(s.controller.dispose);
        await tester.pumpWidget(testHome(s));
        await tester.tap(find.byKey(const Key('connect-device')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bluetooth-connection-option')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(s.transport.starts, 1);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('bluetooth-sheet-status')))
              .data,
          '等待电脑连接',
        );
        expect(find.textContaining('UUID:'), findsNothing);
        expect(find.textContaining('服务端'), findsNothing);
        await tester.tap(find.byKey(const Key('return-chat')));
        await tester.pumpAndSettle();
        expect(s.controller.active, isTrue);
        expect(find.textContaining('等待电脑连接'), findsOneWidget);
        s.transport.emit('connected');
        await tester.pump();
        expect(find.textContaining('正在验证对端'), findsOneWidget);
        s.transport.emit('connected', authenticated: true);
        await tester.pump();
        expect(find.textContaining('蓝牙已连接 · 身份认证成功'), findsOneWidget);
        expect(find.textContaining('聊天和文件仍使用局域网'), findsNothing);
      },
    );
    testWidgets(
      'Windows first association needs confirmation then connects and can cancel',
      (tester) async {
        final s = await Setup.make(android: false);
        addTearDown(s.controller.dispose);
        await tester.pumpWidget(testHome(s));
        await tester.tap(find.byKey(const Key('connect-device')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bluetooth-connection-option')));
        await tester.pumpAndSettle();
        expect(find.text('测试手机 · 尾号 44:55:66'), findsOneWidget);
        expect(find.textContaining('系统已配对'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('paired-112233445566')));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(s.transport.starts, 0);
        await tester.enterText(
          find.byKey(const Key('bluetooth-identity-code')),
          s.peer.local.fingerprint,
        );
        await tester.ensureVisible(
          find.byKey(const Key('confirm-bluetooth-identity')),
        );
        await tester.tap(find.byKey(const Key('confirm-bluetooth-identity')));
        await tester.pump();
        expect(s.transport.starts, 1);
        expect(find.byKey(const Key('bluetooth-cancel')), findsOneWidget);
        await tester.tap(find.byKey(const Key('bluetooth-cancel')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const Key('bluetooth-sheet-status')))
              .data,
          '已取消蓝牙连接',
        );
      },
    );
    testWidgets(
      'release visibility policy hides Bluetooth diagnostics and keeps LAN',
      (tester) async {
        final s = await Setup.make();
        addTearDown(s.controller.dispose);
        await tester.pumpWidget(testHome(s, debug: false));
        expect(find.textContaining('蓝牙'), findsNothing);
        await tester.tap(find.byKey(const Key('connect-device')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('lan-connection-option')), findsOneWidget);
        expect(
          find.byKey(const Key('bluetooth-connection-option')),
          findsNothing,
        );
      },
    );
    testWidgets('narrow 320px layout and permission denial remain usable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final s = await Setup.make();
      s.native.permission = false;
      addTearDown(s.controller.dispose);
      await tester.pumpWidget(testHome(s));
      await tester.tap(find.byKey(const Key('connect-device')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bluetooth-connection-option')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('bluetooth-sheet-status')))
            .data,
        '蓝牙权限未授予',
      );
      expect(tester.takeException(), isNull);
    });
  });
  test(
    'real home wires both top bars and removes settings-only route; guards stay debug-only',
    () {
      final main = File('lib/main.dart').readAsStringSync();
      final desktop = main.substring(
        main.indexOf('  Widget _desktopNearbyPage()'),
        main.indexOf('  Widget _conversationHistory('),
      );
      final mobile = main.substring(
        main.indexOf('  Widget _mobileRecipientBar('),
        main.indexOf('  Widget _mobileChatTimeline('),
      );
      expect(desktop, contains('_connectionControls()'));
      expect(mobile, contains('_connectionControls()'));
      expect(main, contains('if (!_useBluetoothText) {'));
      expect(main, contains('await _showDeviceManager();'));
      expect(main, contains("result = await showDialog<String>("));
      expect(
        main,
        contains(
          'if (kDebugMode && (Platform.isAndroid || Platform.isWindows))',
        ),
      );
      expect(main, contains('_bluetoothConnection?.dispose()'));
      expect(main, isNot(contains('BluetoothDebugPage(')));
    },
  );
}
