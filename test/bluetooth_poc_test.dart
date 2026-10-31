import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_protocol.dart';
import 'package:nearlink/bluetooth/bluetooth_transport.dart';
import 'package:nearlink/security/device_identity.dart';

class MemoryVault implements IdentityVault {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

Future<DeviceIdentityManager> identity() async {
  final i = DeviceIdentityManager(MemoryVault());
  await i.initialize();
  return i;
}

Future<void> trust(DeviceIdentityManager a, DeviceIdentityManager b) =>
    a.register(
      displayName: 'test peer',
      identityCard: b.local.card,
      independentlyCheckedFingerprint: b.local.fingerprint,
    );

class Wire {
  late BluetoothSecureSession client, server;
  late DeviceIdentityManager a, b;
  final queue = <({bool toServer, Uint8List bytes})>[];
  final clientFrames = <Uint8List>[], serverFrames = <Uint8List>[];
  final fromClient = <Uint8List>[], fromServer = <Uint8List>[];
  final cd = BluetoothFrameDecoder(), sd = BluetoothFrameDecoder();
  bool dropServer = false;
  Future<void> init({Duration ack = const Duration(seconds: 1)}) async {
    a = await identity();
    b = await identity();
    await trust(a, b);
    await trust(b, a);
    client = BluetoothSecureSession(
      server: false,
      identity: a,
      expectedFingerprint: b.local.fingerprint,
      ackTimeout: ack,
      write: (bytes) async {
        clientFrames.add(bytes);
        queue.add((toServer: true, bytes: bytes));
      },
      onState: (_) {},
      onTest: fromServer.add,
    );
    server = BluetoothSecureSession(
      server: true,
      identity: b,
      expectedFingerprint: a.local.fingerprint,
      write: (bytes) async {
        serverFrames.add(bytes);
        if (!dropServer) queue.add((toServer: false, bytes: bytes));
      },
      onState: (_) {},
      onTest: fromClient.add,
    );
    addTearDown(() {
      client.close();
      server.close();
    });
    await server.start();
    await client.start();
  }

  Future<void> pump({bool fragments = false}) async {
    // Allow asynchronous cryptography and ACK generation to enqueue more data.
    for (var tick = 0; tick < 6 || queue.isNotEmpty; tick++) {
      if (tick > 100) throw StateError('Protocol did not settle');
      await Future<void>.delayed(Duration.zero);
      while (queue.isNotEmpty) {
        final item = queue.removeAt(0);
        final decoder = item.toServer ? sd : cd;
        final target = item.toServer ? server : client;
        if (fragments) {
          for (final byte in item.bytes) {
            for (final m in decoder.add([byte])) {
              await target.receive(m);
            }
          }
        } else {
          for (final m in decoder.add(item.bytes)) {
            await target.receive(m);
          }
        }
      }
    }
  }

  Future<void> authenticate() async {
    await init();
    await pump();
  }
}

class FakeNative implements BluetoothNative {
  int generation = 0, starts = 0, stops = 0;
  String state = 'idle';
  bool wrongGeneration = false, failStart = false;
  Uint8List bytes = Uint8List(0);
  @override
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? arguments]) async {
    Object? value;
    if (method == 'stop') {
      stops++;
      generation++;
      state = 'idle';
      bytes = Uint8List(0);
    }
    if (method == 'start' || method == 'connect') {
      if (failStart) throw StateError('Permission denied');
      starts++;
      generation++;
      state = 'listening';
      value = generation;
    }
    if (method == 'poll') {
      value = {
        'generation': wrongGeneration ? generation + 1 : generation,
        'state': state,
        'error': 'test disconnect',
        'bytes': bytes,
      };
      bytes = Uint8List(0);
    }
    return value as T?;
  }
}

void main() {
  group('bounded RFCOMM framing', () {
    test('UTF-8 round trip', () {
      expect(
        BluetoothFrameDecoder().add(encodeBluetoothFrame({'text': '邻跃✓'})),
        [
          {'text': '邻跃✓'},
        ],
      );
    });
    test('binary values survive bounded JSON encoding', () {
      final data = List<int>.generate(256, (i) => i);
      expect(
        BluetoothFrameDecoder()
            .add(encodeBluetoothFrame({'binary': data}))
            .single['binary'],
        data,
      );
    });
    test('every possible split including length header', () {
      final frame = encodeBluetoothFrame({'text': '分片测试'});
      for (var split = 0; split <= frame.length; split++) {
        final d = BluetoothFrameDecoder();
        expect(
          [...d.add(frame.sublist(0, split)), ...d.add(frame.sublist(split))],
          [
            {'text': '分片测试'},
          ],
        );
        d.finish();
      }
    });
    test('coalesced consecutive messages', () {
      expect(
        BluetoothFrameDecoder().add([
          ...encodeBluetoothFrame({'a': 1}),
          ...encodeBluetoothFrame({'b': 2}),
        ]),
        [
          {'a': 1},
          {'b': 2},
        ],
      );
    });
    test(
      'reject zero length',
      () => expect(
        () => BluetoothFrameDecoder().add([0, 0, 0, 0]),
        throwsFormatException,
      ),
    );
    test(
      'reject excessive length before allocating body',
      () => expect(
        () => BluetoothFrameDecoder().add([127, 255, 255, 255]),
        throwsFormatException,
      ),
    );
    test(
      'reject overlarge encoding',
      () => expect(
        () => encodeBluetoothFrame({'x': 'x' * 20000}),
        throwsFormatException,
      ),
    );
    test(
      'reject malformed UTF-8',
      () => expect(
        () => BluetoothFrameDecoder().add([0, 0, 0, 1, 255]),
        throwsFormatException,
      ),
    );
    test(
      'reject non-object',
      () => expect(
        () => BluetoothFrameDecoder().add([0, 0, 0, 2, 91, 93]),
        throwsFormatException,
      ),
    );
    test('incomplete disconnect clears decoder', () {
      final d = BluetoothFrameDecoder();
      d.add([0, 0, 0, 12, 123]);
      expect(d.finish, throwsFormatException);
      expect(d.add(encodeBluetoothFrame({'new': true})), [
        {'new': true},
      ]);
    });
    test('incomplete header rejected', () {
      final d = BluetoothFrameDecoder();
      d.add([0, 0]);
      expect(d.finish, throwsFormatException);
    });
  });

  group('mutual registered identity authentication', () {
    test('wrong UUID rejected before proof or business', () async {
      final w = Wire();
      await w.init();
      final hello = BluetoothFrameDecoder().add(w.clientFrames.first).single;
      hello['uuid'] = 'wrong-service';
      await expectLater(w.server.receive(hello), throwsStateError);
      expect(w.serverFrames, isEmpty);
      expect(w.fromClient, isEmpty);
    });
    test('client signature corruption rejected by Android role', () async {
      final w = Wire();
      await w.init();
      await w.server.receive(
        BluetoothFrameDecoder().add(w.clientFrames.first).single,
      );
      await w.client.receive(
        BluetoothFrameDecoder().add(w.serverFrames.first).single,
      );
      final proof = BluetoothFrameDecoder().add(w.clientFrames.last).single;
      proof['sig'] = base64Url
          .encode(List<int>.filled(64, 0))
          .replaceAll('=', '');
      await expectLater(w.server.receive(proof), throwsStateError);
      expect(w.server.authenticated, isFalse);
    });
    test('revoked outbound identity clears authenticated authority', () async {
      final w = Wire();
      await w.authenticate();
      final before = w.clientFrames.length;
      await w.a.revoke(w.b.local.fingerprint);
      await expectLater(w.client.sendTest([1]), throwsStateError);
      expect(w.client.authenticated, isFalse);
      expect(w.clientFrames.length, before);
    });
    test(
      'fresh signed handshake and both directional key confirmations',
      () async {
        final w = Wire();
        await w.authenticate();
        expect(w.client.authenticated, isTrue);
        expect(w.server.authenticated, isTrue);
      },
    );
    test('handshake survives single-byte reads', () async {
      final w = Wire();
      await w.init();
      await w.pump(fragments: true);
      expect(w.client.authenticated && w.server.authenticated, isTrue);
    });
    test('UTF-8 actual delivery requires peer ACK', () async {
      final w = Wire();
      await w.authenticate();
      final data = utf8.encode('邻跃 UTF-8 ✓');
      var done = false;
      final result = w.client.sendTest(data).then((_) {
        done = true;
      });
      expect(done, isFalse);
      await w.pump();
      await result;
      expect(w.fromClient.single, data);
    });
    test('binary reply Android to Windows is confirmed', () async {
      final w = Wire();
      await w.authenticate();
      final data = List<int>.generate(256, (i) => i);
      final result = w.server.sendTest(data);
      await w.pump();
      await result;
      expect(w.fromServer.single, data);
    });
    test('simultaneous duplex tests keep send sequence order', () async {
      final w = Wire();
      await w.authenticate();
      final a = w.client.sendTest([1, 2]), b = w.server.sendTest([3, 4]);
      await w.pump();
      await Future.wait([a, b]);
      expect(w.fromClient.single, [1, 2]);
      expect(w.fromServer.single, [3, 4]);
    });
    test('business send before authentication rejected', () async {
      final w = Wire();
      await w.init();
      await expectLater(w.client.sendTest([1]), throwsStateError);
      expect(w.fromClient, isEmpty);
    });
    test('injected business receive before authentication rejected', () async {
      final w = Wire();
      await w.init();
      await expectLater(
        w.server.receive({'t': 'test', 'd': 'AA'}),
        throwsStateError,
      );
      expect(w.server.closed, isTrue);
      expect(w.fromClient, isEmpty);
    });
    test('OS address/name cannot substitute unregistered identity', () async {
      final w = Wire();
      await w.init();
      final stranger = await identity();
      final hello = BluetoothFrameDecoder().add(w.clientFrames.first).single;
      hello['card'] = stranger.local.card;
      await expectLater(w.server.receive(hello), throwsStateError);
      expect(w.server.authenticated, isFalse);
    });
    test('selected identity must already be registered', () async {
      final a = await identity(), b = await identity();
      final s = BluetoothSecureSession(
        server: true,
        identity: a,
        expectedFingerprint: b.local.fingerprint,
        write: (_) async {},
        onState: (_) {},
        onTest: (_) {},
      );
      addTearDown(s.close);
      await expectLater(s.start(), throwsStateError);
      expect(s.closed, isTrue);
    });
    test('server signature corruption rejected', () async {
      final w = Wire();
      await w.init();
      final hello = w.queue.removeAt(0);
      await w.server.receive(BluetoothFrameDecoder().add(hello.bytes).single);
      final proof = BluetoothFrameDecoder().add(w.serverFrames.first).single;
      proof['sig'] = base64Url
          .encode(List<int>.filled(64, 0))
          .replaceAll('=', '');
      await expectLater(w.client.receive(proof), throwsStateError);
      expect(w.client.authenticated, isFalse);
    });
    test('replay old server proof to new challenge rejected', () async {
      final old = Wire();
      await old.authenticate();
      final current = Wire();
      await current.init();
      // Same trusted identities, new session nonce and ephemeral key.
      current.client.close();
      final c = BluetoothSecureSession(
        server: false,
        identity: old.a,
        expectedFingerprint: old.b.local.fingerprint,
        write: (_) async {},
        onState: (_) {},
        onTest: (_) {},
      );
      addTearDown(c.close);
      await c.start();
      await expectLater(
        c.receive(BluetoothFrameDecoder().add(old.serverFrames.first).single),
        throwsStateError,
      );
    });
    test('replay encrypted frame rejected', () async {
      final w = Wire();
      await w.authenticate();
      final sent = w.client.sendTest([4]);
      await w.pump();
      await sent;
      final frame = BluetoothFrameDecoder().add(w.clientFrames.last).single;
      await expectLater(w.server.receive(frame), throwsStateError);
      expect(w.fromClient.length, 1);
    });
    test('ciphertext tampering rejected before callback', () async {
      final w = Wire();
      await w.authenticate();
      final sent = w.client.sendTest([4]);
      final rejected = expectLater(sent, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final frame = BluetoothFrameDecoder().add(w.clientFrames.last).single;
      frame['m'] = base64Url
          .encode(List<int>.filled(16, 0))
          .replaceAll('=', '');
      await expectLater(w.server.receive(frame), throwsA(anything));
      w.client.close('Peer rejected frame');
      await rejected;
      expect(w.fromClient, isEmpty);
    });
    test('revoked peer denied before incoming business', () async {
      final w = Wire();
      await w.authenticate();
      await w.b.revoke(w.a.local.fingerprint);
      final sent = w.client.sendTest([4]);
      final rejected = expectLater(sent, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final frame = BluetoothFrameDecoder().add(w.clientFrames.last).single;
      await expectLater(w.server.receive(frame), throwsStateError);
      w.client.close('Revoked');
      await rejected;
      expect(w.fromClient, isEmpty);
    });
    test('no peer ACK means failure even after local write', () async {
      final w = Wire();
      await w.init(ack: const Duration(milliseconds: 30));
      await w.pump();
      w.dropServer = true;
      final sent = w.client.sendTest([9]);
      final rejected = expectLater(sent, throwsA(isA<TimeoutException>()));
      await w.pump();
      await rejected;
      expect(w.fromClient.single, [9]);
      expect(w.client.closed, isTrue);
    });
    test('disconnect fails pending ACK and clears authority', () async {
      final w = Wire();
      await w.authenticate();
      final sent = w.client.sendTest([1]);
      final rejected = expectLater(sent, throwsStateError);
      w.client.close('Disconnected');
      await rejected;
      expect(w.client.authenticated, isFalse);
    });
    test('authentication deadline closes idle session', () async {
      final a = await identity(), b = await identity();
      await trust(a, b);
      final s = BluetoothSecureSession(
        server: true,
        identity: a,
        expectedFingerprint: b.local.fingerprint,
        write: (_) async {},
        onState: (_) {},
        onTest: (_) {},
        handshakeTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(s.close);
      await s.start();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(s.closed, isTrue);
      expect(s.error, contains('timeout'));
    });
    test('duplicate session start rejected', () async {
      final w = Wire();
      await w.init();
      await expectLater(w.client.start(), throwsStateError);
    });
    test('oversized test is not emitted', () async {
      final w = Wire();
      await w.authenticate();
      final count = w.clientFrames.length;
      await expectLater(
        w.client.sendTest(List<int>.filled(2049, 0)),
        throwsStateError,
      );
      expect(w.clientFrames.length, count);
    });
  });

  group('isolated transport lifecycle with native boundary fake', () {
    Future<BluetoothTransport> create(
      FakeNative fake, {
      bool server = true,
    }) async => BluetoothTransport(
      identity: await identity(),
      server: server,
      native: fake,
      pollInterval: const Duration(milliseconds: 1),
      connectionTimeout: const Duration(milliseconds: 15),
    );
    test('concurrent start does not create duplicate listener', () async {
      final n = FakeNative();
      final s = await create(n);
      addTearDown(s.dispose);
      final first = s.start(expectedFingerprint: 'x');
      expect(() => s.start(expectedFingerprint: 'x'), throwsStateError);
      await first;
      expect(n.starts, 1);
    });
    test('stop and restart get fresh native generations', () async {
      final n = FakeNative();
      final t = await create(n);
      addTearDown(t.dispose);
      await t.start(expectedFingerprint: 'x');
      final old = n.generation;
      await t.disconnect();
      await t.start(expectedFingerprint: 'x');
      expect(n.generation, greaterThan(old));
      expect(n.starts, 2);
    });
    test('stale native generation rejected', () async {
      final n = FakeNative();
      final s = await create(n);
      addTearDown(s.dispose);
      await s.start(expectedFingerprint: 'x');
      n.wrongGeneration = true;
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(s.state, 'error');
      expect(s.lastError, contains('generation'));
    });
    test('native permission/start failure releases resources', () async {
      final n = FakeNative()..failStart = true;
      final t = await create(n);
      addTearDown(t.dispose);
      await expectLater(t.start(expectedFingerprint: 'x'), throwsStateError);
      expect(t.active, isFalse);
      expect(n.stops, greaterThanOrEqualTo(2));
    });
    test('client connect deadline stops native operation', () async {
      final n = FakeNative();
      final t = await create(n, server: false);
      addTearDown(t.dispose);
      await t.start(expectedFingerprint: 'x', deviceId: 'AABBCC3CF797');
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(t.state, 'error');
      expect(t.lastError, contains('timeout'));
    });
    test('dispose releases native connection', () async {
      final n = FakeNative();
      final t = await create(n);
      await t.start(expectedFingerprint: 'x');
      t.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(n.state, 'idle');
      expect(n.stops, greaterThanOrEqualTo(2));
    });
  });
}
