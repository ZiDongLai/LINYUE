import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_controller.dart';
import 'package:nearlink/bluetooth/bluetooth_transport.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_sheet.dart';
import 'bluetooth_poc_test.dart' as b1;

class StartupNative implements BluetoothNative {
  final calls = <({String method, Map<String, dynamic>? args})>[];
  List<Map<String, dynamic>> devices = [
    {
      'id': 'AABBCC3CF797',
      'name': 'Mate 60 Pro',
      'paired': true,
      'kind': 'phone',
    },
  ];
  String radio = 'on', service = 'ready';
  bool adapter = true;
  String? adapterState;
  int adapterError = 0;
  String? connectError;
  Completer<void>? connectGate;
  Map<String, Object> diagnostics = {
    'platform': 'windows',
    'lastNativeCall': 'connect',
    'targetPresent': true,
    'targetValid': true,
    'targetPairedMatches': 1,
    'preflightStage': 'classic-adapter',
    'preflightError': 'RADIO_QUERY_FAILED Win32=5',
    'adapterWin32Error': 5,
  };
  int generation = 0;
  String state = 'idle';
  Completer<void>? probeGate;
  @override
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? args]) async {
    calls.add((method: method, args: args));
    Object? value;
    if (method == 'status') {
      value = {
        'permission': true,
        'radioAvailable': adapter,
        'devices': devices,
        'localName': 'LL',
        'radio': radio == 'on',
        if (adapterState != null) 'adapterState': adapterState,
        'adapterError': adapterError,
      };
    }
    if (method == 'diagnostics') value = diagnostics;
    if (method == 'radioStatus') value = radio;
    if (method == 'probeService') {
      generation++;
      value = generation;
    }
    if (method == 'probeStatus') {
      await probeGate?.future;
      value = {'generation': generation, 'service': service};
    }
    if (method == 'stop') {
      generation++;
      state = 'idle';
    }
    if (method == 'connect') {
      await connectGate?.future;
      if (connectError != null) {
        throw PlatformException(
          code: connectError!,
          message: 'Windows adapter query failed; Win32=5',
        );
      }
      if (args?['id'] == null) {
        throw PlatformException(
          code: 'BLUETOOTH_POC',
          message: 'Radio unavailable or device not OS-paired',
        );
      }
      generation++;
      state = 'connecting';
      value = generation;
    }
    if (method == 'start') {
      generation++;
      state = 'listening';
      value = generation;
    }
    if (method == 'poll') {
      value = {
        'generation': generation,
        'state': state,
        'bytes': Uint8List(0),
        'error': 'test peer disconnected',
      };
    }
    return value as T?;
  }
}

void main() {
  Future<
    ({
      StartupNative native,
      BluetoothTransport transport,
      BluetoothConnectionController controller,
    })
  >
  setup({
    bool server = false,
    Duration pollInterval = const Duration(days: 1),
  }) async {
    final identity = await b1.identity();
    final native = StartupNative();
    final transport = BluetoothTransport(
      identity: identity,
      server: server,
      native: native,
      textEnabled: true,
      pollInterval: pollInterval,
    );
    final controller = BluetoothConnectionController(
      transport: transport,
      refreshInterval: const Duration(milliseconds: 1),
    );
    addTearDown(controller.dispose);
    return (native: native, transport: transport, controller: controller);
  }

  test(
    'Windows E30 preparation only lists paired target and never starts with null ID',
    () async {
      final s = await setup();
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.chooseDevice);
      expect(s.controller.devices.single.name, 'Mate 60 Pro');
      expect(
        s.native.calls.where(
          (c) =>
              ['connect', 'start', 'stop', 'probeService'].contains(c.method),
        ),
        isEmpty,
      );
    },
  );
  test(
    'Android alone may start E30 waiting without a selected client target',
    () async {
      final s = await setup(
        server: true,
        pollInterval: const Duration(milliseconds: 1),
      );
      await s.controller.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(s.controller.phase, BluetoothConnectionPhase.waiting);
      expect(s.native.calls.where((c) => c.method == 'start').length, 1);
      expect(
        s.native.calls.where(
          (c) => c.method == 'connect' || c.method == 'probeService',
        ),
        isEmpty,
      );
    },
  );
  test('Windows known off blocks start before selection', () async {
    final s = await setup();
    s.native.radio = 'off';
    s.native.adapter = false;
    await s.controller.prepare();
    expect(s.controller.phase, BluetoothConnectionPhase.radioOff);
    expect(
      s.native.calls.where(
        (c) =>
            c.method == 'connect' || c.method == 'start' || c.method == 'stop',
      ),
      isEmpty,
    );
  });
  test('classic adapter missing is distinct from WinRT unknown', () async {
    final s = await setup();
    s.native.adapter = false;
    s.native.radio = 'unknown (no Bluetooth radio exposed)';
    await s.controller.prepare();
    expect(s.controller.phase, BluetoothConnectionPhase.unavailable);
    expect(s.native.calls.where((c) => c.method == 'connect'), isEmpty);
  });
  test(
    'WinRT unknown never becomes off and retains paired selection path',
    () async {
      final s = await setup();
      s.native.radio = 'unknown (Radio.State HRESULT 0x80070005)';
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.chooseDevice);
      expect(s.controller.radioDetail, contains('unknown'));
      expect(s.transport.nativeDiagnostics, contains('adapterWin32Error=5'));
    },
  );
  test('known disabled remains distinct from unknown', () async {
    final s = await setup();
    s.native.radio = 'disabled';
    await s.controller.prepare();
    expect(s.controller.phase, BluetoothConnectionPhase.unavailable);
    expect(s.native.calls.where((c) => c.method == 'connect'), isEmpty);
  });
  test(
    'adapter API access error is not labelled Bluetooth off or unpaired',
    () async {
      final s = await setup();
      s.native.adapterState = 'access-denied';
      s.native.adapterError = 5;
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.failed);
      expect(s.controller.failedStage, '蓝牙适配器查询');
      expect(s.controller.errorDetail, contains('Win32=5'));
      expect(
        s.native.calls.where(
          (c) => c.method == 'connect' || c.method == 'probeService',
        ),
        isEmpty,
      );
    },
  );
  test(
    'no OS-paired target gives pairing guidance without a connect',
    () async {
      final s = await setup();
      s.native.devices = [];
      await s.controller.prepare();
      expect(s.controller.phase, BluetoothConnectionPhase.pairingRequired);
      expect(s.native.calls.where((c) => c.method == 'connect'), isEmpty);
    },
  );
  test(
    'full selected address survives service query and reaches client connect',
    () async {
      final s = await setup();
      await s.controller.prepare();
      await s.controller.connectDevice('aa:bb:cc:3c:f7:97');
      final probe = s.native.calls.singleWhere(
        (c) => c.method == 'probeService',
      );
      final connect = s.native.calls.singleWhere((c) => c.method == 'connect');
      expect(probe.args?['id'], 'AABBCC3CF797');
      expect(connect.args?['id'], probe.args?['id']);
      expect(
        s.native.calls.indexOf(probe),
        lessThan(s.native.calls.indexOf(connect)),
      );
      expect(s.transport.authenticated, isFalse);
      expect(s.transport.textReady, isFalse);
    },
  );
  test(
    'failed target service check never falls through to native connect',
    () async {
      final s = await setup();
      await s.controller.prepare();
      s.native.service = 'missing';
      await s.controller.connectDevice('AABBCC3CF797');
      expect(s.controller.failedStage, '目标服务检查');
      expect(s.native.calls.where((c) => c.method == 'probeService').length, 1);
      expect(s.native.calls.where((c) => c.method == 'connect'), isEmpty);
      expect(s.transport.authenticated, isFalse);
    },
  );
  test('duplicate clicks start one query and one client attempt', () async {
    final s = await setup();
    await s.controller.prepare();
    await Future.wait([
      s.controller.connectDevice('AABBCC3CF797'),
      s.controller.connectDevice('AABBCC3CF797'),
    ]);
    expect(s.native.calls.where((c) => c.method == 'probeService').length, 1);
    expect(s.native.calls.where((c) => c.method == 'connect').length, 1);
  });
  test(
    'refresh replaces the snapshot and old target cannot be connected',
    () async {
      final s = await setup();
      await s.controller.prepare();
      s.controller.selectedDeviceId = 'AABBCC3CF797';
      s.native.devices = [
        {'id': '112233445566', 'name': '另一手机', 'paired': true, 'kind': 'phone'},
      ];
      await s.controller.prepare();
      expect(s.controller.selectedDeviceId, isNull);
      await s.controller.connectDevice('AABBCC3CF797');
      expect(s.native.calls.where((c) => c.method == 'connect'), isEmpty);
      await s.controller.connectDevice('112233445566');
      expect(
        s.native.calls.singleWhere((c) => c.method == 'connect').args?['id'],
        '112233445566',
      );
    },
  );
  test('cancelled service query cannot connect after late success', () async {
    final s = await setup();
    await s.controller.prepare();
    s.native.probeGate = Completer<void>();
    final query = s.controller.connectDevice('AABBCC3CF797');
    await Future<void>.delayed(Duration.zero);
    await s.controller.stop();
    s.native.probeGate!.complete();
    await query;
    expect(s.native.calls.where((c) => c.method == 'connect'), isEmpty);
    expect(s.controller.phase, BluetoothConnectionPhase.cancelled);
  });
  test(
    'cancel before queued transport start prevents native connect entirely',
    () async {
      final s = await setup();
      final start = s.transport.start(
        expectedFingerprint: '',
        deviceId: 'AABBCC3CF797',
      );
      final stop = s.transport.disconnect();
      await Future.wait([start, stop]);
      expect(s.native.calls.where((c) => c.method == 'connect'), isEmpty);
      expect(s.native.calls.where((c) => c.method == 'stop').length, 1);
    },
  );
  test('repeated disconnect requests share one cleanup operation', () async {
    final s = await setup();
    final first = s.transport.disconnect();
    final second = s.transport.disconnect();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(s.native.calls.where((c) => c.method == 'stop').length, 1);
  });
  test(
    'invalid direct client locators fail before native I/O or cleanup',
    () async {
      final s = await setup();
      for (final id in [null, '', 'Mate 60 Pro', '0bebbd a7', '000000000000']) {
        expect(
          () => s.transport.start(expectedFingerprint: '', deviceId: id),
          throwsStateError,
        );
      }
      expect(s.native.calls, isEmpty);
      expect(s.transport.active, isFalse);
    },
  );
  test(
    'native API failure snapshot survives cleanup with its exact stage',
    () async {
      final s = await setup();
      await s.controller.prepare();
      s.native.connectError = 'RADIO_QUERY_FAILED';
      await s.controller.connectDevice('AABBCC3CF797');
      expect(s.controller.phase, BluetoothConnectionPhase.failed);
      expect(s.controller.failedStage, '蓝牙适配器查询');
      expect(
        s.transport.nativeDiagnostics,
        contains('preflightStage=classic-adapter'),
      );
      expect(s.transport.nativeDiagnostics, contains('adapterWin32Error=5'));
      expect(s.transport.textReady, isFalse);
    },
  );
  test(
    'late native connect result after cancel is cleaned once and cannot change UI state',
    () async {
      final s = await setup();
      await s.controller.prepare();
      s.native.connectGate = Completer<void>();
      final connect = s.controller.connectDevice('AABBCC3CF797');
      while (!s.native.calls.any((c) => c.method == 'connect')) {
        await Future<void>.delayed(Duration.zero);
      }
      final stop = s.controller.stop();
      s.native.connectGate!.complete();
      await Future.wait([connect, stop]);
      expect(s.controller.phase, BluetoothConnectionPhase.cancelled);
      expect(s.transport.active, isFalse);
      expect(
        s.native.calls.where((c) => c.method == 'stop').length,
        2,
      ); // pre-start + explicit cancel, no recursive stop.
    },
  );
  testWidgets(
    'production Windows text-mode sheet lists Mate before any connect, then queries chosen target',
    (t) async {
      final s = await setup();
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('open'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      DeviceConnectionSheet(controller: s.controller),
                ),
                child: const Text('聊天'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const Key('open')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('bluetooth-connection-option')));
      await t.pumpAndSettle();
      expect(find.text('Mate 60 Pro · 尾号 3C:F7:97'), findsOneWidget);
      expect(s.native.calls.where((c) => c.method == 'connect'), isEmpty);
      await t.ensureVisible(find.byKey(const ValueKey('paired-AABBCC3CF797')));
      await t.tap(find.byKey(const ValueKey('paired-AABBCC3CF797')));
      await t.pump(const Duration(milliseconds: 100));
      expect(
        s.native.calls.singleWhere((c) => c.method == 'connect').args?['id'],
        'AABBCC3CF797',
      );
      expect(s.transport.authenticated, isFalse);
      await s.controller.stop();
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.byKey(const Key('return-chat')));
      await t.pumpAndSettle();
      final calls = s.native.calls.length;
      await t.tap(find.byKey(const Key('open')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('bluetooth-connection-option')));
      await t.pumpAndSettle();
      expect(
        s.native.calls
            .skip(calls)
            .where((c) => c.method == 'connect' || c.method == 'stop'),
        isEmpty,
      );
    },
  );
}
