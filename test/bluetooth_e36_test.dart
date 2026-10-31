import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_file_lane.dart';
import 'package:nearlink/bluetooth/bluetooth_file_results.dart';
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';
import 'package:nearlink/bluetooth/bluetooth_protocol.dart';
import 'package:nearlink/services/disk_capacity_guard.dart';
import 'package:nearlink/services/transfer_history.dart';
import 'bluetooth_e32_test.dart' show sha;
import 'bluetooth_poc_test.dart' as b1;
import 'fixtures/e34_bluetooth_protocol.dart' as e34;
import 'package:nearlink/services/conversation_text_protocol.dart';

const aPeer =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const bPeer =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class FailingWriteFile extends Fake implements RandomAccessFile {
  FailingWriteFile(this.file, this.failWrite);
  final RandomAccessFile file;
  final bool Function() failWrite;
  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) {
    if (failWrite()) {
      throw const FileSystemException('ENOSPC injected write failure');
    }
    return file.writeFrom(buffer, start, end);
  }

  @override
  Future<void> close() => file.close();
  @override
  Future<RandomAccessFile> flush() => file.flush();
}

/// Real production Dart state/store/history and host files. The link and native
/// rename callback are test ports, NOT Bluetooth hardware/native API evidence.
class StableWire {
  late Directory root;
  late BluetoothFileLane a, b;
  late BluetoothFileStore aStore, bStore;
  late TransferHistoryStore aHistory, bHistory;
  final queue = <({bool toB, Map<String, dynamic> message})>[];
  final sent = <({bool toB, Map<String, dynamic> message})>[];
  final progress = <BluetoothFileProgress>[];
  final held = <({bool toB, Map<String, dynamic> message})>[];
  bool dropFinal = false,
      dropResult = false,
      holdFinal = false,
      duplicate = false;
  bool failCommit = false,
      failHistory = false,
      failAfterRename = false,
      badSha = false,
      deny = false;
  bool failWrite = false, badLength = false;
  Future<void> Function()? beforeCommit;
  int commitCount = 0;
  Future<void> init({
    Duration timeout = const Duration(seconds: 2),
    bool negotiate = true,
  }) async {
    root = await Directory.systemTemp.createTemp('e36_');
    Future<(BluetoothFileStore, TransferHistoryStore)> storage(
      String side,
    ) async {
      final inbox = await Directory('${root.path}/$side').create();
      final history = TransferHistoryStore(
        customDirectory: Directory('${root.path}/${side}_history'),
      );
      await history.load();
      final store = BluetoothFileStore(
        inbox: inbox,
        work: Directory('${root.path}/${side}_work'),
        reliableResults: true,
        diskGuard: DiskCapacityGuard(lookup: (_) async => 100000000),
        recoverCommitted: (record) async {
          // Host filesystem port for native verify+sync; not Android/Win32 API coverage.
          final f = File('${inbox.path}/${record.savedName}');
          if (!await f.exists() ||
              await f.length() != record.offer.size ||
              sha(await f.readAsBytes()) != record.offer.sha256) {
            throw StateError('host verification failed');
          }
          final handle = await f.open(mode: FileMode.append);
          await handle.flush();
          await handle.close();
          return f;
        },
        openWriter: (f) async => FailingWriteFile(
          await f.open(mode: FileMode.writeOnly),
          () => failWrite,
        ),
        commit: (temporary, offer) async {
          await beforeCommit?.call();
          if (failCommit) throw const FileSystemException('disk full');
          final nonce = offer.commitNonce!;
          final result = BluetoothFileResult(
            side == 'b' ? aPeer : bPeer,
            offer,
            nonce,
            'committing',
            1,
          );
          final target = File('${inbox.path}/${result.savedName}');
          if (await target.exists()) throw StateError('no overwrite');
          await temporary.rename(target.path);
          commitCount++;
          if (failAfterRename) {
            a.close();
            b.close();
            throw StateError('simulated process exit after native rename');
          }
          return target;
        },
      );
      return (store, history);
    }

    final aStorage = await storage('a'), bStorage = await storage('b');
    aStore = aStorage.$1;
    aHistory = aStorage.$2;
    bStore = bStorage.$1;
    bHistory = bStorage.$2;
    Future<void> emit(bool toB, Map<String, dynamic> value) async {
      final entry = (toB: toB, message: Map<String, dynamic>.from(value));
      sent.add(entry);
      if (badSha && value['k'] == 'file-offer') entry.message['sha'] = 'c' * 64;
      if (badLength && value['k'] == 'file-offer') {
        entry.message['size'] = (value['size'] as int) + 1;
      }
      if (value['k'] == 'file-complete') {
        if (holdFinal) {
          held.add(entry);
          return;
        }
        if (dropFinal) return;
      }
      if (dropResult && value['k'] == 'file-result') return;
      // Exercise the actual frame decoder across partial headers and bodies.
      final raw = encodeBluetoothFrame(entry.message),
          decoder = BluetoothFrameDecoder(maxBody: 16380);
      for (var at = 0; at < raw.length; at += 127) {
        for (final m in decoder.add(
          raw.sublist(at, (at + 127).clamp(0, raw.length)),
        )) {
          queue.add((toB: toB, message: m));
        }
      }
      decoder.finish();
      if (duplicate &&
          (value['k'] == 'file-complete' || value['k'] == 'file-result')) {
        queue.add(entry);
      }
    }

    Future<void> received(
      bool sideB,
      BluetoothFileOffer offer,
      File file,
    ) async {
      if (failHistory) throw StateError('injected history write failure');
      await (sideB ? bHistory : aHistory).appendBluetoothConfirmed(
        TransferRecord(
          name: file.uri.pathSegments.last,
          peerName: 'trusted peer',
          direction: 'receive',
          status: 'success',
          bytes: offer.size,
          timestamp: DateTime.now(),
          localPath: file.path,
          transport: 'bluetooth',
          peerFingerprint: sideB ? aPeer : bPeer,
          transferId: offer.id,
          sha256: offer.sha256,
        ),
      );
    }

    a = BluetoothFileLane(
      server: false,
      reverseEnabled: true,
      seal: (m) => emit(true, m),
      alive: () {},
      onProgress: progress.add,
      store: aStore,
      approve: (_) async => !deny,
      onReceived: (o, f) => received(false, o, f),
      peerFingerprint: bPeer,
      ackTimeout: timeout,
    );
    b = BluetoothFileLane(
      server: true,
      reverseEnabled: true,
      seal: (m) => emit(false, m),
      alive: () {},
      onProgress: progress.add,
      store: bStore,
      approve: (_) async => !deny,
      onReceived: (o, f) => received(true, o, f),
      peerFingerprint: aPeer,
      ackTimeout: timeout,
    );
    for (final pair in [(a, b), (b, a)]) {
      pair.$1.observeCapability(pair.$2.capability);
      pair.$1.confirmCapability(pair.$2.capability, pair.$1.capability);
      pair.$1.observeReverse(pair.$2.reverseCapability);
      pair.$1.confirmReverse(
        pair.$2.reverseCapability,
        pair.$1.reverseCapability,
      );
      if (negotiate) {
        pair.$1.observeResult(pair.$2.resultCapability);
        pair.$1.confirmResult(
          pair.$2.resultCapability,
          pair.$1.resultCapability,
        );
      }
    }
    addTearDown(() async {
      a.close();
      b.close();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await root.delete(recursive: true);
    });
  }

  Future<void> pump() async {
    while (queue.isNotEmpty) {
      final e = queue.removeAt(0);
      await (e.toB ? b : a).receive(e.message);
    }
  }

  Future<T> drive<T>(Future<T> task) async {
    var done = false;
    unawaited(
      task.then(
        (_) {
          done = true;
        },
        onError: (Object _) {
          done = true;
        },
      ),
    );
    final clock = Stopwatch()..start();
    while (!done && clock.elapsed < const Duration(seconds: 15)) {
      await pump();
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await pump();
    if (!done) throw StateError('test did not settle');
    return task;
  }

  Future<File> source(int size, {String name = '中文文件.txt'}) => File(
    '${root.path}/$name',
  ).writeAsBytes(List.generate(size, (i) => i % 251));
  Future<BluetoothFileOffer> transfer(File file, {bool reverse = false}) =>
      drive((reverse ? b : a).send(file));
  Iterable<Map<String, dynamic>> get finalReplies => sent
      .map((e) => e.message)
      .where(
        (m) =>
            m['k'] == 'file-complete' ||
            (m['k'] == 'file-result' && m['status'] == 'complete'),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final reverse in [false, true]) {
    for (final size in [1, 10240, 183001, 1048575, 1048576]) {
      test(
        'E36 ${reverse ? 'Android to Windows' : 'Windows to Android'} real file/history size=$size',
        () async {
          final w = StableWire();
          await w.init();
          final file = await w.source(size);
          final result = await w.transfer(file, reverse: reverse);
          final history = reverse ? w.aHistory : w.bHistory;
          expect(history.records.length, 1);
          final saved = File(history.records.single.localPath!);
          expect(await saved.length(), size);
          expect(sha(await saved.readAsBytes()), result.sha256);
          expect(w.commitCount, 1);
          expect(w.finalReplies.length, 1);
        },
      );
    }
  }
  test('E36 oversize and missing source rejected before offer', () async {
    final w = StableWire();
    await w.init();
    await expectLater(w.transfer(await w.source(1048577)), throwsStateError);
    await expectLater(
      w.transfer(File('${w.root.path}/missing')),
      throwsStateError,
    );
    expect(w.sent, isEmpty);
    expect(w.commitCount, 0);
  });
  test(
    'E36 final ACK lost is reconciled once without another commit',
    () async {
      final w = StableWire();
      await w.init(timeout: const Duration(milliseconds: 250));
      w.dropFinal = true;
      final offer = await w.transfer(await w.source(183001));
      expect(w.commitCount, 1);
      expect(w.bHistory.records.length, 1);
      expect(
        w.sent.where((e) => e.message['k'] == 'file-result-query').length,
        1,
      );
      expect(w.a.hasUnconfirmedResult, isFalse);
      expect(
        w.progress.where((p) => !p.receiving).last.phase,
        startsWith('成功'),
      );
      final record = await w.bStore.results.load(aPeer, offer.id);
      expect(record!.phase, 'ackQueued');
    },
  );
  test(
    'E36 both receipts lost stay unknown, manual query is idempotent',
    () async {
      final w = StableWire();
      await w.init(timeout: const Duration(milliseconds: 200));
      w.dropFinal = true;
      w.dropResult = true;
      await expectLater(
        w.transfer(await w.source(10240)),
        throwsA(isA<TimeoutException>()),
      );
      expect(w.a.hasUnconfirmedResult, isTrue);
      expect(w.progress.where((p) => !p.receiving).last.bytes, 10240);
      expect(w.commitCount, 1);
      expect(
        w.progress.where((p) => !p.receiving).last.phase,
        startsWith('失败'),
      );
      await expectLater(
        w.a.send(await w.source(1)),
        throwsStateError,
      ); // no blind retry
      w.dropResult = false;
      final result = await w.drive(w.a.confirmUncertainResult());
      expect(w.commitCount, 1);
      final query = w.sent
          .lastWhere((e) => e.message['k'] == 'file-result-query')
          .message;
      await w.b.receive(query);
      await w.pump();
      await w.b.receive(query);
      await w.pump();
      expect(w.bHistory.records.length, 1);
      expect(w.bHistory.records.single.transferId, result.id);
    },
  );
  test(
    'E36 late original ACK does not overwrite failure; explicit consumption verifies success',
    () async {
      final w = StableWire();
      await w.init(timeout: const Duration(milliseconds: 200));
      w.holdFinal = true;
      w.dropResult = true;
      await expectLater(
        w.transfer(await w.source(1)),
        throwsA(isA<TimeoutException>()),
      );
      w.queue.addAll(w.held);
      await w.pump();
      expect(
        w.progress.where((p) => !p.receiving).last.phase,
        startsWith('失败'),
      );
      await w.drive(w.a.confirmUncertainResult());
      expect(w.commitCount, 1);
      expect(
        w.progress.where((p) => !p.receiving).last.phase,
        startsWith('成功'),
      );
    },
  );
  test(
    'E36 history failure preserves committed file and query repairs once',
    () async {
      final w = StableWire();
      await w.init();
      w.failHistory = true;
      await expectLater(w.transfer(await w.source(183001)), throwsStateError);
      expect(w.finalReplies, isEmpty);
      expect(w.commitCount, 1);
      expect(w.bHistory.records, isEmpty);
      final files = await w.bStore.inbox
          .list()
          .where((f) => f is File)
          .toList();
      expect(files.length, 1);
      w.failHistory = false;
      await w.drive(w.a.confirmUncertainResult());
      expect(w.commitCount, 1);
      expect(w.bHistory.records.length, 1);
      expect(await files.single.exists(), isTrue);
    },
  );
  test(
    'E36 process exit after rename recovers only history, no partial transfer or ACK',
    () async {
      final w = StableWire();
      await w.init();
      w.failAfterRename = true;
      await expectLater(w.transfer(await w.source(183001)), throwsStateError);
      expect(w.finalReplies, isEmpty);
      // New journal instance reads actual disk, no in-memory success flag.
      final fresh = BluetoothFileResults(w.bStore.work, w.bStore.inbox);
      final pending = await fresh.pendingHistory(aPeer).toList();
      expect(pending.length, 1);
      expect(pending.single.phase, 'committing');
      expect(await fresh.verify(pending.single), isA<File>());
      final restored = BluetoothFileLane(
        server: true,
        seal: (_) async {
          fail('repair must not send protocol messages');
        },
        alive: () {},
        onProgress: w.progress.add,
        store: w.bStore,
        peerFingerprint: aPeer,
        approve: (_) async => true,
        onReceived: (offer, file) async {
          await w.bHistory.appendBluetoothConfirmed(
            TransferRecord(
              name: file.uri.pathSegments.last,
              peerName: 'trusted peer',
              direction: 'receive',
              status: 'success',
              bytes: offer.size,
              timestamp: DateTime.now(),
              localPath: file.path,
              transport: 'bluetooth',
              peerFingerprint: aPeer,
              transferId: offer.id,
              sha256: offer.sha256,
            ),
          );
        },
      );
      restored.observeCapability(w.a.capability);
      restored.confirmCapability(w.a.capability, restored.capability);
      final sent = w.sent.length;
      await restored.repairCommittedHistory();
      await restored.repairCommittedHistory();
      restored.close();
      expect(w.bHistory.records.length, 1);
      expect(w.commitCount, 1);
      expect(w.sent.length, sent);
      expect(
        w.progress.where((p) => !p.receiving).last.phase,
        startsWith('失败'),
      ); // no sender success after exit
    },
  );
  test(
    'E36 tampered committed file/history record never yields success',
    () async {
      final w = StableWire();
      await w.init();
      w.failHistory = true;
      await expectLater(w.transfer(await w.source(1)), throwsStateError);
      w.failHistory = false;
      final file =
          (await w.bStore.inbox.list().where((f) => f is File).toList()).single
              as File;
      await file.writeAsBytes([99]);
      await expectLater(
        w.drive(w.a.confirmUncertainResult()),
        throwsStateError,
      );
      expect(w.finalReplies, isEmpty);
      expect(w.bHistory.records, isEmpty);
      expect(await file.exists(), isTrue);
    },
  );
  test(
    'E36 commit failure cannot ACK; reselect after explicit failure on old capability remains possible',
    () async {
      final w = StableWire();
      await w.init(negotiate: false);
      w.failCommit = true;
      await expectLater(w.transfer(await w.source(1)), throwsStateError);
      expect(w.finalReplies, isEmpty);
      w.failCommit = false;
      await w.transfer(await w.source(10240));
      expect(w.commitCount, 1);
    },
  );
  test(
    'E36 absent capability sends no new message and leaves lost receipt unknown',
    () async {
      final w = StableWire();
      await w.init(
        negotiate: false,
        timeout: const Duration(milliseconds: 200),
      );
      w.dropFinal = true;
      await expectLater(
        w.transfer(await w.source(1)),
        throwsA(isA<TimeoutException>()),
      );
      expect(w.sent.any((e) => e.message['k'] == 'file-result-query'), isFalse);
      await expectLater(w.a.confirmUncertainResult(), throwsStateError);
      expect(w.commitCount, 1);
    },
  );
  test(
    'E36 duplicate end, ACK and result do not duplicate history or commit',
    () async {
      final w = StableWire();
      await w.init();
      w.duplicate = true;
      await w.transfer(await w.source(1));
      final end = w.sent.lastWhere((e) => e.message['k'] == 'file-end').message;
      await w.b.receive(end);
      await w.pump();
      expect(w.commitCount, 1);
      expect(w.bHistory.records.length, 1);
    },
  );
  test(
    'E36 same names are distinct tasks and never overwrite an existing file',
    () async {
      final w = StableWire();
      await w.init();
      final src = await w.source(1);
      await w.transfer(src);
      final first = File(w.bHistory.records.single.localPath!);
      final original = await first.readAsBytes();
      await w.transfer(src);
      expect(w.commitCount, 2);
      expect(w.bHistory.records.length, 2);
      expect(await first.readAsBytes(), original);
      expect(w.bHistory.records.map((e) => e.localPath).toSet().length, 2);
    },
  );
  test(
    'E36 SHA failure never commits, later new transfer can succeed',
    () async {
      final w = StableWire();
      await w.init(negotiate: false);
      w.badSha = true;
      await expectLater(w.transfer(await w.source(1)), throwsStateError);
      expect(w.commitCount, 0);
      expect(w.finalReplies, isEmpty);
      w.badSha = false;
      await w.transfer(await w.source(1));
      expect(w.commitCount, 1);
    },
  );
  test('E36 user refusal never creates a successful history record', () async {
    final w = StableWire();
    await w.init();
    w.deny = true;
    await expectLater(w.transfer(await w.source(1)), throwsStateError);
    expect(w.commitCount, 0);
    expect(w.bHistory.records, isEmpty);
  });
  test(
    'E36 cancellation during commit never overwritten by callback success',
    () async {
      final w = StableWire();
      await w.init();
      w.beforeCommit = () async {
        w.a.close();
        w.b.close();
      };
      await expectLater(w.transfer(await w.source(1)), throwsA(anything));
      expect(w.finalReplies, isEmpty);
      expect(w.progress.any((p) => p.phase.startsWith('成功')), isFalse);
    },
  );
  test(
    'E36 result query rejects wrong token and wrong authenticated peer',
    () async {
      final w = StableWire();
      await w.init();
      final offer = await w.transfer(await w.source(1));
      final end = w.sent.lastWhere((e) => e.message['k'] == 'file-end').message;
      await expectLater(
        w.b.receive({...end, 'k': 'file-result-query', 'token': '0' * 32}),
        throwsStateError,
      );
      expect(await w.bStore.results.load(bPeer, offer.id), isNull);
    },
  );
  test(
    'E36 durable journal contains no session token or key and detects corruption',
    () async {
      final w = StableWire();
      await w.init();
      final offer = await w.transfer(await w.source(1));
      final paths = await w.bStore.results.directory
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      for (final f in paths) {
        final s = await f.readAsString();
        expect(s, isNot(contains('token')));
        expect(s, isNot(contains('secretKey')));
        await f.writeAsString('broken');
      }
      await expectLater(
        w.bStore.results.load(aPeer, offer.id),
        throwsStateError,
      );
    },
  );
  test(
    'E36 receive write failure and wrong length never ACK; next transfer works',
    () async {
      final w = StableWire();
      await w.init(negotiate: false);
      w.failWrite = true;
      await expectLater(w.transfer(await w.source(10240)), throwsStateError);
      expect(w.commitCount, 0);
      expect(w.finalReplies, isEmpty);
      expect(w.bHistory.records, isEmpty);
      w.failWrite = false;
      w.badLength = true;
      await expectLater(w.transfer(await w.source(1)), throwsStateError);
      expect(w.commitCount, 0);
      w.badLength = false;
      await w.transfer(await w.source(1));
      expect(w.commitCount, 1);
    },
  );
  test(
    'E36 durable intent precedes commit; no history or final ACK before commit',
    () async {
      final w = StableWire();
      await w.init();
      w.beforeCommit = () async {
        expect(w.finalReplies, isEmpty);
        expect(w.bHistory.records, isEmpty);
        final end = w.sent
            .lastWhere((e) => e.message['k'] == 'file-end')
            .message;
        final result = await w.bStore.results.load(aPeer, end['id']);
        expect(result!.phase, 'committing');
        expect(await w.bStore.results.target(result).exists(), isFalse);
      };
      await w.transfer(await w.source(1));
      final file = File(w.bHistory.records.single.localPath!);
      w.a.close();
      w.b.close();
      expect(await file.exists(), isTrue);
      expect(
        w.progress.where((p) => !p.receiving).last.phase,
        startsWith('成功'),
      );
    },
  );
  test('E36 wire cannot choose the local reserved target nonce', () {
    final offer = BluetoothFileOffer.parse({
      'id': '0' * 32,
      'name': 'a.txt',
      'size': 1,
      'sha': 'a' * 64,
      'commitNonce': '../escape',
    });
    expect(offer.commitNonce, isNull);
  });

  for (final oldServer in <bool?>[null, false, true]) {
    test(
      'E36 real B1 signatures/AEAD duplex file/text with frozen E34 oldServer=$oldServer',
      () async {
        final w = StableWire();
        await w.init();
        final local = await b1.identity(), remote = await b1.identity();
        await b1.trust(local, remote);
        await b1.trust(remote, local);
        final q = <({bool server, Map<String, dynamic> message})>[];
        var maxFrame = 0, texts = 0;
        Future<void> write(bool server, List<int> raw) async {
          maxFrame = raw.length > maxFrame ? raw.length : maxFrame;
          final decoder = BluetoothFrameDecoder(maxBody: 16380);
          for (var at = 0; at < raw.length; at += 13) {
            for (final m in decoder.add(
              raw.sublist(at, (at + 13).clamp(0, raw.length)),
            )) {
              q.add((server: server, message: m));
            }
          }
          decoder.finish();
        }

        Future<BluetoothFileStore> legacyStore(String side) async {
          final inbox = await Directory('${w.root.path}/legacy_$side').create();
          return BluetoothFileStore(
            inbox: inbox,
            work: Directory('${w.root.path}/legacy_${side}_work'),
            diskGuard: DiskCapacityGuard(lookup: (_) async => 100000000),
            commit: (f, o) => f.rename('${inbox.path}/${o.id}_${o.name}'),
          );
        }

        Future<void> history(
          bool server,
          BluetoothFileOffer offer,
          File file,
        ) async {
          final fingerprint = server
              ? local.local.fingerprint
              : remote.local.fingerprint;
          await (server ? w.bHistory : w.aHistory).appendBluetoothConfirmed(
            TransferRecord(
              name: file.uri.pathSegments.last,
              peerName: 'B1 authenticated peer',
              direction: 'receive',
              status: 'success',
              bytes: offer.size,
              timestamp: DateTime.now(),
              localPath: file.path,
              transport: 'bluetooth',
              peerFingerprint: fingerprint,
              transferId: offer.id,
              sha256: offer.sha256,
            ),
          );
        }

        final dynamic client = oldServer == false
            ? e34.BluetoothSecureSession(
                server: false,
                identity: local,
                expectedFingerprint: remote.local.fingerprint,
                write: (b) => write(true, b),
                onState: (_) {},
                onTest: (_) {},
                onText: (_) async {
                  texts++;
                },
                filesEnabled: true,
                reverseFilesEnabled: true,
                fileStore: await legacyStore('client'),
                approveFile: (_) async => true,
                onFileReceived: (o, f) => history(false, o, f),
              )
            : BluetoothSecureSession(
                server: false,
                identity: local,
                expectedFingerprint: remote.local.fingerprint,
                write: (b) => write(true, b),
                onState: (_) {},
                onTest: (_) {},
                onText: (_) async {
                  texts++;
                },
                filesEnabled: true,
                reverseFilesEnabled: true,
                fileStore: w.aStore,
                approveFile: (_) async => true,
                onFileReceived: (o, f) => history(false, o, f),
              );
        final dynamic server = oldServer == true
            ? e34.BluetoothSecureSession(
                server: true,
                identity: remote,
                expectedFingerprint: local.local.fingerprint,
                write: (b) => write(false, b),
                onState: (_) {},
                onTest: (_) {},
                onText: (_) async {
                  texts++;
                },
                filesEnabled: true,
                reverseFilesEnabled: true,
                fileStore: await legacyStore('server'),
                approveFile: (_) async => true,
                onFileReceived: (o, f) => history(true, o, f),
              )
            : BluetoothSecureSession(
                server: true,
                identity: remote,
                expectedFingerprint: local.local.fingerprint,
                write: (b) => write(false, b),
                onState: (_) {},
                onTest: (_) {},
                onText: (_) async {
                  texts++;
                },
                filesEnabled: true,
                reverseFilesEnabled: true,
                fileStore: w.bStore,
                approveFile: (_) async => true,
                onFileReceived: (o, f) => history(true, o, f),
              );
        addTearDown(() => client.close());
        addTearDown(() => server.close());
        Future<void> pump() async {
          while (q.isNotEmpty) {
            final next = q.removeAt(0);
            await (next.server ? server : client).receive(next.message);
          }
        }

        Future<void> drive(Future<dynamic> future) async {
          var done = false;
          unawaited(
            future.then(
              (_) {
                done = true;
              },
              onError: (Object _) {
                done = true;
              },
            ),
          );
          final clock = Stopwatch()..start();
          while (!done && clock.elapsed < const Duration(seconds: 10)) {
            await pump();
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(done, isTrue);
          await future;
          await pump();
        }

        await server.start();
        await client.start();
        for (
          var i = 0;
          i < 100 &&
              !(client.fileSendReady as bool && server.fileSendReady as bool);
          i++
        ) {
          await pump();
          await Future<void>.delayed(Duration.zero);
        }
        expect(client.authenticated, isTrue);
        expect(server.authenticated, isTrue);
        expect(client.fileSendReady, isTrue);
        expect(server.fileSendReady, isTrue);
        final source = await w.source(10240);
        await drive(client.sendFile(source));
        await drive(server.sendFile(source));
        await drive(client.sendText(TextChatMessage.create('中文，E36 ↔ E34。')));
        await drive(server.sendText(TextChatMessage.create('双向文字已收到！')));
        expect(texts, 2);
        expect(maxFrame, lessThanOrEqualTo(16384));
        expect(
          w.aHistory.records.single.peerFingerprint,
          remote.local.fingerprint,
        );
        expect(
          w.bHistory.records.single.peerFingerprint,
          local.local.fingerprint,
        );
      },
    );
  }
}
