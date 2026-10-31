import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_file_lane.dart';
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';
import 'package:nearlink/bluetooth/bluetooth_source_stage.dart';
import 'package:nearlink/bluetooth/bluetooth_protocol.dart';
import 'package:nearlink/bluetooth/bluetooth_transport.dart';
import 'package:nearlink/services/disk_capacity_guard.dart';
import 'package:nearlink/services/received_file_visibility.dart';
import 'package:nearlink/services/transfer_history.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'fixtures/e32_bluetooth_protocol.dart' as e32;
import 'bluetooth_poc_test.dart' as b1;
import 'bluetooth_e30_test.dart' show until;
import 'bluetooth_e32_test.dart' show sha, CapacityNative;
import 'test_diagnostics.dart';

class ReverseWire {
  late Directory root;
  late BluetoothFileLane android, windows;
  final q = <({bool android, Map<String, dynamic> value})>[];
  final sent = <Map<String, dynamic>>[];
  final received = <File>[];
  final progress = <BluetoothFileProgress>[];
  Future<void> Function(File)? beforeCommit;
  bool corruptFinal = false;
  bool badSha = false,
      dropFinal = false,
      duplicateFinal = false,
      failHistory = false;
  Future<void> init({
    bool reverse = true,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    root = await Directory.systemTemp.createTemp('e33_');
    Future<void> emit(bool toAndroid, Map<String, dynamic> value) async {
      value = Map.from(value);
      if (corruptFinal && value['k'] == 'file-complete') {
        value['token'] = '0' * 32;
      }
      sent.add(value);
      if (badSha && value['k'] == 'file-offer') value['sha'] = 'a' * 64;
      if (dropFinal && value['k'] == 'file-complete') return;
      final decoder = BluetoothFrameDecoder();
      final raw = encodeBluetoothFrame(value);
      for (var i = 0; i < raw.length; i += 7) {
        for (final m in decoder.add(
          raw.sublist(i, (i + 7).clamp(0, raw.length)),
        )) {
          q.add((android: toAndroid, value: m));
        }
      }
      decoder.finish();
      if (duplicateFinal && value['k'] == 'file-complete') {
        q.add((android: toAndroid, value: Map.from(value)));
      }
    }

    Future<BluetoothFileStore> store(String side) async {
      final inbox = await Directory('${root.path}/$side').create();
      return BluetoothFileStore(
        inbox: inbox,
        work: Directory('${inbox.path}/.linyue_part_bt_e33'),
        allowWindowsNestedWork: true,
        diskGuard: DiskCapacityGuard(lookup: (_) async => 100000000),
        commit: (file, offer) async {
          await beforeCommit?.call(file);
          final target = File('${inbox.path}/${offer.id}_${offer.name}');
          if (await target.exists()) throw StateError('no overwrite');
          return file.rename(
            target.path,
          ); // Test port, NOT production Win32/Android native I/O.
        },
      );
    }

    android = BluetoothFileLane(
      server: true,
      reverseEnabled: reverse,
      seal: (m) => emit(false, m),
      alive: () {},
      onProgress: progress.add,
      store: await store('android'),
      approve: (_) async => true,
      onReceived: (_, f) async {
        if (failHistory) throw StateError('history failed');
        received.add(f);
      },
      ackTimeout: timeout,
    );
    windows = BluetoothFileLane(
      server: false,
      reverseEnabled: reverse,
      seal: (m) => emit(true, m),
      alive: () {},
      onProgress: progress.add,
      store: await store('windows'),
      approve: (_) async => true,
      onReceived: (_, f) async {
        if (failHistory) throw StateError('history failed');
        received.add(f);
      },
      ackTimeout: timeout,
    );
    for (final pair in [(android, windows), (windows, android)]) {
      pair.$1.observeCapability(pair.$2.capability);
      pair.$1.confirmCapability(pair.$2.capability, pair.$1.capability);
      pair.$1.observeReverse(pair.$2.reverseCapability);
      pair.$1.confirmReverse(
        pair.$2.reverseCapability,
        pair.$1.reverseCapability,
      );
    }
    addTearDown(() async {
      android.close();
      windows.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await root.delete(recursive: true);
    });
  }

  Future<void> pump() async {
    while (q.isNotEmpty) {
      final p = q.removeAt(0);
      await (p.android ? android : windows).receive(p.value);
    }
  }

  Future<File> source(int size, {String name = '中文文件.txt'}) => File(
    '${root.path}/$name',
  ).writeAsBytes(List.generate(size, (i) => i % 251));
  Future<BluetoothFileOffer> transfer(File f, {bool forward = false}) async {
    final send = (forward ? windows : android).send(f);
    var done = false;
    unawaited(
      send.then(
        (_) {
          done = true;
        },
        onError: (Object _) {
          done = true;
        },
      ),
    );
    final clock = Stopwatch()..start();
    while (!done && clock.elapsed < const Duration(seconds: 8)) {
      await pump();
      await Future<void>.delayed(Duration.zero);
    }
    if (!done) throw StateError('test transfer did not settle');
    await pump();
    return send;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [1, 10240, 183001, 1048576]) {
    test('E33 reverse segmented file exact SHA size=$size', () async {
      final w = ReverseWire();
      await w.init();
      final f = await w.source(
        size,
        name: size == 183001 ? '图片.png' : '中文文件.txt',
      );
      final receipt = await w.transfer(f);
      expect(receipt.name, f.uri.pathSegments.last);
      expect(receipt.size, size);
      expect(await w.received.single.readAsBytes(), await f.readAsBytes());
      expect(receipt.sha256, sha(await w.received.single.readAsBytes()));
      expect(w.sent.last['k'], 'file-complete');
    });
  }
  test(
    'E33 forward then reverse keeps same frame protocol and isolated names',
    () async {
      final w = ReverseWire();
      await w.init();
      final f = await w.source(3);
      await w.transfer(f, forward: true);
      await w.transfer(f);
      await w.transfer(f);
      expect(w.received.length, 3);
      expect(w.received.map((f) => f.path).toSet().length, 3);
    },
  );
  test('E33 exceeds maximum before offer', () async {
    final w = ReverseWire();
    await w.init();
    await expectLater(w.transfer(await w.source(1048577)), throwsStateError);
    expect(w.sent, isEmpty);
  });
  test('E33 mismatched reverse echo does not grant send capability', () async {
    final w = ReverseWire();
    await w.init();
    w.android.confirmReverse(w.windows.reverseCapability, {'forged': true});
    expect(w.android.sendReady, isFalse);
    await expectLater(w.transfer(await w.source(1)), throwsStateError);
    expect(w.sent, isEmpty);
  });
  test('E33 wrong final receipt token never reports sender success', () async {
    final w = ReverseWire();
    await w.init();
    w.corruptFinal = true;
    await expectLater(w.transfer(await w.source(1)), throwsStateError);
    expect(
      w.progress.where((p) => !p.receiving && p.phase.startsWith('成功')),
      isEmpty,
    );
  });
  test('E33 file cannot be sent before B1 authentication', () async {
    final local = await b1.identity();
    var writes = 0;
    final session = BluetoothSecureSession(
      server: true,
      identity: local,
      expectedFingerprint: 'a' * 64,
      write: (_) async {
        writes++;
      },
      onState: (_) {},
      onTest: (_) {},
      onText: (_) async {},
      filesEnabled: true,
      reverseFilesEnabled: true,
    );
    addTearDown(session.close);
    await expectLater(
      session.sendFile(File('must-not-be-read')),
      throwsStateError,
    );
    expect(writes, 0);
  });
  test(
    'E33 reverse requires two-way capability, forward remains available',
    () async {
      final w = ReverseWire();
      await w.init(reverse: false);
      expect(w.android.sendReady, isFalse);
      expect(w.windows.receiveReady, isFalse);
      await expectLater(w.transfer(await w.source(1)), throwsStateError);
      await w.transfer(await w.source(1), forward: true);
    },
  );
  test('E33 wrong SHA never commits or sends final success', () async {
    final w = ReverseWire();
    await w.init();
    w.badSha = true;
    await expectLater(w.transfer(await w.source(1)), throwsStateError);
    expect(w.received, isEmpty);
    expect(w.sent.where((m) => m['k'] == 'file-complete'), isEmpty);
  });
  test('E33 commit failure no final ACK, retry succeeds', () async {
    final w = ReverseWire();
    await w.init();
    w.beforeCommit = (_) async {
      throw const FileSystemException('access denied');
    };
    final f = await w.source(10240);
    await expectLater(w.transfer(f), throwsStateError);
    expect(w.received, isEmpty);
    expect(w.sent.where((m) => m['k'] == 'file-complete'), isEmpty);
    w.beforeCommit = null;
    await w.transfer(f);
    expect(w.received.length, 1);
  });
  test('E33 history failure cannot acknowledge completed save', () async {
    final w = ReverseWire();
    await w.init();
    w.failHistory = true;
    await expectLater(w.transfer(await w.source(1)), throwsStateError);
    expect(w.received, isEmpty);
    expect(w.sent.where((m) => m['k'] == 'file-complete'), isEmpty);
  });
  test('E33 disconnect during commit cannot acknowledge', () async {
    final w = ReverseWire();
    await w.init();
    w.beforeCommit = (_) async {
      w.windows.close();
      w.android.close();
    };
    await expectLater(w.transfer(await w.source(1)), throwsA(anything));
    expect(w.received, isEmpty);
    expect(w.sent.where((m) => m['k'] == 'file-complete'), isEmpty);
  });
  test('E33 duplicated final ACK is idempotent', () async {
    final w = ReverseWire();
    await w.init();
    w.duplicateFinal = true;
    await w.transfer(await w.source(1));
    expect(w.received.length, 1);
    expect(w.android.ready, isTrue);
  });
  test('E33 lost final ACK fails sender while receiver file is real', () async {
    final w = ReverseWire();
    await w.init(timeout: const Duration(milliseconds: 300));
    w.dropFinal = true;
    await expectLater(
      w.transfer(await w.source(1)),
      throwsA(isA<TimeoutException>()),
    );
    expect(w.received.length, 1);
    expect(w.progress.where((p) => !p.receiving).last.phase, startsWith('失败'));
  });
  for (final bad in [false, true]) {
    test('E33 bounded URI source ${bad ? 'oversize' : 'normal'}', () async {
      final root = await Directory.systemTemp.createTemp('e33_picker_');
      addTearDown(() => root.delete(recursive: true));
      final result = BluetoothSourceStage.create(
        root: root,
        name: '文档.txt',
        declaredSize: 3,
        read: () => Stream.fromIterable(
          bad
              ? [
                  [1, 2],
                  [3, 4],
                ]
              : [
                  [1],
                  [2, 3],
                ],
        ),
      );
      if (bad) {
        await expectLater(result, throwsStateError);
        expect(await root.list().toList(), isEmpty);
      } else {
        final stage = await result;
        expect(await stage.file.readAsBytes(), [1, 2, 3]);
        await stage.dispose();
        expect(await root.list().toList(), isEmpty);
      }
    });
  }
  test('E33 over-limit picker metadata does not even open stream', () async {
    var read = false;
    await expectLater(
      BluetoothSourceStage.create(
        root: Directory('unused'),
        name: 'a.txt',
        declaredSize: 1048577,
        read: () {
          read = true;
          return const Stream.empty();
        },
      ),
      throwsStateError,
    );
    expect(read, isFalse);
  });
  test('E33 picker read failure cleans its own temporary child', () async {
    final root = await Directory.systemTemp.createTemp('e33_picker_fail_');
    addTearDown(() => root.delete(recursive: true));
    await expectLater(
      BluetoothSourceStage.create(
        root: root,
        name: 'a.txt',
        declaredSize: 1,
        read: () => Stream.error(const FileSystemException('unreadable')),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await root.list().toList(), isEmpty);
  });
  test(
    'E33 history persists fingerprint/route and deduplicates only same identity/task',
    () async {
      final root = await Directory.systemTemp.createTemp('e33_history_');
      addTearDown(() => root.delete(recursive: true));
      final store = TransferHistoryStore(customDirectory: root);
      await store.load();
      TransferRecord record(String fp) => TransferRecord(
        name: '同名.txt',
        peerName: '我的手机',
        direction: 'receive',
        status: 'success',
        bytes: 1,
        timestamp: DateTime.now(),
        localPath: 'received',
        transport: 'bluetooth',
        peerFingerprint: fp,
        transferId: 'a' * 32,
        sha256: 'b' * 64,
      );
      await store.appendBluetoothConfirmed(record('c' * 64));
      await store.appendBluetoothConfirmed(record('c' * 64));
      await store.appendBluetoothConfirmed(record('d' * 64));
      final loaded = TransferHistoryStore(customDirectory: root);
      await loaded.load();
      expect(loaded.records.length, 2);
      expect(loaded.records.map((e) => e.peerFingerprint).toSet(), {
        'c' * 64,
        'd' * 64,
      });
    },
  );
  test(
    'E33 history disk failure rolls back only its Bluetooth entry',
    () async {
      final store = TransferHistoryStore();
      final record = TransferRecord(
        name: 'a',
        peerName: 'p',
        direction: 'receive',
        status: 'success',
        bytes: 1,
        timestamp: DateTime.now(),
        transport: 'bluetooth',
        peerFingerprint: 'a' * 64,
        transferId: 'b' * 32,
        sha256: 'c' * 64,
      );
      await expectLater(
        store.appendBluetoothConfirmed(record),
        throwsStateError,
      );
      expect(store.records, isEmpty);
    },
  );
  for (final name in [
    '.linyue_resume_${'a' * 32}.part',
    '.linyue_resume_v2_${'a' * 32}.a.json',
    '.linyue_resume_${'a' * 32}.b.json',
    '.linyue_resume_${'a' * 32}.receipt.json',
    '.linyue_resume_${'a' * 32}.receipt.json.tmp.123',
    '.linyue_part_bt_failed_abc',
  ]) {
    test(
      'E33 internal file is not completed candidate: $name',
      () => expect(isCompletedReceivedName(name), isFalse),
    );
  }
  test('E33 normal received names remain visible', () {
    for (final n in ['photo.png', '中文文件.txt', 'notes.json']) {
      expect(isCompletedReceivedName(n), isTrue);
    }
  });
  test('E33 MethodChannel commit validates actual metadata receipt', () async {
    const ch = MethodChannel('nearlink/bluetooth_file_commit');
    Map? args;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
          args = call.arguments as Map;
          return {'path': 'final', 'size': 1, 'sha256': 'a' * 64};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null),
    );
    await BluetoothFileStore.commitWindows(
      File('temp'),
      BluetoothFileOffer(
        id: 'a' * 32,
        name: '文档.txt',
        size: 1,
        sha256: 'a' * 64,
      ),
      Directory('inbox'),
    );
    expect(args!['inbox'], 'inbox');
    expect(args!['name'], '文档.txt');
    expect(args!['sha256'], 'a' * 64);
  });
  for (final newServer in [true, false]) {
    test(
      'E33 vs frozen accepted E32 preserves W->A and text; newServer=$newServer',
      () async {
        final local = await b1.identity(), remote = await b1.identity();
        await b1.trust(local, remote);
        await b1.trust(remote, local);
        final root = await Directory.systemTemp.createTemp('e33_compat_');
        addTearDown(() => root.delete(recursive: true));
        Future<BluetoothFileStore> store(String name) async {
          final d = await Directory('${root.path}/$name').create();
          return BluetoothFileStore(
            inbox: d,
            work: Directory('${root.path}/${name}_work'),
            diskGuard: DiskCapacityGuard(lookup: (_) async => 100000000),
            commit: (f, o) => f.rename('${d.path}/${o.id}_${o.name}'),
          );
        }

        final queue = <({bool fresh, Map<String, dynamic> m})>[];
        Future<void> write(bool fresh, Uint8List data) async {
          final decoder = BluetoothFrameDecoder();
          for (final m in decoder.add(data)) {
            queue.add((fresh: fresh, m: m));
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
          onText: (_) async {},
          filesEnabled: true,
          reverseFilesEnabled: true,
          fileStore: await store('fresh'),
          approveFile: (_) async => true,
        );
        final old = e32.BluetoothSecureSession(
          server: !newServer,
          identity: remote,
          expectedFingerprint: local.local.fingerprint,
          write: (b) => write(true, b),
          onState: (_) {},
          onTest: (_) {},
          onText: (_) async {},
          filesEnabled: true,
          fileStore: await store('old'),
          approveFile: (_) async => true,
        );
        addTearDown(fresh.close);
        addTearDown(old.close);
        Future<void> pump() async {
          while (queue.isNotEmpty) {
            final e = queue.removeAt(0);
            if (e.fresh) {
              await fresh.receive(e.m);
            } else {
              await old.receive(e.m);
            }
          }
        }

        await old.start();
        await fresh.start();
        for (var i = 0; i < 100 && !(fresh.fileReady && old.fileReady); ++i) {
          await pump();
          await Future<void>.delayed(Duration.zero);
        }
        expect(fresh.fileReady && old.fileReady, isTrue);
        expect(fresh.fileSendReady, !newServer);
        expect(fresh.fileReceiveReady, newServer);
        final source = await File('${root.path}/x.txt').writeAsBytes([1, 2, 3]);
        final pending = newServer
            ? old.sendFile(source)
            : fresh.sendFile(source);
        var done = false;
        unawaited(
          pending.then(
            (_) {
              done = true;
            },
            onError: (Object _) {
              done = true;
            },
          ),
        );
        final limit = Stopwatch()..start();
        while (!done && limit.elapsed < const Duration(seconds: 5)) {
          await pump();
          await Future<void>.delayed(Duration.zero);
        }
        expect(done, isTrue, reason: 'protocol operation must settle');
        await pending;
        final text = Future.wait([
          fresh.sendText(TextChatMessage.create('新端文字')),
          old.sendText(TextChatMessage.create('旧端文字')),
        ]);
        done = false;
        unawaited(
          text.then(
            (_) {
              done = true;
            },
            onError: (Object _) {
              done = true;
            },
          ),
        );
        limit.reset();
        while (!done && limit.elapsed < const Duration(seconds: 5)) {
          await pump();
          await Future<void>.delayed(Duration.zero);
        }
        expect(done, isTrue, reason: 'text operation must settle');
        await text;
        if (newServer) {
          await expectLater(fresh.sendFile(source), throwsStateError);
        }
      },
    );
  }
  test(
    'E33 production B1 transports reverse file and both directions text over simulated native',
    () async {
      final ia = await b1.identity(), iw = await b1.identity();
      await b1.trust(ia, iw);
      await b1.trust(iw, ia);
      final na = CapacityNative(), nw = CapacityNative();
      na.other = nw;
      nw.other = na;
      final root = await Directory.systemTemp.createTemp('e33_secure_');
      final a = BluetoothTransport(
        identity: ia,
        server: true,
        native: na,
        textEnabled: true,
        filesEnabled: true,
        reverseFilesEnabled: true,
        pollInterval: const Duration(milliseconds: 1),
      );
      final w = BluetoothTransport(
        identity: iw,
        server: false,
        native: nw,
        textEnabled: true,
        filesEnabled: true,
        reverseFilesEnabled: true,
        pollInterval: const Duration(milliseconds: 1),
      );
      addTearDown(() async {
        await a.disconnect();
        await w.disconnect();
        a.dispose();
        w.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await root.delete(recursive: true);
      });
      var text = 0, received = 0;
      for (final t in [a, w]) {
        t.onText = (_, _) async {
          text++;
        };
        t.approveFile = (_) async => true;
        t.onFileReceived = (_, _) async {
          received++;
        };
        final inbox = await Directory('${root.path}/${t.server}').create();
        t.fileStore = BluetoothFileStore(
          inbox: inbox,
          work: Directory('${root.path}/work_${t.server}'),
          diskGuard: DiskCapacityGuard(lookup: (_) async => 100000000),
          commit: (f, o) => f.rename('${inbox.path}/${o.id}_${o.name}'),
        );
      }
      await a.start(expectedFingerprint: iw.local.fingerprint);
      await w.start(
        expectedFingerprint: ia.local.fingerprint,
        deviceId: '112233445566',
      );
      await until(() => a.fileSendReady && w.fileReceiveReady);
      final f = await File('${root.path}/small.txt').writeAsBytes([1, 2, 3]);
      await a.sendFile(f);
      await w.sendFile(f);
      await a.sendText(TextChatMessage.create('手机中文'));
      await w.sendText(TextChatMessage.create('电脑中文'));
      expect(received, 2);
      expect(text, 2);
      expect(na.peak, lessThanOrEqualTo(16384));
      expect(nw.peak, lessThanOrEqualTo(16384));
      final d = await testDiagnosticsDirectory();
      await d.create(recursive: true);
      await File('${d.path}/e33_automated_android_role.log').writeAsString(
        'PRODUCTION DART/B1, SIMULATED NATIVE; NOT HARDWARE\n${a.events.join('\n')}\n',
      );
      await File('${d.path}/e33_automated_windows_role.log').writeAsString(
        'PRODUCTION DART/B1, SIMULATED NATIVE; NOT HARDWARE\n${w.events.join('\n')}\n',
      );
    },
  );
}
