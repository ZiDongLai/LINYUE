import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_controller.dart';
import 'package:nearlink/bluetooth/bluetooth_debug_page.dart';
import 'package:nearlink/bluetooth/bluetooth_native_diagnostics.dart';
import 'package:nearlink/bluetooth/bluetooth_protocol.dart';
import 'bluetooth_connection_ui_test.dart' as ui;
import 'bluetooth_poc_test.dart' as b1;

Map<String, Object> diagnostic({String platform = 'windows'}) => {
  'platform': platform,
  'serviceUuid': bluetoothServiceUuid,
  'nativeGeneration': 4,
  'phase': platform == 'android' ? 'listening' : 'idle',
  'queryMethod': 'GetRfcommServicesForIdAsync(Uncached)',
  'queryStage': 'target-service-query',
  'resultCount': 0,
  'hresult': '0x80000018',
  'events': ['150ms gen=4 query result=error'],
};

class DiagnosticNative extends ui.WorkflowNative {
  Map<String, Object> snapshot = diagnostic();
  String serviceError = '';
  bool diagnosticReadFails = false;
  @override
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? arguments]) async {
    if (method == 'diagnostics') {
      if (diagnosticReadFails) throw StateError('diagnostic read unavailable');
      return snapshot as T;
    }
    if (method == 'probeStatus') {
      return {
            'generation': 1,
            'service': serviceOutcome,
            'error': serviceError,
            'diagnostics': snapshot,
          }
          as T;
    }
    return super.invoke<T>(method, arguments);
  }
}

void main() {
  Future<
    ({
      DiagnosticNative native,
      ui.WorkflowTransport transport,
      BluetoothConnectionController controller,
    })
  >
  setup() async {
    final local = await b1.identity(), peer = await b1.identity();
    await b1.trust(local, peer);
    final native = DiagnosticNative();
    final transport = ui.WorkflowTransport(
      identity: local,
      server: false,
      native: native,
    );
    final controller = BluetoothConnectionController(
      transport: transport,
      refreshInterval: const Duration(milliseconds: 1),
    );
    addTearDown(controller.dispose);
    return (native: native, transport: transport, controller: controller);
  }

  test(
    'Android register/accept flags stay distinct from UI/authentication',
    () {
      final result = formatBluetoothNativeDiagnostics({
        ...diagnostic(platform: 'android'),
        'registrationReturned': true,
        'listenerOpen': true,
        'acceptEntered': true,
        'connected': false,
        'permission': true,
        'sdk': 31,
      });
      expect(result, contains('registrationReturned=true'));
      expect(result, contains('acceptEntered=true'));
      expect(result, contains('connected=false'));
      expect(result, isNot(contains('身份认证成功')));
    },
  );
  test('Windows query method/count/native HRESULT are retained', () {
    final result = formatBluetoothNativeDiagnostics(diagnostic());
    expect(result, contains('Uncached'));
    expect(result, contains('resultCount=0'));
    expect(result, contains('hresult=0x80000018'));
    expect(result, contains('target-service-query'));
  });
  test('UUID agreement only compares native with local protocol', () {
    expect(
      formatBluetoothNativeDiagnostics(diagnostic()),
      contains('双端是否同版仍需对照'),
    );
    expect(
      formatBluetoothNativeDiagnostics({'serviceUuid': 'wrong'}),
      contains('不一致'),
    );
  });
  test('unknown and sensitive map keys are never serialized', () {
    final result = formatBluetoothNativeDiagnostics({
      'privateKey': 'PRIVATE_SENTINEL',
      'token': 'TOKEN_SENTINEL',
      'bytes': 'FILE_SENTINEL',
      ...diagnostic(),
    });
    expect(result, isNot(contains('SENTINEL')));
  });
  test('event count and line lengths are bounded and controls removed', () {
    final result = formatBluetoothNativeDiagnostics({
      'events': List.generate(200, (i) => 'E$i ${'x' * 1000}\nINJECT\tEND'),
    });
    expect(result.split('\n').length, 81);
    expect(result, isNot(contains('E0 ')));
    expect(result, contains('E199 '));
    expect(result.split('\n').every((s) => s.length <= 321), isTrue);
  });
  test('absent and invalid diagnostic payloads are harmless', () {
    expect(formatBluetoothNativeDiagnostics(null), '');
    expect(formatBluetoothNativeDiagnostics('not a snapshot'), '');
    expect(
      formatBluetoothNativeDiagnostics({
        'events': [null, 7, {}],
      }).split('\n').length,
      1,
    );
  });
  test('diagnostic read never starts, stops or authorizes transport', () async {
    final s = await setup();
    await s.transport.refreshNativeDiagnostics();
    expect(s.transport.nativeDiagnostics, contains('0x80000018'));
    expect(s.transport.starts, 0);
    expect(s.transport.stops, 0);
    expect(s.transport.authenticated, isFalse);
  });
  test(
    'failed refresh preserves evidence and does not alter session state',
    () async {
      final s = await setup();
      await s.transport.refreshNativeDiagnostics();
      final previous = s.transport.nativeDiagnostics;
      s.native.diagnosticReadFails = true;
      await s.transport.refreshNativeDiagnostics();
      expect(s.transport.nativeDiagnostics, previous);
      expect(s.transport.lastError, '');
      expect(s.transport.starts, 0);
    },
  );
  test(
    'service error snapshot survives stop and never enters identity confirmation',
    () async {
      final s = await setup();
      s.native.serviceOutcome = 'error';
      s.native.serviceError =
          'Service discovery stage=target-service-query HRESULT=0x80000018';
      await s.controller.prepare();
      await s.controller.connectDevice('112233445566');
      expect(s.controller.phase, BluetoothConnectionPhase.failed);
      expect(s.controller.failedStage, '目标服务检查');
      expect(s.controller.errorDetail, contains('0x80000018'));
      expect(s.transport.nativeDiagnostics, contains('0x80000018'));
      expect(s.transport.starts, 0);
    },
  );
  test(
    'zero service result is not confused with authorization or connection',
    () async {
      final s = await setup();
      s.native.serviceOutcome = 'missing';
      await s.controller.prepare();
      await s.controller.connectDevice('112233445566');
      expect(s.controller.errorDetail, contains('not found in this query'));
      expect(s.transport.starts, 0);
      expect(s.controller.authenticated, isFalse);
    },
  );
  test(
    'diagnostic notification cannot restore an old failed phase during new query',
    () async {
      final s = await setup();
      s.transport.state = 'error';
      s.transport.lastError = 'previous identity failure';
      await s.controller.prepare();
      await s.controller.connectDevice('112233445566');
      expect(s.controller.phase, BluetoothConnectionPhase.chooseIdentity);
      expect(s.transport.starts, 0);
      expect(s.controller.authenticated, isFalse);
    },
  );
  for (final code in [
    'ConsentRequired',
    'ResourceInUse',
    'DeviceNotConnected',
  ]) {
    test('service $code keeps native cause and actionable hint', () async {
      final s = await setup();
      s.native.serviceOutcome = 'error';
      s.native.serviceError = 'Service discovery BluetoothError=$code';
      await s.controller.prepare();
      await s.controller.connectDevice('112233445566');
      expect(s.controller.errorDetail, contains(code));
      expect(s.controller.errorHint, isNot(contains('未能确认手机的邻跃蓝牙服务')));
      expect(s.transport.starts, 0);
    });
  }
  testWidgets(
    'panel refreshes and copies public native traces independently of business controls',
    (t) async {
      final s = await setup();
      String clipboard = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = call.arguments['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BluetoothDiagnostics(transport: s.transport),
            ),
          ),
        ),
      );
      await t.tap(
        find.byKey(const Key('refresh-native-bluetooth-diagnostics')),
      );
      await t.pumpAndSettle();
      expect(
        find.byKey(const Key('native-bluetooth-diagnostics')),
        findsOneWidget,
      );
      await t.tap(find.text('复制诊断'));
      await t.pumpAndSettle();
      expect(clipboard, contains('0x80000018'));
      expect(clipboard, contains(bluetoothServiceUuid));
      expect(s.transport.starts, 0);
    },
  );
  testWidgets('native diagnostic panel remains usable at 320px width', (
    t,
  ) async {
    final s = await setup();
    t.view.physicalSize = const Size(320, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    s.transport.captureNativeDiagnostics({
      ...diagnostic(platform: 'android'),
      'events': List.generate(
        80,
        (i) => '${i}ms gen=4 server.accept call entry',
      ),
    });
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BluetoothDiagnostics(transport: s.transport),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.byKey(const Key('refresh-native-bluetooth-diagnostics')),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });
  test(
    'production wait helper uses Status rather than reassigning Completed',
    () {
      final helper = File(
        'windows/runner/bluetooth_async_wait.h',
      ).readAsStringSync();
      expect(helper, contains('operation.Status()'));
      expect(helper, contains('operation.Cancel()'));
      expect(helper, isNot(contains('operation.wait_for(')));
      final cpp = File('windows/runner/bluetooth_poc.cpp').readAsStringSync();
      expect(
        cpp,
        contains('WaitForBluetoothOperation(operation,cancelled,deadline)'),
      );
      expect(cpp, contains('BluetoothCacheMode::Uncached'));
    },
  );
}
