import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_controller.dart';
import 'package:nearlink/bluetooth/bluetooth_association.dart';
import 'package:nearlink/bluetooth/bluetooth_protocol.dart';
import 'package:nearlink/bluetooth/bluetooth_transport.dart';
import 'package:nearlink/bluetooth/bluetooth_text_lane.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'package:nearlink/services/encrypted_text_history_runtime.dart';
import 'bluetooth_poc_test.dart' as b1;
import 'bluetooth_connection_ui_test.dart' as ui;

class PresentationTransport extends ui.WorkflowTransport {
  PresentationTransport({required super.identity, required super.native})
    : super(server: true, textEnabled: true);
  bool comparing = false, ready = false;
  int confirms = 0;
  @override
  bool get confirmationRequired => comparing;
  @override
  String get comparisonCode => 'ABCD 1234 EFFF';
  @override
  bool get textReady => ready && authenticated;
  @override
  Future<void> confirmAssociation(bool accepted) async {
    confirms++;
    comparing = false;
    if (!accepted) await disconnect(reason: 'User rejected comparison code');
    notifyListeners();
  }
}

class AssociationWire {
  late DeviceIdentityManager a, b;
  late BluetoothAssociation client, server;
  final queue = <({bool toServer, Map<String, dynamic> m})>[];
  final log = <({bool toServer, Map<String, dynamic> m})>[];
  int completed = 0;
  Future<void> init({
    bool trusted = false,
    String? pinned,
    Duration timeout = const Duration(seconds: 120),
    bool reuse = false,
  }) async {
    if (!reuse) {
      a = await b1.identity();
      b = await b1.identity();
    }
    if (trusted) {
      await b1.trust(a, b);
      await b1.trust(b, a);
    }
    Future<void> send(bool toServer, Uint8List bytes) async {
      final decoder = BluetoothFrameDecoder();
      // Exercise byte-by-byte length header and UTF-8 payload fragmentation.
      for (final byte in bytes) {
        for (final m in decoder.add([byte])) {
          final entry = (toServer: toServer, m: m);
          queue.add(entry);
          log.add(entry);
        }
      }
    }

    client = BluetoothAssociation(
      server: false,
      identity: a,
      localName: '电脑✓',
      expectedFingerprint: pinned,
      timeout: timeout,
      write: (b) => send(true, b),
      onState: (_) {},
      onComplete: (_, _) async {
        completed++;
      },
    );
    server = BluetoothAssociation(
      server: true,
      identity: b,
      localName: '手机✓',
      timeout: timeout,
      write: (b) => send(false, b),
      onState: (_) {},
      onComplete: (_, _) async {
        completed++;
      },
    );
    addTearDown(() => client.close());
    addTearDown(() => server.close());
    await server.start();
    await client.start();
  }

  Future<void> pump() async {
    var n = 0;
    while (queue.isNotEmpty) {
      if (n++ > 100) throw StateError('loop');
      final e = queue.removeAt(0);
      await (e.toServer ? server : client).receive(e.m);
    }
  }

  Future<void> associate() async {
    await pump();
    await client.confirm(true);
    await server.confirm(true);
    await pump();
  }
}

class DuplexNative implements BluetoothNative {
  DuplexNative? other;
  int generation = 0, starts = 0, stops = 0;
  String state = 'idle';
  final buffer = <int>[];
  bool drop = false;
  @override
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? args]) async {
    Object? value;
    if (method == 'stop') {
      stops++;
      generation++;
      state = 'idle';
      buffer.clear();
    }
    if (method == 'start') {
      starts++;
      generation++;
      state = 'listening';
      value = generation;
    }
    if (method == 'connect') {
      starts++;
      generation++;
      state = 'connected';
      other!.state = 'connected';
      value = generation;
    }
    if (method == 'write') {
      if (state != 'connected') throw StateError('Disconnected');
      if (!drop) other!.buffer.addAll(args!['bytes'] as List<int>);
    }
    if (method == 'poll') {
      final count = buffer.length.clamp(
        0,
        37,
      ); // Real stream splitting/concatenation.
      final bytes = Uint8List.fromList(buffer.take(count).toList());
      buffer.removeRange(0, count);
      value = {
        'generation': generation,
        'state': state,
        'bytes': bytes,
        'error': 'peer disconnected',
        'peerId': '112233445566',
      };
    }
    return value as T?;
  }
}

Future<void> until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 8)) {
      throw StateError('timeout waiting test');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  test(
    'simultaneous LAN/Bluetooth trust commits cannot discard a registration',
    () async {
      final local = await b1.identity(),
          a = await b1.identity(),
          b = await b1.identity();
      await Future.wait([b1.trust(local, a), b1.trust(local, b)]);
      final reloaded = DeviceIdentityManager(local.vault);
      await reloaded.initialize();
      expect(reloaded.entries.map((e) => e.fingerprint).toSet(), {
        a.local.fingerprint,
        b.local.fingerprint,
      });
      await Future.wait([
        local.revoke(a.local.fingerprint),
        local.revoke(b.local.fingerprint),
      ]);
      expect(local.entries, isEmpty);
    },
  );
  testWidgets(
    'unknown Android starts waiting without registry/code copy, then compares local SAS',
    (t) async {
      final local = await b1.identity(), peer = await b1.identity();
      final native = ui.WorkflowNative();
      final transport = PresentationTransport(identity: local, native: native);
      final c = BluetoothConnectionController(transport: transport);
      addTearDown(c.dispose);
      final s = ui.Setup(native, transport, c, peer);
      await t.pumpWidget(ui.testHome(s));
      await t.tap(find.byKey(const Key('connect-device')));
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.byKey(const Key('bluetooth-connection-option')));
      await t.pump(const Duration(milliseconds: 100));
      expect(transport.starts, 1);
      expect(local.entries, isEmpty);
      expect(c.label, '等待电脑连接');
      expect(find.byKey(const Key('bluetooth-identity-code')), findsNothing);
      expect(
        find.byKey(const Key('local-bluetooth-identity-code')),
        findsNothing,
      );
      transport.comparing = true;
      transport.emit('connected');
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('bluetooth-sas')), findsOneWidget);
      expect(find.text('ABCD 1234 EFFF'), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('bluetooth-sas-accept')));
      await t.tap(find.byKey(const Key('bluetooth-sas-accept')));
      await t.pump(const Duration(milliseconds: 100));
      expect(transport.confirms, 1);
      expect(transport.authenticated, isFalse);
      transport.emit('connected', authenticated: true);
      await t.pump(const Duration(milliseconds: 100));
      expect(transport.textReady, isFalse);
      transport.ready = true;
      transport.emit('connected', authenticated: true);
      await t.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('文字已可用'), findsOneWidget);
    },
  );
  test(
    'main chat wiring selects Bluetooth, gates E32 file capability, and has no fallback',
    () {
      final main = File(
        'lib/main.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final send = main.substring(
        main.indexOf('  Future<void> _sendBluetoothText()'),
        main.indexOf('  InAppPairingService? _pairing'),
      );
      expect(send, contains('textReady'));
      expect(send, contains('bluetooth: true'));
      expect(send, isNot(contains('peer.ip')));
      expect(main, contains('onRouteChanged: _selectWorkbenchRoute'));
      expect(
        main,
        contains('fileSendReady == true'),
      );
      expect(
        main,
        contains(
          'if (_useBluetoothText) {\n      final fp = _bluetoothConnection?.transport.peerFingerprint;',
        ),
      );
      expect(main, contains('_bluetoothUnconfirmed[fingerprint]'));
      expect(main, contains('await t.sendText(message);'));
    },
  );
  test(
    'unknown peers exchange keys in-band; equal SAS, two confirmations before trust',
    () async {
      final w = AssociationWire();
      await w.init();
      await w.pump();
      expect(w.client.comparisonCode, w.server.comparisonCode);
      expect(
        w.client.comparisonCode,
        matches(RegExp(r'^[0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4}$')),
      );
      expect(w.a.entries, isEmpty);
      expect(w.b.entries, isEmpty);
      await w.client.confirm(true);
      await w.pump();
      expect(w.a.entries, isEmpty);
      expect(w.b.entries, isEmpty);
      expect(w.completed, 0);
      await w.server.confirm(true);
      await w.pump();
      expect(w.completed, 2);
      expect(w.a.entries.single.fingerprint, w.b.local.fingerprint);
      expect(w.b.entries.single.fingerprint, w.a.local.fingerprint);
      expect(w.log.take(2).every((e) => e.m['t'] == 'commit'), isTrue);
    },
  );
  test(
    'known peers reconnect automatically with fresh signed association',
    () async {
      final w = AssociationWire();
      await w.init(trusted: true);
      await w.pump();
      expect(w.completed, 2);
      expect(w.client.needsConfirmation, isFalse);
    },
  );
  test('one-side trust still requires screen comparison on both', () async {
    final w = AssociationWire();
    await w.init();
    await b1.trust(w.a, w.b);
    await w.pump();
    expect(w.client.needsConfirmation, isTrue);
    expect(w.server.needsConfirmation, isTrue);
    expect(w.completed, 0);
  });
  test('rejection never registers unknown peer or completes', () async {
    final w = AssociationWire();
    await w.init();
    await w.pump();
    await w.client.confirm(false);
    await w.pump();
    expect(w.server.closed, isTrue);
    expect(w.a.entries, isEmpty);
    expect(w.b.entries, isEmpty);
    expect(w.completed, 0);
  });
  test('tampered reveal fails commitment', () async {
    final w = AssociationWire();
    await w.init();
    await w.server.receive(w.queue.removeAt(0).m);
    await w.client.receive(w.queue.removeAt(0).m);
    final m = w.queue.removeAt(0).m;
    final reveal = List<String>.from(m['r'] as List)..[1] = '伪造名称';
    await expectLater(w.server.receive({...m, 'r': reveal}), throwsA(anything));
    expect(w.b.entries, isEmpty);
  });
  test('wrong signature is rejected before comparison approval', () async {
    final w = AssociationWire();
    await w.init();
    while (w.queue.first.m['t'] != 'reveal-proof') {
      final e = w.queue.removeAt(0);
      await (e.toServer ? w.server : w.client).receive(e.m);
    }
    final e = w.queue.removeAt(0);
    await expectLater(
      w.client.receive({
        ...e.m,
        'sig': base64Url.encode(List.filled(64, 0)).replaceAll('=', ''),
      }),
      throwsA(anything),
    );
    expect(w.completed, 0);
    expect(w.a.entries, isEmpty);
  });
  test(
    'pinned OS endpoint cannot silently replace a trusted identity',
    () async {
      final wrong = await b1.identity();
      final w = AssociationWire();
      await w.init(pinned: wrong.local.fingerprint);
      await expectLater(w.pump(), throwsA(anything));
      expect(w.completed, 0);
    },
  );
  test('replayed prior approval cannot confirm a fresh handshake', () async {
    final w = AssociationWire();
    await w.init();
    await w.associate();
    final old = w.log.firstWhere((e) => e.toServer && e.m['t'] == 'approve').m;
    w.queue.clear();
    await w.init(
      reuse: true,
    ); // both now known, intercept before automatic approve
    while (w.queue.isNotEmpty) {
      final e = w.queue.removeAt(0);
      if (e.toServer && e.m['t'] == 'approve') {
        await expectLater(w.server.receive(old), throwsA(anything));
        return;
      }
      await (e.toServer ? w.server : w.client).receive(e.m);
    }
    fail('expected new approval');
  });
  test(
    'revocation during comparison does not re-enroll old known identity',
    () async {
      final w = AssociationWire();
      await w.init();
      await b1.trust(w.a, w.b);
      await w.pump();
      await w.a.revoke(w.b.local.fingerprint);
      await w.client.confirm(true);
      await w.server.confirm(true);
      await expectLater(w.pump(), throwsA(anything));
      expect(w.a.entries, isEmpty);
    },
  );
  test(
    'association timeout clears comparison and never grants trust',
    () async {
      final w = AssociationWire();
      await w.init(timeout: const Duration(milliseconds: 20));
      await w.pump();
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(w.client.closed, isTrue);
      expect(w.client.comparisonCode, '');
      expect(w.a.entries, isEmpty);
    },
  );
  test('legacy or unsupported association frames fail closed', () async {
    final w = AssociationWire();
    await w.init();
    await expectLater(
      w.server.receive({'t': 'hello', 'v': bluetoothProtocolDomain}),
      throwsA(anything),
    );
    expect(w.completed, 0);
  });

  test(
    'two independent substituted-identity sessions have different SAS and are not trusted',
    () async {
      final left = AssociationWire(), right = AssociationWire();
      await left.init();
      await right.init();
      await left.pump();
      await right.pump();
      expect(left.client.comparisonCode, isNot(right.server.comparisonCode));
      await left.client.confirm(false);
      await right.server.confirm(false);
      expect(left.a.entries, isEmpty);
      expect(right.b.entries, isEmpty);
    },
  );
  test(
    'claimed trust mode cannot be altered without invalidating signature',
    () async {
      final w = AssociationWire();
      await w.init();
      while (w.queue.first.m['t'] != 'reveal-proof') {
        final e = w.queue.removeAt(0);
        await (e.toServer ? w.server : w.client).receive(e.m);
      }
      final e = w.queue.removeAt(0);
      await expectLater(
        w.client.receive({...e.m, 'known': true}),
        throwsA(anything),
      );
      expect(w.a.entries, isEmpty);
      expect(w.completed, 0);
    },
  );
  group('authenticated fragmented Bluetooth text lane', () {
    late BluetoothTextLane a, b;
    late List<({bool toB, Map<String, dynamic> m})> q;
    late List<TextChatMessage> received;
    late List<String> failures;
    Future<void> pump() async {
      for (var i = 0; i < 6 || q.isNotEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
        while (q.isNotEmpty) {
          final e = q.removeAt(0);
          await (e.toB ? b : a).receive(e.m);
        }
      }
    }

    setUp(() async {
      q = [];
      received = [];
      failures = [];
      a = BluetoothTextLane(
        seal: (m) async {
          q.add((toB: true, m: m));
        },
        onText: (m) async {
          received.add(m);
        },
        onReady: () {},
        onFailure: failures.add,
        ackTimeout: const Duration(milliseconds: 120),
      );
      b = BluetoothTextLane(
        seal: (m) async {
          q.add((toB: false, m: m));
        },
        onText: (m) async {
          received.add(m);
        },
        onReady: () {},
        onFailure: failures.add,
        ackTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(a.close);
      addTearDown(b.close);
      await a.start();
      await b.start();
      await pump();
    });
    for (final text in ['你好，邻跃 ✓\n中文标点！', '文' * 2700, 'A${'\n' * 8191}']) {
      test(
        'UTF8/long/escaped text ${text.length} chars with matching ACK',
        () async {
          final msg = TextChatMessage.create(text);
          final send = a.send(msg);
          await pump();
          await send;
          expect(received.single.body, text);
          expect(failures, isEmpty);
        },
      );
    }
    test(
      'duplicate ID is ACKed idempotently without duplicate display',
      () async {
        final m = TextChatMessage.create('重复');
        var send = a.send(m);
        await pump();
        await send;
        send = a.send(m);
        await pump();
        await send;
        expect(received.length, 1);
      },
    );
    test('same ID with changed content is rejected', () async {
      final m = TextChatMessage.create('原文');
      var send = a.send(m);
      await pump();
      await send;
      send = a.send(
        TextChatMessage(id: m.id, createdAt: m.createdAt, body: '被修改'),
      );
      unawaited(send.catchError((Object _) {}));
      await expectLater(pump(), throwsA(anything));
      a.close();
      await expectLater(send, throwsA(anything));
      expect(received.length, 1);
    });
    test('missing ACK times out and cannot be shown as sent', () async {
      final send = a.send(TextChatMessage.create('丢失确认'));
      await expectLater(send, throwsA(isA<TimeoutException>()));
      expect(failures.single, contains('unconfirmed'));
    });
    test('disconnect fails outstanding send', () async {
      final send = a.send(TextChatMessage.create('断开'));
      unawaited(send.catchError((Object _) {}));
      a.close();
      await expectLater(send, throwsA(anything));
      expect(a.ready, isFalse);
    });
    test('invalid and oversized body rejected before transmission', () async {
      expect(() => TextChatMessage.create('x' * 8193), throwsFormatException);
      expect(() => TextChatMessage.create('a\u0000'), throwsFormatException);
      expect(q, isEmpty);
    });
    test(
      'fragment out of order and huge count rejected without allocating',
      () async {
        await expectLater(
          b.receive({
            'k': 'text-part',
            'id': 'a' * 32,
            'i': 0,
            'count': 100000,
            'd': 'WA',
          }),
          throwsA(anything),
        );
        await expectLater(
          b.receive({
            'k': 'text-part',
            'id': 'a' * 32,
            'i': 1,
            'count': 2,
            'd': 'WA',
          }),
          throwsA(anything),
        );
      },
    );
    test('readiness is distinct from authenticated transport', () async {
      final pending = BluetoothTextLane(
        seal: (_) async {},
        onText: (_) async {},
        onReady: () {},
        onFailure: (_) {},
      );
      addTearDown(pending.close);
      expect(pending.ready, isFalse);
      await expectLater(
        pending.send(TextChatMessage.create('尚未协商')),
        throwsA(anything),
      );
    });
    test(
      'forged encrypted ACK content cannot mark delivery confirmed',
      () async {
        final message = TextChatMessage.create('确认绑定');
        final send = a.send(message);
        unawaited(send.catchError((Object _) {}));
        await Future<void>.delayed(Duration.zero);
        await expectLater(
          a.receive({
            'k': 'text-ack',
            'id': message.id,
            'sha': '0' * 64,
            'size': 4,
          }),
          throwsA(anything),
        );
        a.close();
        await expectLater(send, throwsA(anything));
      },
    );
    test(
      'incomplete message deadline reports failure and never displays',
      () async {
        await b.receive({
          'k': 'text-part',
          'id': 'a' * 32,
          'i': 0,
          'count': 2,
          'd': 'WA',
        });
        await Future<void>.delayed(const Duration(milliseconds: 140));
        expect(failures, contains('Incomplete Bluetooth text message timeout'));
        expect(received, isEmpty);
      },
    );
    test('disk failure prevents ACK', () async {
      b.close();
      b = BluetoothTextLane(
        seal: (m) async {
          q.add((toB: false, m: m));
        },
        onText: (_) async {
          throw FileSystemException('disk full');
        },
        onReady: () {},
        onFailure: failures.add,
      );
      await b.start();
      a.close();
      a = BluetoothTextLane(
        seal: (m) async {
          q.add((toB: true, m: m));
        },
        onText: (_) async {},
        onReady: () {},
        onFailure: failures.add,
      );
      await a.start();
      await pump();
      final send = a.send(TextChatMessage.create('不能落盘'));
      unawaited(send.catchError((Object _) {}));
      await expectLater(pump(), throwsA(isA<FileSystemException>()));
      expect(q.where((e) => e.m['k'] == 'text-ack'), isEmpty);
      a.close();
      await expectLater(send, throwsA(anything));
    });
  });

  test(
    'real secure transports perform association, B1 auth, capabilities and durable bidirectional text over native byte stream',
    () async {
      final ia = await b1.identity(), ib = await b1.identity();
      final na = DuplexNative(), nb = DuplexNative();
      na.other = nb;
      nb.other = na;
      final a = BluetoothTransport(
        identity: ia,
        server: false,
        native: na,
        textEnabled: true,
        pollInterval: const Duration(milliseconds: 1),
      );
      final b = BluetoothTransport(
        identity: ib,
        server: true,
        native: nb,
        textEnabled: true,
        pollInterval: const Duration(milliseconds: 1),
      );
      final dir = await Directory.systemTemp.createTemp('linyue_bt_e30_test_');
      addTearDown(() => dir.delete(recursive: true));
      final ha = EncryptedTextHistoryRuntime(
        vault: ia.vault,
        directory: Directory('${dir.path}/a'),
      );
      final hb = EncryptedTextHistoryRuntime(
        vault: ib.vault,
        directory: Directory('${dir.path}/b'),
      );
      await ha.initialize();
      await hb.initialize();
      a.onText = (fp, m) async {
        await ha.store.saveConfirmed(
          authenticatedFingerprint: fp,
          message: m,
          outbound: false,
        );
      };
      b.onText = (fp, m) async {
        await hb.store.saveConfirmed(
          authenticatedFingerprint: fp,
          message: m,
          outbound: false,
        );
      };
      addTearDown(() async {
        await a.disconnect();
        await b.disconnect();
        a.dispose();
        b.dispose();
      });
      await b.start(expectedFingerprint: '');
      await a.start(expectedFingerprint: '', deviceId: '112233445566');
      await until(() => a.confirmationRequired && b.confirmationRequired);
      expect(a.textReady, isFalse);
      expect(a.authenticated, isFalse);
      expect(a.comparisonCode, b.comparisonCode);
      await a.confirmAssociation(true);
      await b.confirmAssociation(true);
      await until(() => a.textReady && b.textReady);
      final wa = TextChatMessage.create('电脑 → 手机 中文🙂 ${'长文本' * 500}');
      final wb = TextChatMessage.create('手机 → 电脑，确认！');
      await Future.wait([a.sendText(wa), b.sendText(wb)]);
      expect(
        (await hb.store.loadPeer(ia.local.fingerprint)).single.message.body,
        wa.body,
      );
      expect(
        (await ha.store.loadPeer(ib.local.fingerprint)).single.message.body,
        wb.body,
      );
      expect(a.events.any((e) => e.contains('text peer ACK verified')), isTrue);
      await a.disconnect();
      await expectLater(
        a.sendText(TextChatMessage.create('断线禁止发送')),
        throwsA(anything),
      );
      // Existing trust reconnects without manual comparison (fresh signatures).
      await b.disconnect();
      await b.start(expectedFingerprint: ia.local.fingerprint);
      await a.start(
        expectedFingerprint: ib.local.fingerprint,
        deviceId: '112233445566',
      );
      await until(() => a.textReady && b.textReady);
      expect(a.confirmationRequired, isFalse);
    },
  );
}
