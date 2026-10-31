import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_bounded_writer.dart';
import 'package:nearlink/bluetooth/bluetooth_file_lane.dart';
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';
import 'package:nearlink/bluetooth/bluetooth_protocol.dart';
import 'package:nearlink/bluetooth/bluetooth_text_lane.dart';
import 'package:nearlink/bluetooth/bluetooth_transport.dart';
import 'package:nearlink/services/disk_capacity_guard.dart';
import 'package:nearlink/services/transfer_history.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'bluetooth_poc_test.dart' as b1;
import 'bluetooth_e30_test.dart' show DuplexNative, until;
import 'fixtures/e30_bluetooth_text_lane.dart';
import 'fixtures/e30_bluetooth_protocol.dart' as frozen;
import 'test_diagnostics.dart';

String sha(List<int> b) => hashes.sha256.convert(b).toString();
const id = '0123456789abcdef0123456789abcdef';

class FileWire {
  late Directory dir, inbox;
  late BluetoothFileLane a, b;
  final q = <({bool toB, Map<String, dynamic> m})>[];
  final sent = <({bool toB, Map<String, dynamic> m})>[];
  final progress = <BluetoothFileProgress>[];
  final received = <File>[];
  Future<void> Function(File)? beforeCommit;
  bool refuse = false, failWrite = false, dropComplete = false;
  Future<void> init({
    Duration timeout = const Duration(milliseconds: 300),
  }) async {
    dir = await Directory.systemTemp.createTemp('e32_');
    inbox = await Directory('${dir.path}/inbox').create();
    final store = BluetoothFileStore(
      inbox: inbox,
      work: Directory('${dir.path}/work'),
      diskGuard: DiskCapacityGuard(lookup: (_) async => 100 * 1024 * 1024),
      commit: (temp, offer) async {
        // Simulates ONLY Android's atomic commit contract, not real Android I/O.
        await beforeCommit?.call(temp);
        if (failWrite) throw const FileSystemException('disk full');
        final target = File('${inbox.path}/${offer.id}_${offer.name}');
        if (await target.exists()) throw StateError('no overwrite');
        return temp.rename(target.path);
      },
    );
    Future<void> emit(bool toB, Map<String, dynamic> m) async {
      final entry = (toB: toB, m: m);
      sent.add(entry);
      if (!toB && dropComplete && m['k'] == 'file-complete') return;
      final decoder = BluetoothFrameDecoder();
      final bytes = encodeBluetoothFrame(m);
      // Actual production decoder, every header byte and body byte segmented.
      for (final byte in bytes) {
        for (final value in decoder.add([byte])) {
          q.add((toB: toB, m: value));
        }
      }
      decoder.finish();
    }

    a = BluetoothFileLane(
      server: false,
      seal: (m) => emit(true, m),
      alive: () {},
      onProgress: progress.add,
      ackTimeout: timeout,
    );
    b = BluetoothFileLane(
      server: true,
      seal: (m) => emit(false, m),
      alive: () {},
      onProgress: progress.add,
      store: store,
      approve: (_) async => !refuse,
      onReceived: (_, f) async => received.add(f),
      ackTimeout: timeout,
    );
    a.observeCapability(b.capability);
    b.observeCapability(a.capability);
    a.confirmCapability(b.capability, a.capability);
    b.confirmCapability(a.capability, b.capability);
    addTearDown(() async {
      a.close();
      b.close();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await dir.delete(recursive: true);
    });
  }

  Future<void> pump() async {
    while (q.isNotEmpty) {
      final e = q.removeAt(0);
      await (e.toB ? b : a).receive(e.m);
    }
  }

  Future<File> source(int size) async => File(
    '${dir.path}/sample.bin',
  ).writeAsBytes(List.generate(size, (i) => i % 251));
  Future<BluetoothFileOffer> transfer(File f) async {
    final result = a.send(f);
    Object? failure;
    bool done = false;
    unawaited(
      result.then(
        (_) {
          done = true;
        },
        onError: (Object e) {
          failure = e;
          done = true;
        },
      ),
    );
    final clock = Stopwatch()..start();
    while (!done && clock.elapsed < const Duration(seconds: 5)) {
      await pump();
      await Future<void>.delayed(Duration.zero);
    }
    if (failure != null) return result;
    if (!done) throw StateError('test transfer did not settle');
    return result;
  }
}

class CapacityNative extends DuplexNative {
  int peak = 0;
  @override
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? args]) async {
    if (method == 'writeCapacity') {
      return {'generation': generation, 'queuedBytes': 0} as T;
    }
    if (method == 'write') {
      final length = (args!['bytes'] as Uint8List).length;
      if (length > 16384 || other!.buffer.length + length > 65536) {
        throw StateError('native byte budget');
      }
      peak = length > peak ? length : peak;
    }
    return super.invoke<T>(method, args);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final newServer in [true, false]) {
    test(
      'frozen E30 B1 peer preserves encrypted duplex text; newServer=$newServer',
      () async {
        final local = await b1.identity(), remote = await b1.identity();
        await b1.trust(local, remote);
        await b1.trust(remote, local);
        final queue = <({bool toNew, Map<String, dynamic> m})>[];
        var received = 0;
        Future<void> write(bool toNew, Uint8List bytes) async {
          final decoder = BluetoothFrameDecoder();
          for (var i = 0; i < bytes.length; i += 7) {
            queue.addAll(
              decoder
                  .add(bytes.sublist(i, (i + 7).clamp(0, bytes.length)))
                  .map((m) => (toNew: toNew, m: m)),
            );
          }
          decoder.finish();
        }

        final fresh = BluetoothSecureSession(
          server: newServer,
          identity: local,
          expectedFingerprint: remote.local.fingerprint,
          write: (b) => write(false, b),
          onState: (_) {},
          onTest: (_) {},
          onText: (_) async {
            received++;
          },
          filesEnabled: true,
          fileStore: newServer
              ? BluetoothFileStore(
                  inbox: Directory('unused'),
                  work: Directory('also_unused'),
                )
              : null,
          approveFile: (_) async => true,
        );
        final old = frozen.BluetoothSecureSession(
          server: !newServer,
          identity: remote,
          expectedFingerprint: local.local.fingerprint,
          write: (b) => write(true, b),
          onState: (_) {},
          onTest: (_) {},
          onText: (_) async {
            received++;
          },
        );
        addTearDown(fresh.close);
        addTearDown(old.close);
        Future<void> pump() async {
          while (queue.isNotEmpty) {
            final e = queue.removeAt(0);
            if (e.toNew) {
              await fresh.receive(e.m);
            } else {
              await old.receive(e.m);
            }
          }
        }

        await old.start();
        await fresh.start();
        final clock = Stopwatch()..start();
        while (!(fresh.textReady && old.textReady) &&
            clock.elapsed < const Duration(seconds: 3)) {
          await pump();
          await Future<void>.delayed(Duration.zero);
        }
        expect(fresh.textReady && old.textReady, isTrue);
        expect(fresh.fileReady, isFalse);
        final sends = Future.wait([
          fresh.sendText(TextChatMessage.create('新端中文')),
          old.sendText(TextChatMessage.create('旧端中文')),
        ]);
        var done = false;
        unawaited(
          sends.then((_) {
            done = true;
          }),
        );
        while (!done && clock.elapsed < const Duration(seconds: 4)) {
          await pump();
          await Future<void>.delayed(Duration.zero);
        }
        await sends;
        expect(received, 2);
        await expectLater(
          fresh.sendFile(File('must_not_read')),
          throwsStateError,
        );
      },
    );
  }

  test(
    'actual B1 fixed ten-minute expiry cancels pending file without extending lifetime',
    () async {
      final callbacks = <void Function()>[];
      final dir = await Directory.systemTemp.createTemp('e32_expiry_');
      final ia = await b1.identity(), ib = await b1.identity();
      await b1.trust(ia, ib);
      await b1.trust(ib, ia);
      await runZoned(
        () async {
          final na = CapacityNative(), nb = CapacityNative();
          na.other = nb;
          nb.other = na;
          final a = BluetoothTransport(
            identity: ia,
            server: false,
            native: na,
            textEnabled: true,
            filesEnabled: true,
            pollInterval: const Duration(milliseconds: 1),
          );
          final b = BluetoothTransport(
            identity: ib,
            server: true,
            native: nb,
            textEnabled: true,
            filesEnabled: true,
            pollInterval: const Duration(milliseconds: 1),
          );
          final approval = Completer<bool>();
          a.onText = (_, _) async {};
          b.onText = (_, _) async {};
          b.approveFile = (_) => approval.future;
          final inbox = await Directory('${dir.path}/inbox').create();
          b.fileStore = BluetoothFileStore(
            inbox: inbox,
            work: Directory('${dir.path}/work'),
            diskGuard: DiskCapacityGuard(lookup: (_) async => 100000000),
          );
          try {
            await b.start(expectedFingerprint: ia.local.fingerprint);
            await a.start(
              expectedFingerprint: ib.local.fingerprint,
              deviceId: '112233445566',
            );
            await until(() => a.fileReady && b.fileReady);
            expect(callbacks, hasLength(2));
            final file = await File('${dir.path}/x.bin').writeAsBytes([1, 2]);
            final pending = a.sendFile(file);
            final rejected = expectLater(pending, throwsA(anything));
            await until(() => b.fileProgress?.phase == '等待接收确认');
            // Invoke the production timer callback captured at EXACTLY ten minutes.
            callbacks.last();
            await rejected;
            expect(a.fileReady, isFalse);
            expect(a.fileProgress?.phase.startsWith('成功'), isNot(true));
          } finally {
            if (!approval.isCompleted) approval.complete(false);
            await a.disconnect();
            await b.disconnect();
            a.dispose();
            b.dispose();
          }
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration == const Duration(minutes: 10)) {
              callbacks.add(() => zone.run(callback));
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await dir.delete(recursive: true);
    },
  );

  for (final size in [0, 1, 4095, 4096, 4097, 65536, 1048576]) {
    test('production file lane exact bytes and final SHA size=$size', () async {
      final w = FileWire();
      await w.init();
      final f = await w.source(size);
      final result = await w.transfer(f);
      expect(w.received, hasLength(1));
      expect(await w.received.single.readAsBytes(), await f.readAsBytes());
      expect(result.sha256, sha(await f.readAsBytes()));
      expect(w.sent.last.m['k'], 'file-complete');
      expect(w.progress.last.phase, startsWith('成功'));
      expect(
        w.sent
            .where((e) => e.m['k'] == 'file-data')
            .every(
              (e) =>
                  base64Url.decode(base64Url.normalize(e.m['d'])).length <=
                  4096,
            ),
        isTrue,
      );
    });
  }
  for (final name in [
    '../x',
    '/tmp/x',
    'CON.txt',
    '.linyue_resume_v2_x.part',
    'foo.part',
    'a\\b',
    'bad.exe/other',
    'x.',
  ]) {
    test('file metadata rejects unsafe $name', () {
      expect(
        () => BluetoothFileOffer(id: id, name: name, size: 1, sha256: 'a' * 64),
        throwsA(anything),
      );
    });
  }
  test('disconnect during final commit never emits success', () async {
    final w = FileWire();
    await w.init(timeout: const Duration(milliseconds: 100));
    final entered = Completer<void>(), release = Completer<void>();
    w.beforeCommit = (_) async {
      entered.complete();
      await release.future;
    };
    final result = w.transfer(await w.source(10));
    final failed = expectLater(result, throwsA(anything));
    await entered.future;
    w.b.close();
    release.complete();
    await failed;
    expect(w.sent.any((e) => e.m['k'] == 'file-complete'), isFalse);
    expect(w.progress.where((e) => e.phase.startsWith('成功')), isEmpty);
  });
  test('metadata and maximum reject before sending', () async {
    final w = FileWire();
    await w.init();
    final f = await w.source(1048577);
    await expectLater(w.a.send(f), throwsA(anything));
    expect(w.sent, isEmpty);
    expect(
      () => BluetoothFileOffer.parse({
        'id': id,
        'name': 'x',
        'size': '1',
        'sha': 'a' * 64,
      }),
      throwsFormatException,
    );
    expect(
      () => BluetoothFileOffer(id: id, name: 'x', size: -1, sha256: 'a' * 64),
      throwsFormatException,
    );
    expect(
      () => BluetoothFileOffer(id: id, name: 'x', size: 1, sha256: 'wrong'),
      throwsFormatException,
    );
  });
  test('E32 decoder counts header in the 16 KiB total limit', () {
    final allowed = BluetoothFrameDecoder(maxBody: 16380);
    final body = utf8.encode(jsonEncode({'p': 'x' * 16372}));
    expect(body.length, 16380);
    final frame = Uint8List(16384);
    ByteData.sublistView(frame).setUint32(0, body.length);
    frame.setRange(4, frame.length, body);
    expect(allowed.add(frame).single['p'], hasLength(16372));
    final tooLong = Uint8List(4);
    ByteData.sublistView(tooLong).setUint32(0, 16381);
    expect(() => allowed.add(tooLong), throwsFormatException);
  });
  test(
    'file protocol rejects incompatible version and unapproved data',
    () async {
      final w = FileWire();
      await w.init();
      await expectLater(
        w.b.receive({'v': 'other', 'id': id, 'k': 'file-offer'}),
        throwsFormatException,
      );
      await w.b.receive({
        'v': bluetoothFileVersion,
        'id': id,
        'k': 'file-data',
        'token': 'wrong',
        'offset': 0,
        'i': 0,
        'd': 'AQ',
      });
      expect(w.sent.last.m['k'], 'file-error');
      expect(w.received, isEmpty);
    },
  );
  test(
    'wrong offset and changed duplicate data fail without completion',
    () async {
      final w = FileWire();
      await w.init();
      await w.b.receive({
        'v': bluetoothFileVersion,
        'k': 'file-offer',
        'id': id,
        'name': 'x',
        'size': 2,
        'sha': sha([1, 2]),
      });
      final token = w.sent.last.m['token'];
      await w.b.receive({
        'v': bluetoothFileVersion,
        'k': 'file-data',
        'id': id,
        'token': token,
        'offset': 1,
        'i': 0,
        'd': 'AQ',
      });
      expect(w.sent.last.m['k'], 'file-error');
      expect(w.received, isEmpty);
    },
  );
  test('raw file business before B1 authentication is rejected', () async {
    final local = await b1.identity();
    final session = BluetoothSecureSession(
      server: true,
      identity: local,
      expectedFingerprint: 'a' * 64,
      write: (_) async {},
      onState: (_) {},
      onTest: (_) {},
      filesEnabled: true,
    );
    await expectLater(
      session.receive({'k': 'file-data', 'id': id, 'd': 'AQ'}),
      throwsStateError,
    );
    expect(session.authenticated, isFalse);
    expect(session.fileReady, isFalse);
    session.close();
  });
  test(
    'capability absent/wrong version/wrong role does not permit file',
    () async {
      final w = FileWire();
      await w.init();
      w.a.observeCapability(null);
      await expectLater(w.a.send(await w.source(1)), throwsStateError);
      expect(w.sent, isEmpty);
      w.a.observeCapability({...w.b.capability, 'v': 'future'});
      expect(w.a.ready, isFalse);
      w.a.observeCapability(w.a.capability);
      expect(w.a.ready, isFalse);
      await expectLater(w.b.send(await w.source(1)), throwsStateError);
    },
  );
  test('refusal creates no part and no success', () async {
    final w = FileWire();
    await w.init();
    w.refuse = true;
    await expectLater(w.transfer(await w.source(2)), throwsA(anything));
    expect(w.received, isEmpty);
    expect(w.sent.any((e) => e.m['k'] == 'file-complete'), isFalse);
    expect(await w.inbox.list().toList(), isEmpty);
  });
  test('disk failure never sends success ACK', () async {
    final w = FileWire();
    await w.init();
    w.failWrite = true;
    await expectLater(w.transfer(await w.source(4097)), throwsA(anything));
    expect(w.sent.any((e) => e.m['k'] == 'file-complete'), isFalse);
    expect(w.received, isEmpty);
  });
  test('commit must finish before final ACK; temp never in inbox', () async {
    final w = FileWire();
    await w.init();
    final gate = Completer<void>(), entered = Completer<void>();
    w.beforeCommit = (f) async {
      expect(
        await f.parent.parent.resolveSymbolicLinks(),
        await Directory('${w.dir.path}/work').resolveSymbolicLinks(),
      );
      entered.complete();
      await gate.future;
    };
    final send = w.transfer(await w.source(20));
    await entered.future;
    expect(w.sent.any((e) => e.m['k'] == 'file-complete'), isFalse);
    expect(await w.inbox.list().toList(), isEmpty);
    gate.complete();
    await send;
  });
  test('whole SHA mismatch and wrong offset do not complete', () async {
    final w = FileWire();
    await w.init();
    await w.b.receive({
      'v': bluetoothFileVersion,
      'k': 'file-offer',
      'id': id,
      'name': 'x.bin',
      'size': 1,
      'sha': 'a' * 64,
    });
    final token = w.sent.last.m['token'];
    await w.b.receive({
      'v': bluetoothFileVersion,
      'k': 'file-data',
      'id': id,
      'token': token,
      'offset': 0,
      'i': 0,
      'd': 'AQ',
    });
    await w.b.receive({
      'v': bluetoothFileVersion,
      'k': 'file-end',
      'id': id,
      'token': token,
      'size': 1,
      'sha': 'a' * 64,
    });
    expect(w.received, isEmpty);
    expect(w.sent.any((e) => e.m['k'] == 'file-complete'), isFalse);
  });
  test(
    'duplicate data writes once; duplicate end reuses real receipt',
    () async {
      final w = FileWire();
      await w.init();
      final bytes = [1, 2, 3];
      await w.b.receive({
        'v': bluetoothFileVersion,
        'k': 'file-offer',
        'id': id,
        'name': 'x.bin',
        'size': 3,
        'sha': sha(bytes),
      });
      final token = w.sent.last.m['token'];
      final data = {
        'v': bluetoothFileVersion,
        'k': 'file-data',
        'id': id,
        'token': token,
        'offset': 0,
        'i': 0,
        'd': base64Url.encode(bytes).replaceAll('=', ''),
      };
      await w.b.receive(data);
      await w.b.receive(data);
      final end = {
        'v': bluetoothFileVersion,
        'k': 'file-end',
        'id': id,
        'token': token,
        'size': 3,
        'sha': sha(bytes),
      };
      await w.b.receive(end);
      await w.b.receive(end);
      expect(w.received, hasLength(1));
      expect(await w.received.single.readAsBytes(), bytes);
      expect(w.sent.where((e) => e.m['k'] == 'file-complete').length, 2);
      await w.received.single.writeAsBytes([7]);
      await w.b.receive(end);
      expect(w.sent.last.m['k'], 'file-error');
      expect(w.sent.where((e) => e.m['k'] == 'file-complete').length, 2);
    },
  );
  test('missing final ACK fails even though remote file exists', () async {
    final w = FileWire();
    await w.init(timeout: const Duration(milliseconds: 30));
    w.dropComplete = true;
    await expectLater(
      w.transfer(await w.source(2)),
      throwsA(isA<TimeoutException>()),
    );
    expect(w.received, hasLength(1));
    // Both endpoints publish into this list. Under full-suite load the receiver
    // may report its valid local save after the sender's ACK timeout.
    expect(w.progress.where((p) => !p.receiving).last.phase, startsWith('失败'));
    expect(w.progress.where((p) => p.receiving).last.phase, startsWith('成功'));
  });
  test('disconnect/session expiry fails an outstanding offer', () async {
    final w = FileWire();
    await w.init();
    final result = w.a.send(await w.source(1));
    final expectation = expectLater(result, throwsA(anything));
    await until(() => w.q.isNotEmpty);
    w.a.close();
    await expectation;
    expect(w.progress.any((p) => p.phase.startsWith('成功')), isFalse);
  });
  test(
    'byte writer total frame includes header and rejects overflow',
    () async {
      final gate = Completer<void>();
      var free = 0;
      final writes = <int>[];
      final writer = BluetoothBoundedWriter(
        capacity: () async => free,
        write: (b) async {
          writes.add(b.length);
          await gate.future;
        },
      );
      final pending = List.generate(4, (_) => writer.add(Uint8List(16384)));
      expect(writer.pendingBytes, 65536);
      expect(writer.peakBytes, 65536);
      expect(() => writer.add(Uint8List(1)), throwsStateError);
      expect(() => writer.add(Uint8List(16385)), throwsStateError);
      free = 65536;
      gate.complete();
      await Future.wait(pending);
      expect(writer.pendingBytes, 0);
      expect(writes.length, 4);
    },
  );
  test(
    'native byte capacity applies backpressure and bounded timeout',
    () async {
      var writes = 0;
      final writer = BluetoothBoundedWriter(
        capacity: () async => 0,
        write: (_) async {
          writes++;
        },
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        writer.add(Uint8List(10)),
        throwsA(isA<TimeoutException>()),
      );
      expect(writes, 0);
      expect(writer.pendingBytes, 0);
    },
  );
  test('close cancels queued native byte writes', () async {
    final writer = BluetoothBoundedWriter(
      capacity: () async => 0,
      write: (_) async => fail('must not write'),
    );
    final result = writer.add(Uint8List(10));
    writer.close();
    await expectLater(result, throwsStateError);
  });
  test('old E30 ignores optional capability and keeps text usable', () async {
    final q = <({bool old, Map<String, dynamic> m})>[];
    var delivered = 0;
    final lane = BluetoothFileLane(
      server: false,
      seal: (_) async {},
      alive: () {},
      onProgress: (_) {},
    );
    final current = BluetoothTextLane(
      seal: (m) async {
        q.add((old: true, m: m));
      },
      onText: (_) async {},
      onReady: () {},
      onFailure: (_) {},
      fileCapability: lane.capability,
      onFileOffer: lane.observeCapability,
      onFileAck: lane.confirmCapability,
    );
    final old = E30BluetoothTextLane(
      seal: (m) async {
        q.add((old: false, m: m));
      },
      onText: (_) async {
        delivered++;
      },
      onReady: () {},
      onFailure: (_) {},
    );
    addTearDown(current.close);
    addTearDown(old.close);
    addTearDown(lane.close);
    Future<void> pump() async {
      while (q.isNotEmpty) {
        final e = q.removeAt(0);
        if (e.old) {
          await old.receive(e.m);
        } else {
          await current.receive(e.m);
        }
      }
    }

    await current.start();
    await old.start();
    await pump();
    expect(current.ready, isTrue);
    expect(lane.ready, isFalse);
    final text = current.send(TextChatMessage.create('旧版文字仍可用'));
    await pump();
    await text;
    expect(delivered, 1);
  });
  test(
    'temporary work cannot live under inbox; unknown space fails closed',
    () async {
      final d = await Directory.systemTemp.createTemp('e32_store_');
      addTearDown(() => d.delete(recursive: true));
      final offer = BluetoothFileOffer(
        id: id,
        name: 'x',
        size: 1,
        sha256: 'a' * 64,
      );
      final store = BluetoothFileStore(
        inbox: d,
        work: Directory('${d.path}/inside'),
      );
      await expectLater(store.begin(offer), throwsStateError);
      final inbox = await Directory('${d.path}/inbox').create();
      await expectLater(
        BluetoothFileStore(
          inbox: inbox,
          work: Directory('${d.path}/work'),
          diskGuard: DiskCapacityGuard(lookup: (_) async => null),
        ).begin(offer),
        throwsStateError,
      );
    },
  );
  test(
    'Android atomic commit method channel validates native receipt',
    () async {
      const channel = MethodChannel('nearlink/files');
      Map<dynamic, dynamic>? arguments;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'commitBluetoothReceivedFile');
            arguments = call.arguments;
            return {'path': 'x', 'size': 2, 'sha256': 'bad'};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await expectLater(
        BluetoothFileStore.commitAndroid(
          File('temp'),
          BluetoothFileOffer(id: id, name: 'x', size: 1, sha256: 'a' * 64),
        ),
        throwsStateError,
      );
      expect(arguments!['size'], 1);
      expect(arguments!['sha256'], 'a' * 64);
    },
  );
  test(
    'BT history attribution survives rename; legacy JSON remains compatible',
    () async {
      final d = await Directory.systemTemp.createTemp('e32_history_');
      addTearDown(() => d.delete(recursive: true));
      final store = TransferHistoryStore(customDirectory: d);
      await store.load();
      final record = TransferRecord(
        name: 'x',
        peerName: '手机',
        direction: 'receive',
        status: 'success',
        bytes: 1,
        timestamp: DateTime.now(),
        localPath: 'old',
        transport: 'bluetooth',
        peerFingerprint: 'a' * 64,
        transferId: id,
        sha256: 'b' * 64,
      );
      await store.append(record);
      await store.renameReceivedFilePath(
        oldPath: 'old',
        newPath: 'new',
        newName: 'y',
      );
      final restored = TransferHistoryStore(customDirectory: d);
      await restored.load();
      expect(restored.records.single.peerFingerprint, 'a' * 64);
      expect(restored.records.single.transport, 'bluetooth');
      expect(
        TransferRecord.fromJson({...record.toJson()}..remove('transport')).name,
        'x',
      );
    },
  );
  test(
    'BT files create no LAN recovery records and never invoke HTTP send',
    () async {
      final w = FileWire();
      await w.init();
      await w.transfer(await w.source(1));
      final journal = OutboundResumeJournal(
        Directory('${w.dir.path}/lan_journal'),
      );
      expect(await journal.load(), isEmpty);
      expect(
        await w.dir
            .list(recursive: true)
            .any((f) => f.path.contains('.linyue_outbound_resume_')),
        isFalse,
      );
      final source = File(
        'lib/bluetooth/bluetooth_file_lane.dart',
      ).readAsStringSync();
      expect(source.contains('HttpClient'), isFalse);
      expect(source.contains('OutboundResume'), isFalse);
    },
  );
  test(
    'real B1 transports file over bounded native byte stream and still exchange text',
    () async {
      final ia = await b1.identity(), ib = await b1.identity();
      await b1.trust(ia, ib);
      await b1.trust(ib, ia);
      final na = CapacityNative(), nb = CapacityNative();
      na.other = nb;
      nb.other = na;
      final dir = await Directory.systemTemp.createTemp('e32_secure_');
      final inbox = await Directory('${dir.path}/inbox').create();
      final a = BluetoothTransport(
        identity: ia,
        server: false,
        native: na,
        textEnabled: true,
        filesEnabled: true,
        pollInterval: const Duration(milliseconds: 1),
      );
      final b = BluetoothTransport(
        identity: ib,
        server: true,
        native: nb,
        textEnabled: true,
        filesEnabled: true,
        pollInterval: const Duration(milliseconds: 1),
      );
      addTearDown(() async {
        await a.disconnect();
        await b.disconnect();
        a.dispose();
        b.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await dir.delete(recursive: true);
      });
      a.onText = (_, _) async {};
      var textCount = 0;
      b.onText = (_, _) async {
        textCount++;
      };
      b.approveFile = (_) async => true;
      File? received;
      b.onFileReceived = (_, f) async {
        received = f;
      };
      b.fileStore = BluetoothFileStore(
        inbox: inbox,
        work: Directory('${dir.path}/work'),
        diskGuard: DiskCapacityGuard(lookup: (_) async => 100000000),
        commit: (temp, offer) => temp.rename('${inbox.path}/${offer.name}'),
      );
      await b.start(expectedFingerprint: ia.local.fingerprint);
      await a.start(
        expectedFingerprint: ib.local.fingerprint,
        deviceId: '112233445566',
      );
      await until(() => a.fileReady && b.fileReady);
      final file = await File(
        '${dir.path}/small.bin',
      ).writeAsBytes(List.generate(9000, (i) => i % 251));
      final receipt = await a.sendFile(file);
      expect(receipt.sha256, sha(await file.readAsBytes()));
      expect(await received!.readAsBytes(), await file.readAsBytes());
      expect(na.peak, lessThanOrEqualTo(16384));
      final evidence = await testDiagnosticsDirectory();
      await evidence.create(recursive: true);
      await File('${evidence.path}/automated_windows_role.log').writeAsString(
        'AUTOMATED PRODUCTION DART / SIMULATED NATIVE; NOT HARDWARE\n${a.events.join('\n')}\n',
      );
      await File('${evidence.path}/automated_android_role.log').writeAsString(
        'AUTOMATED PRODUCTION DART / SIMULATED NATIVE; NOT HARDWARE\n${b.events.join('\n')}\n',
      );

      await a.sendText(TextChatMessage.create('文件后文字'));
      expect(textCount, 1);
      await a.disconnect();
      await expectLater(a.sendFile(file), throwsStateError);
    },
  );
}
