import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_controller.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_sheet.dart';
import 'package:nearlink/bluetooth/bluetooth_file_lane.dart';
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';
import 'package:nearlink/services/transfer_progress.dart';
import 'package:nearlink/ui/bluetooth_file_presentation.dart';
import 'package:nearlink/ui/workbench_composer.dart';
import 'bluetooth_connection_ui_test.dart' as workflow;
import 'bluetooth_poc_test.dart' as b1;

class HomeTransport extends workflow.WorkflowTransport {
  HomeTransport({
    required super.identity,
    required super.server,
    required super.native,
  }) : super(textEnabled: true);
  bool text = false, files = false;
  @override
  bool get textReady => authenticated && text;
  @override
  bool get fileSendReady => authenticated && files;
}

Future<
  ({
    BluetoothConnectionController c,
    HomeTransport t,
    workflow.WorkflowNative n,
    String fp,
  })
>
fixture({bool android = false}) async {
  final local = await b1.identity(), peer = await b1.identity();
  await b1.trust(local, peer);
  final n = workflow.WorkflowNative();
  final t = HomeTransport(identity: local, server: android, native: n);
  final c = BluetoothConnectionController(
    transport: t,
    refreshInterval: const Duration(milliseconds: 1),
  );
  addTearDown(c.dispose);
  return (c: c, t: t, n: n, fp: peer.local.fingerprint);
}

Widget surface(Widget child) => MaterialApp(
  theme: ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'E34PreviewCJK',
    scaffoldBackgroundColor: const Color(0xFF081721),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF74D9D2),
      secondary: Color(0xFF43C4BF),
      surface: Color(0xFF102732),
      onSurface: Color(0xFFE2EEEC),
    ),
  ),
  home: Scaffold(
    body: SafeArea(
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    ),
  ),
);

void main() {
  const renderPreview = bool.fromEnvironment('E34_RENDER_PREVIEW');
  setUpAll(() async {
    if (!renderPreview) return;
    for (final entry in {
      'E34PreviewCJK': 'C:/Windows/Fonts/msyh.ttc',
      'MaterialIcons':
          'D:/SDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (await file.exists()) {
        final loader = FontLoader(entry.key)
          ..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          );
        await loader.load();
      }
    }
  });

  test(
    'unique trusted paired endpoint resumes only through original service/auth gates',
    () async {
      final f = await fixture();
      await f.c.bindings.load();
      await f.c.bindings.remember('112233445566', f.fp);
      await f.c.prepare(resumeKnown: true);
      expect(f.n.serviceQueries, 1);
      expect(f.t.starts, 1);
      expect(f.t.expected, f.fp);
      expect(
        f.c.authenticated,
        isFalse,
      ); // Native start is not identity verification.
      expect(f.c.phase, BluetoothConnectionPhase.connecting);
    },
  );
  test(
    'unknown OS paired device never auto-trusted or auto-selected',
    () async {
      final f = await fixture();
      await f.c.prepare(resumeKnown: true);
      expect(f.c.phase, BluetoothConnectionPhase.chooseDevice);
      expect(f.t.starts, 0);
      expect(f.n.serviceQueries, 0);
    },
  );
  test('two trusted paired endpoints require user selection', () async {
    final f = await fixture();
    f.n.paired = [
      {'id': '112233445566', 'name': '同名'},
      {'id': 'AABBCCDDEEFF', 'name': '同名'},
    ];
    await f.c.bindings.load();
    await f.c.bindings.remember('112233445566', f.fp);
    await f.c.bindings.remember('AABBCCDDEEFF', f.fp);
    await f.c.prepare(resumeKnown: true);
    expect(f.c.phase, BluetoothConnectionPhase.chooseDevice);
    expect(f.t.starts, 0);
  });
  test(
    'trusted retry retains service failure rather than bypassing SDP',
    () async {
      final f = await fixture();
      await f.c.bindings.load();
      await f.c.bindings.remember('112233445566', f.fp);
      f.n.serviceOutcome = 'missing';
      await f.c.prepare(resumeKnown: true);
      expect(f.c.phase, BluetoothConnectionPhase.failed);
      expect(f.t.starts, 0);
      expect(f.c.failedStage, '目标服务检查');
    },
  );
  test('repeated resume clicks do not create parallel starts', () async {
    final f = await fixture();
    await f.c.bindings.load();
    await f.c.bindings.remember('112233445566', f.fp);
    await Future.wait([
      f.c.prepare(resumeKnown: true),
      f.c.prepare(resumeKnown: true),
    ]);
    expect(f.t.starts, 1);
    expect(f.n.serviceQueries, 1);
  });
  test(
    'resuming an existing waiting session does not stop or recreate it',
    () async {
      final f = await fixture(android: true);
      await f.c.prepare(resumeKnown: true);
      await f.c.prepare(resumeKnown: true);
      expect(f.t.starts, 1);
      expect(f.t.stops, 0);
      f.c.leaveSheet();
      expect(f.c.phase, BluetoothConnectionPhase.waiting);
    },
  );
  testWidgets('selected route alone determines the visible device/status', (
    tester,
  ) async {
    final f = await fixture();
    f.t.peerName = '已认证手机';
    f.t.peerFingerprint = f.fp;
    f.t.emit('connected', authenticated: true);
    await tester.pumpWidget(
      surface(
        DeviceConnectionBar(
          controller: f.c,
          onConnect: () {},
          lanLabel: 'LAN电脑',
          bluetoothSelected: false,
          onRouteChanged: (_) {},
          lanStatus: '待身份验证',
        ),
      ),
    );
    expect(find.text('LAN电脑'), findsOneWidget);
    expect(find.text('已认证手机'), findsNothing);
    expect(find.byKey(const Key('lan-header-status')), findsOneWidget);
    await tester.pumpWidget(
      surface(
        DeviceConnectionBar(
          controller: f.c,
          onConnect: () {},
          lanLabel: 'LAN电脑',
          bluetoothSelected: true,
          onRouteChanged: (_) {},
        ),
      ),
    );
    expect(find.text('已认证手机'), findsOneWidget);
    expect(find.text('LAN电脑'), findsNothing);
    expect(find.byKey(const Key('connect-device')), findsOneWidget);
  });
  testWidgets('text and file availability stay separate after authentication', (
    tester,
  ) async {
    final f = await fixture();
    f.t.peerFingerprint = f.fp;
    f.t.emit('connected', authenticated: true);
    await tester.pumpWidget(
      surface(
        DeviceConnectionBar(
          controller: f.c,
          onConnect: () {},
          lanLabel: 'LAN',
          bluetoothSelected: true,
        ),
      ),
    );
    expect(find.textContaining('文字通道准备中'), findsOneWidget);
    f.t.text = true;
    f.t.emit('connected', authenticated: true);
    await tester.pump();
    expect(find.textContaining('文件发送未就绪'), findsOneWidget);
    f.t.files = true;
    f.t.emit('connected', authenticated: true);
    await tester.pump();
    expect(find.textContaining('可发送文件≤1 MiB'), findsOneWidget);
  });
  testWidgets('route selection is explicit, locked during active work', (
    tester,
  ) async {
    final f = await fixture();
    var changed = 0;
    Widget bar(bool locked) => surface(
      DeviceConnectionBar(
        controller: f.c,
        onConnect: () {},
        lanLabel: 'LAN',
        onRouteChanged: (_) {
          changed++;
        },
        routeLocked: locked,
      ),
    );
    await tester.pumpWidget(bar(true));
    await tester.tap(find.text('蓝牙'));
    await tester.pump();
    expect(changed, 0);
    await tester.pumpWidget(bar(false));
    await tester.tap(find.text('蓝牙'));
    await tester.pump();
    expect(changed, 1);
    expect(
      f.t.starts,
      0,
    ); // The header does not initiate a second connection itself.
  });
  testWidgets(
    'compact connection flow skips the method chooser and return preserves waiting',
    (tester) async {
      final f = await fixture(android: true);
      await tester.pumpWidget(
        surface(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => DeviceConnectionSheet(
                  controller: f.c,
                  initialBluetooth: true,
                ),
              ),
              child: const Text('连接'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('连接'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(
        find.byKey(const Key('bluetooth-connection-option')),
        findsNothing,
      );
      expect(f.t.starts, 1);
      expect(find.text('等待电脑连接'), findsOneWidget);
      expect(find.textContaining('文件仍用局域网'), findsNothing);
      expect(find.byKey(const Key('return-chat')), findsOneWidget);
      await tester.tap(find.byKey(const Key('return-chat')));
      await tester.pumpAndSettle();
      expect(f.c.phase, BluetoothConnectionPhase.waiting);
      expect(f.t.stops, 0);
    },
  );
  testWidgets('release visibility keeps LAN and hides experimental controls', (
    tester,
  ) async {
    final f = await fixture();
    await tester.pumpWidget(
      surface(
        DeviceConnectionBar(
          controller: f.c,
          onConnect: () {},
          lanLabel: 'LAN',
          debugEnabled: false,
        ),
      ),
    );
    expect(find.byKey(const Key('connection-route')), findsNothing);
    expect(find.textContaining('蓝牙'), findsNothing);
    expect(find.byKey(const Key('connect-device')), findsOneWidget);
  });
  testWidgets('one composer keeps draft and callbacks while routes change', (
    tester,
  ) async {
    final draft = TextEditingController(), focus = FocusNode();
    addTearDown(draft.dispose);
    addTearDown(focus.dispose);
    var route = false, lan = 0, bt = 0, picks = 0;
    Widget input() => surface(
      WorkbenchComposer(
        draft: draft,
        focus: focus,
        canText: true,
        busy: false,
        mobile: true,
        onAddFile: () {
          picks++;
        },
        onSend: () {
          if (route) {
            bt++;
          } else {
            lan++;
          }
        },
      ),
    );
    await tester.pumpWidget(input());
    await tester.enterText(
      find.byKey(const Key('workbench-text-input')),
      '中文草稿',
    );
    await tester.tap(find.byKey(const Key('workbench-send-text')));
    expect(lan, 1);
    expect(bt, 0);
    route = true;
    await tester.pumpWidget(input());
    expect(draft.text, '中文草稿');
    await tester.tap(find.byKey(const Key('workbench-send-text')));
    expect(lan, 1);
    expect(bt, 1);
    await tester.tap(find.byKey(const Key('workbench-add-file')));
    expect(picks, 1);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const Key('workbench-add-file')), findsOneWidget);
  });
  testWidgets('disconnected and ACK-wait input cannot falsely send', (
    tester,
  ) async {
    final draft = TextEditingController(), focus = FocusNode();
    addTearDown(draft.dispose);
    addTearDown(focus.dispose);
    var sends = 0;
    for (final enabled in [false, true]) {
      await tester.pumpWidget(
        surface(
          WorkbenchComposer(
            draft: draft,
            focus: focus,
            canText: enabled,
            busy: enabled,
            mobile: true,
            onAddFile: null,
            onSend: () {
              sends++;
            },
          ),
        ),
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('workbench-send-text')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('workbench-add-file')))
            .onPressed,
        isNull,
      );
    }
    expect(sends, 0);
  });
  for (final phase in [
    '等待手机确认',
    '已获对端块确认 · 尚待整文件校验',
    '校验并保存',
    '成功 · 已校验并保存',
    '失败 · 未完成',
  ]) {
    test('BT progress projects without inventing success: $phase', () {
      final offer = BluetoothFileOffer(
        id: 'a' * 32,
        name: '文档.txt',
        size: 100,
        sha256: 'b' * 64,
      );
      final result = bluetoothFileProgressInfo(
        BluetoothFileProgress(offer, false, 100, phase),
      );
      expect(
        result.phase == TransferProgressPhase.completed,
        phase.startsWith('成功'),
      );
      expect(
        result.phase == TransferProgressPhase.failed,
        phase.startsWith('失败'),
      );
      expect(result.totalBytes, 100);
      expect(result.name, '文档.txt');
    });
  }
  test(
    'local cancellation stays failed for delivery but displays cancellation, never success',
    () {
      final offer = BluetoothFileOffer(
        id: 'a' * 32,
        name: 'x.txt',
        size: 10,
        sha256: 'b' * 64,
      );
      final cancelled = BluetoothFileProgress(
        offer,
        false,
        10,
        '失败 · 蓝牙断开，未确认完成',
        '用户断开',
      );
      expect(bluetoothFileWasCancelled(cancelled), isTrue);
      expect(
        bluetoothFileProgressInfo(cancelled).phase,
        TransferProgressPhase.failed,
      );
      expect(
        bluetoothFileWasCancelled(
          BluetoothFileProgress(offer, false, 10, '成功 · 已保存', '用户断开'),
        ),
        isFalse,
      );
    },
  );
  for (final width in [320.0, 390.0, 980.0, 1280.0]) {
    testWidgets(
      'shared workbench components fit ${width.toInt()}px and resize',
      (tester) async {
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = await fixture();
        f.t.peerFingerprint = f.fp;
        f.t.peerName = 'Mate 60 Pro · 很长的设备名称';
        f.t.text = true;
        f.t.files = true;
        f.t.emit('connected', authenticated: true);
        final draft = TextEditingController(), focus = FocusNode();
        addTearDown(draft.dispose);
        addTearDown(focus.dispose);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          surface(
            RepaintBoundary(
              key: boundary,
              child: ColoredBox(
                color: const Color(0xFF081721),
                child: Column(
                  children: [
                    DeviceConnectionBar(
                      controller: f.c,
                      onConnect: () {},
                      lanLabel: 'LAN',
                      bluetoothSelected: true,
                      onRouteChanged: (_) {},
                    ),
                    const Expanded(child: Center(child: Text('聊天与文件卡片区域'))),
                    WorkbenchComposer(
                      draft: draft,
                      focus: focus,
                      canText: true,
                      busy: false,
                      mobile: width < 980,
                      onAddFile: () {},
                      onSend: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (renderPreview) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final folder = await Directory(
              'audit/20261025_e34_ui_simplification/visuals',
            ).create(recursive: true);
            await File(
              '${folder.path}/components_${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        tester.view.physicalSize = Size(width == 320 ? 390 : 320, 760);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'real home uses one route/composer/live-card path; crypto and recovery stay outside UI',
    () {
      final s = File('lib/main.dart').readAsStringSync();
      final controls = s.substring(
        s.indexOf('  Widget _connectionControls()'),
        s.indexOf('  Future<void> _showConnectionMethods()'),
      );
      expect(controls.split('DeviceConnectionBar(').length - 1, 1);
      expect(controls, contains('onRouteChanged: _selectWorkbenchRoute'));
      expect(controls.contains('ChoiceChip'), isFalse);
      final timeline = s.substring(
        s.indexOf('  Widget _mixedConversationItems('),
        s.indexOf('  Future<void> _sendTextTrial('),
      );
      expect(timeline, contains('_conversationLiveBubble('));
      expect(timeline, contains('bluetoothFileProgressInfo(p)'));
      expect(timeline.contains('SelectableText(\'SHA-256'), isFalse);
      final picker = s.substring(
        s.indexOf('  Future<void> _addWorkbenchFile()'),
        s.indexOf('  Widget _unifiedTextComposer('),
      );
      expect(picker, contains('final bluetooth = _useBluetoothText;'));
      expect(picker, contains('_workbenchFilePickerOpen = true'));
      expect(
        picker.contains('catch'),
        isFalse,
      ); // No route fallback on failures.
    },
  );
}
