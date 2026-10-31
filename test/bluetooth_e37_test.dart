import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_file_lane.dart';
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';
import 'package:nearlink/bluetooth/bluetooth_file_policy.dart';
import 'package:nearlink/bluetooth/bluetooth_bounded_writer.dart';
import 'package:nearlink/bluetooth/bluetooth_protocol.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'bluetooth_e36_test.dart' show StableWire, aPeer, bPeer;
import 'bluetooth_poc_test.dart' as b1;
import 'fixtures/e36_bluetooth_protocol.dart' as e36;
import 'test_diagnostics.dart';

Future<String> digest(File file) async =>
    (await crypto.sha256.bind(file.openRead()).first).toString();
Future<File> sourceFile(Directory root, int size) async {
  final f = File('${root.path}/流式_${size}B.bin');
  final output = await f.open(mode: FileMode.writeOnly);
  final block = Uint8List.fromList(List.generate(65536, (i) => i % 251));
  try {
    for (var at = 0; at < size; at += block.length) {
      await output.writeFrom(block, 0, math.min(block.length, size - at));
    }
    await output.flush();
  } finally {
    await output.close();
  }
  return f;
}

// E36's 15-second harness was sized for 1 MiB. This driver yields without
// imposing a per-frame 1 ms timer, and never retains file payloads in evidence.
// Protocol ACK/idle/session deadlines remain production values.
class ExpansionWire extends StableWire {
  @override
  Future<void> pump() async {
    await super.pump();
    for (final entry in sent) {
      if (entry.message['k'] == 'file-data') entry.message.remove('d');
    }
  }

  @override
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
    while (!done && clock.elapsed < const Duration(minutes: 2)) {
      await pump();
      await Future<void>.delayed(Duration.zero);
    }
    await pump();
    if (!done) throw StateError('E37 harness did not settle in two minutes');
    return task;
  }
}

Future<StableWire> wire({
  bool aCandidate = true,
  bool bCandidate = true,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final w = ExpansionWire();
  await w.init(timeout: timeout);
  final oldA = w.a, oldB = w.b;
  BluetoothFileStore wrap(BluetoothFileStore old, bool candidate) =>
      BluetoothFileStore(
        inbox: old.inbox,
        work: old.work,
        maxBytes: candidate
            ? bluetoothCandidateFileBytes
            : bluetoothFileMaxBytes,
        reliableResults: true,
        diskGuard: old.diskGuard,
        commit: old.commit,
        openWriter: old.openWriter,
        recoverCommitted: (record) async {
          final file = File('${old.inbox.path}/${record.savedName}');
          if (await file.length() != record.offer.size ||
              await digest(file) != record.offer.sha256) {
            throw StateError('host recovery SHA mismatch');
          }
          final writer = await file.open(mode: FileMode.append);
          await writer.flush();
          await writer.close();
          return file;
        },
      );
  w.aStore = wrap(w.aStore, aCandidate);
  w.bStore = wrap(w.bStore, bCandidate);
  w.a = BluetoothFileLane(
    server: false,
    reverseEnabled: true,
    seal: oldA.seal,
    alive: () {},
    onProgress: w.progress.add,
    store: w.aStore,
    approve: oldA.approve,
    onReceived: oldA.onReceived,
    peerFingerprint: bPeer,
    ackTimeout: timeout,
  );
  w.b = BluetoothFileLane(
    server: true,
    reverseEnabled: true,
    seal: oldB.seal,
    alive: () {},
    onProgress: w.progress.add,
    store: w.bStore,
    approve: oldB.approve,
    onReceived: oldB.onReceived,
    peerFingerprint: aPeer,
    ackTimeout: timeout,
  );
  oldA.close();
  oldB.close();
  for (final p in [(w.a, w.b), (w.b, w.a)]) {
    p.$1.observeCapability(p.$2.capability);
    p.$1.confirmCapability(p.$2.capability, p.$1.capability);
    p.$1.observeReverse(p.$2.reverseCapability);
    p.$1.confirmReverse(p.$2.reverseCapability, p.$1.reverseCapability);
    p.$1.observeResult(p.$2.resultCapability);
    p.$1.confirmResult(p.$2.resultCapability, p.$1.resultCapability);
    p.$1.observeSize(p.$2.sizeCapability);
    p.$1.confirmSize(p.$2.sizeCapability, p.$1.sizeCapability);
  }
  return w;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('E38 default is 10MiB while E36 wire fallback remains 1MiB', () {
    expect(bluetoothFileMaxBytes, 1048576);
    expect(bluetoothStableFileBytes, 1048576);
    expect(bluetoothCandidateFileBytes, 10485760);
    expect(bluetoothDefaultFileBytes, 10485760);
    expect(bluetoothBuildFileLimit(), 10485760);
    expect(
      () => BluetoothFileOffer(
        id: '0' * 32,
        name: 'a',
        size: 1048577,
        sha256: 'a' * 64,
      ),
      throwsFormatException,
    );
    expect(BluetoothBoundedWriter.frameLimit, 16384);
    expect(BluetoothBoundedWriter.byteLimit, 65536);
  });
  for (final reverse in [false, true]) {
    for (final size in [1, 183001, 1048576, 1048577, 10485759, 10485760]) {
      test(
        'E37 ${reverse ? 'Android->Windows' : 'Windows->Android'} bounded real host file size=$size',
        () async {
          final w = await wire();
          final f = await sourceFile(w.root, size);
          final expected = await digest(f);
          final watch = Stopwatch()..start();
          final offer = await w.transfer(f, reverse: reverse);
          watch.stop();
          final history = reverse ? w.aHistory : w.bHistory;
          final saved = File(history.records.single.localPath!);
          expect(await saved.length(), size);
          expect(await digest(saved), expected);
          expect(offer.sha256, expected);
          expect(w.commitCount, 1);
          expect(w.finalReplies.length, 1);
          expect((reverse ? w.b : w.a).maxFileBytes, 10485760);
          final metrics = {
            'kind':
                'production Dart file lane + simulated wire/native commit + real host disk; NOT HARDWARE',
            'direction': reverse
                ? 'Android-role->Windows-role'
                : 'Windows-role->Android-role',
            'bytes': size,
            'sha256': expected,
            'elapsedUs': watch.elapsedMicroseconds,
            'payloadBytesPerSec':
                size * 1000000 / math.max(1, watch.elapsedMicroseconds),
            'rssBytes': ProcessInfo.currentRss,
            'processLifetimeMaxRssBytes': ProcessInfo.maxRss,
            'framePayloadMax': 4096,
            'finalAck': 'verified',
            'commitCount': w.commitCount,
            'historyRecords': history.records.length,
          };
          final d = await testDiagnosticsDirectory();
          await File(
            '${d.path}/e37_${reverse ? 'A_W' : 'W_A'}_$size.json',
          ).writeAsString(jsonEncode(metrics));
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }
  }
  test('E37 10MiB+1 rejected before offer both directions', () async {
    final w = await wire();
    final f = await sourceFile(w.root, 10485761);
    await expectLater(w.a.send(f), throwsStateError);
    await expectLater(w.b.send(f), throwsStateError);
    expect(w.sent, isEmpty);
    expect(w.commitCount, 0);
  });
  for (final oldA in [true, false]) {
    test(
      'E37 one stable endpoint keeps both directions <=1MiB oldA=$oldA',
      () async {
        final w = await wire(aCandidate: !oldA, bCandidate: oldA);
        expect(w.a.maxFileBytes, 1048576);
        expect(w.b.maxFileBytes, 1048576);
        final tooBig = await sourceFile(w.root, 1048577);
        await expectLater(w.a.send(tooBig), throwsStateError);
        await expectLater(w.b.send(tooBig), throwsStateError);
        expect(w.sent, isEmpty);
        final small = await sourceFile(w.root, 1048576);
        await w.transfer(small);
        await w.transfer(small, reverse: true);
        expect(w.commitCount, 2);
      },
    );
  }
  test('E37 wrong expansion echo never raises file limit', () async {
    final w = await wire();
    w.a.confirmSize(w.b.sizeCapability, {
      'v': 'linyue-bt-limit-e37-v1',
      'max': 10485761,
    });
    expect(w.a.maxFileBytes, 1048576);
    await expectLater(
      w.a.send(await sourceFile(w.root, 1048577)),
      throwsStateError,
    );
    expect(w.sent, isEmpty);
    await w.b.receive({
      'v': bluetoothFileVersion,
      'k': 'file-offer',
      'id': '1' * 32,
      'name': 'unsafe',
      'size': 10485761,
      'sha': 'a' * 64,
    });
    expect(w.commitCount, 0);
    expect(w.finalReplies, isEmpty);
  });
  test(
    'E37 10MiB ACK loss uses E36 result query without a second commit',
    () async {
      // Still shorter than production's 15s ACK limit; allow 10MiB host hashing.
      final w = await wire(timeout: const Duration(seconds: 2));
      w.dropFinal = true;
      await w.transfer(await sourceFile(w.root, 10485760));
      expect(w.commitCount, 1);
      expect(w.bHistory.records.length, 1);
      expect(
        w.sent.where((e) => e.message['k'] == 'file-result-query').length,
        1,
      );
      final end = w.sent.lastWhere((e) => e.message['k'] == 'file-end').message;
      await w.b.receive(end);
      await w.pump();
      expect(w.commitCount, 1);
      expect(w.bHistory.records.length, 1);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'E37 write and commit failures never ACK; new complete attempt can work',
    () async {
      final w = await wire();
      w.failWrite = true;
      await expectLater(
        w.transfer(await sourceFile(w.root, 1048577)),
        throwsStateError,
      );
      expect(w.finalReplies, isEmpty);
      w.failWrite = false;
      w.failCommit = true;
      await expectLater(
        w.transfer(await sourceFile(w.root, 1048577)),
        throwsStateError,
      );
      expect(w.commitCount, 0);
      // A new connection, not data resume. No application task is given to LAN.
      final next = await wire();
      await next.transfer(await sourceFile(next.root, 1048577));
      expect(next.commitCount, 1);
    },
  );
  test(
    'E37 SHA mismatch and disconnect in commit never report success',
    () async {
      final w = await wire();
      w.badSha = true;
      await expectLater(
        w.transfer(await sourceFile(w.root, 1048577)),
        throwsStateError,
      );
      expect(w.finalReplies, isEmpty);
      expect(w.commitCount, 0);
      final next = await wire();
      next.beforeCommit = () async {
        next.a.close();
        next.b.close();
      };
      await expectLater(
        next.transfer(await sourceFile(next.root, 1048577)),
        throwsA(anything),
      );
      expect(next.finalReplies, isEmpty);
    },
  );
  test('E37 byte backpressure keeps 64KiB even for many frames', () async {
    var free = 0, writes = 0;
    final writer = BluetoothBoundedWriter(
      capacity: () async => free,
      write: (_) async {
        writes++;
      },
    );
    final futures = List.generate(4, (_) => writer.add(Uint8List(16384)));
    expect(() => writer.add(Uint8List(1)), throwsStateError);
    expect(writer.pendingBytes, 65536);
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(writes, 0);
    expect(writer.backpressurePolls, greaterThan(0));
    free = 65536;
    await Future.wait(futures);
    expect(writer.peakBytes, 65536);
    expect(writer.pendingBytes, 0);
    writer.close();
  });
  for (final oldServer in <bool?>[null, false, true]) {
    test(
      'E37 real B1/AEAD fragmented bounded native and E36 mixed max oldServer=$oldServer',
      () async {
        final w = await wire();
        final local = await b1.identity(), remote = await b1.identity();
        await b1.trust(local, remote);
        await b1.trust(remote, local);
        final q = <({bool server, Map<String, dynamic> m})>[];
        var peakFrame = 0, texts = 0;
        final writerA = BluetoothBoundedWriter(
          capacity: () async => 65536,
          write: (bytes) async {
            peakFrame = math.max(peakFrame, bytes.length);
            final d = BluetoothFrameDecoder(maxBody: 16380);
            for (var i = 0; i < bytes.length; i += 311) {
              for (final m in d.add(
                bytes.sublist(i, math.min(i + 311, bytes.length)),
              )) {
                q.add((server: true, m: m));
              }
            }
          },
        );
        final writerB = BluetoothBoundedWriter(
          capacity: () async => 65536,
          write: (bytes) async {
            peakFrame = math.max(peakFrame, bytes.length);
            final d = BluetoothFrameDecoder(maxBody: 16380);
            for (var i = 0; i < bytes.length; i += 277) {
              for (final m in d.add(
                bytes.sublist(i, math.min(i + 277, bytes.length)),
              )) {
                q.add((server: false, m: m));
              }
            }
          },
        );
        Future<void> received(
          bool server,
          BluetoothFileOffer offer,
          File file,
        ) async {
          expect(await digest(file), offer.sha256);
          expect(await file.length(), offer.size);
        }

        final dynamic client = oldServer == false
            ? e36.BluetoothSecureSession(
                server: false,
                identity: local,
                expectedFingerprint: remote.local.fingerprint,
                write: writerA.add,
                onState: (_) {},
                onTest: (_) {},
                onText: (_) async {
                  texts++;
                },
                filesEnabled: true,
                reverseFilesEnabled: true,
                fileStore: w.aStore,
                approveFile: (_) async => true,
                onFileReceived: (o, f) => received(false, o, f),
              )
            : BluetoothSecureSession(
                server: false,
                identity: local,
                expectedFingerprint: remote.local.fingerprint,
                write: writerA.add,
                onState: (_) {},
                onTest: (_) {},
                onText: (_) async {
                  texts++;
                },
                filesEnabled: true,
                reverseFilesEnabled: true,
                fileStore: w.aStore,
                approveFile: (_) async => true,
                onFileReceived: (o, f) => received(false, o, f),
              );
        final dynamic server = oldServer == true
            ? e36.BluetoothSecureSession(
                server: true,
                identity: remote,
                expectedFingerprint: local.local.fingerprint,
                write: writerB.add,
                onState: (_) {},
                onTest: (_) {},
                onText: (_) async {
                  texts++;
                },
                filesEnabled: true,
                reverseFilesEnabled: true,
                fileStore: w.bStore,
                approveFile: (_) async => true,
                onFileReceived: (o, f) => received(true, o, f),
              )
            : BluetoothSecureSession(
                server: true,
                identity: remote,
                expectedFingerprint: local.local.fingerprint,
                write: writerB.add,
                onState: (_) {},
                onTest: (_) {},
                onText: (_) async {
                  texts++;
                },
                filesEnabled: true,
                reverseFilesEnabled: true,
                fileStore: w.bStore,
                approveFile: (_) async => true,
                onFileReceived: (o, f) => received(true, o, f),
              );
        addTearDown(() => client.close());
        addTearDown(() => server.close());
        Future<void> pump() async {
          while (q.isNotEmpty) {
            final e = q.removeAt(0);
            await (e.server ? server : client).receive(e.m);
          }
        }

        Future<void> drive(Future<dynamic> task) async {
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
          while (!done && clock.elapsed < const Duration(minutes: 2)) {
            await pump();
            await Future<void>.delayed(Duration.zero);
          }
          expect(done, isTrue);
          await task;
          await pump();
        }

        await server.start();
        await client.start();
        for (var i = 0; i < 100; i++) {
          await pump();
          if (client.fileSendReady as bool && server.fileSendReady as bool) {
            break;
          }
          await Future<void>.delayed(Duration.zero);
        }
        final expected = oldServer == null ? 10485760 : 1048576;
        if (oldServer != false) expect(client.maxFileBytes, expected);
        if (oldServer != true) expect(server.maxFileBytes, expected);
        final source = await sourceFile(w.root, expected);
        final clock = Stopwatch()..start();
        await drive(client.sendFile(source));
        await drive(server.sendFile(source));
        if (oldServer != null) {
          final tooLarge = await sourceFile(w.root, 1048577);
          await expectLater(
            (oldServer == true ? client : server).sendFile(tooLarge),
            throwsStateError,
          );
        }
        await drive(client.sendText(TextChatMessage.create('E37中文、标点。')));
        await drive(server.sendText(TextChatMessage.create('E36兼容测试')));
        expect(texts, 2);
        expect(peakFrame, lessThanOrEqualTo(16384));
        expect(writerA.peakBytes, lessThanOrEqualTo(65536));
        expect(writerB.peakBytes, lessThanOrEqualTo(65536));
        final d = await testDiagnosticsDirectory();
        await File('${d.path}/e37_b1_$oldServer.json').writeAsString(
          jsonEncode({
            'scope':
                'real B1 cryptography/production framing and bounded writer; simulated native, real host files, NOT HARDWARE',
            'oldServer': oldServer,
            'bytesEachDirection': expected,
            'elapsedUsDuplexWithText': clock.elapsedMicroseconds,
            'peakFrameBytes': peakFrame,
            'writerAPeak': writerA.peakBytes,
            'writerBPeak': writerB.peakBytes,
            'rss': ProcessInfo.currentRss,
            'processLifetimeMaxRss': ProcessInfo.maxRss,
          }),
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
