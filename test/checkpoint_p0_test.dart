import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/checkpoint_primitives/checkpoint_store.dart';

String sha(List<int> bytes) => hashes.sha256.convert(bytes).toString();
BtCheckpointIdentity identity({
  String id = '11111111111111111111111111111111',
  String local =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String peer =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  String name = '中文文件.bin',
  int size = 3,
  String? digest,
  String route = 'bluetooth',
  BtCheckpointRole role = BtCheckpointRole.receiver,
  String? source,
}) => BtCheckpointIdentity(
  taskId: id,
  localFingerprint: local,
  peerFingerprint: peer,
  role: role,
  fileName: name,
  fileSize: size,
  fileSha256: digest ?? sha([1, 2, 3]),
  dataBinding: 'dddddddddddddddddddddddddddddddd',
  sourceBinding: source,
  transport: route,
);

BtCheckpointRecord record(
  BtCheckpointIdentity task, {
  int generation = 0,
  int offset = 0,
  String previous = '',
  String? prefix,
  BtCheckpointStatus status = BtCheckpointStatus.created,
  String? reason,
}) => BtCheckpointRecord(
  identity: task,
  generation: generation,
  previousHash: previous,
  offset: offset,
  prefixSha256: prefix ?? btCheckpointEmptySha256,
  status: status,
  createdUtc: DateTime.utc(2026, 10, 26),
  updatedUtc: DateTime.utc(2026, 10, 26),
  terminalReason: reason,
);

class Sandbox {
  late Directory base;
  late BtCheckpointStore store;
  final task = identity();
  Future<void> init({
    Future<void> Function(BtCheckpointFaultPoint)? fault,
  }) async {
    base = await Directory.systemTemp.createTemp('linyue_p0_');
    store = BtCheckpointStore(baseDirectory: base, fault: fault);
    addTearDown(() async {
      await base.delete(recursive: true);
    });
  }

  Directory get root =>
      Directory('${base.path}/${BtCheckpointStore.namespace}');
  Directory get taskDir => Directory('${root.path}/${task.taskId}');
  File generation(int n) =>
      File('${taskDir.path}/g${n.toString().padLeft(3, '0')}.json');
  Future<File> filled() async {
    await store.createTask(task);
    final f = await store.dataFile(task);
    await f.writeAsBytes([1, 2, 3]);
    return f;
  }
}

Matcher error(String code) =>
    throwsA(isA<BtCheckpointException>().having((e) => e.code, 'code', code));

// A separate closure scope passes only serializable values, not the test's
// Completers or fault callback. This invokes the real store in another isolate.
Future<String> loadFromSeparateIsolate(
  String basePath,
  Map<String, dynamic> taskJson,
) => Isolate.run(() async {
  final other = BtCheckpointStore(baseDirectory: Directory(basePath));
  try {
    await other.load(BtCheckpointIdentity.fromJson(taskJson));
    return 'unexpected-success';
  } on BtCheckpointException catch (e) {
    return e.code;
  }
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('P0 pure model', () {
    test(
      'identity roundtrip uses stable fingerprints and opaque source/data bindings',
      () {
        final i = identity(role: BtCheckpointRole.sender, source: 'c' * 32);
        expect(BtCheckpointIdentity.fromJson(i.toJson()).sameAs(i), isTrue);
        expect(i.toJson().keys, isNot(contains('session')));
        expect(
          BtCheckpointIdentity.newId(),
          matches(RegExp(r'^[a-f0-9]{32}$')),
        );
        expect(
          BtCheckpointIdentity.newId(),
          isNot(BtCheckpointIdentity.newId()),
        );
      },
    );
    for (final bad in ['', 'a' * 31, '../escape', 'A' * 32]) {
      test(
        'invalid task ID $bad',
        () => expect(() => identity(id: bad), throwsFormatException),
      );
    }
    for (final bad in [
      '../bad',
      'CON.txt',
      '',
      '.hidden',
      'a.part',
      'a.writing',
    ]) {
      test(
        'unsafe name $bad',
        () => expect(() => identity(name: bad), throwsFormatException),
      );
    }
    test(
      'LAN, missing source identity, wrong size and fingerprint rejected',
      () {
        expect(() => identity(route: 'lan'), throwsFormatException);
        expect(() => identity(local: 'short'), throwsFormatException);
        expect(() => identity(peer: 'a' * 64), throwsFormatException);
        expect(
          () => identity(role: BtCheckpointRole.sender),
          throwsFormatException,
        );
        expect(() => identity(size: 10485761), throwsFormatException);
        expect(() => identity(digest: 'short'), throwsFormatException);
      },
    );
    test('record roundtrip, zero and exact full offset', () {
      final first = record(identity());
      expect(BtCheckpointRecord.fromJson(first.toJson()).digest, first.digest);
      final last = record(
        identity(),
        generation: 1,
        offset: 3,
        previous: first.digest,
        prefix: sha([1, 2, 3]),
        status: BtCheckpointStatus.completed,
        reason: 'local-data-sealed',
      );
      first.validateNext(last);
      expect(last.offset, 3);
      expect(last.status.isTerminal, isTrue);
    });
    for (final offset in [-1, 4]) {
      test(
        'invalid offset $offset',
        () => expect(
          () => record(identity(), offset: offset),
          throwsFormatException,
        ),
      );
    }
    test('invalid schemas/fields/generations and metadata types', () {
      final m = record(identity()).toJson();
      expect(
        () => BtCheckpointRecord.fromJson({...m, 'schema': 'future-v2'}),
        throwsFormatException,
      );
      final missing = Map<String, dynamic>.from(m)..remove('offset');
      expect(() => BtCheckpointRecord.fromJson(missing), throwsFormatException);
      expect(
        () => BtCheckpointRecord.fromJson({...m, 'offset': 1.5}),
        throwsFormatException,
      );
      expect(() => record(identity(), generation: 256), throwsFormatException);
      expect(
        () => BtCheckpointIdentity.fromJson({
          ...identity().toJson(),
          'role': 'other',
        }),
        throwsA(anything),
      );
    });
    test('hash chain, identity, version and completed cannot regress', () {
      final first = record(identity());
      final active = record(
        identity(),
        generation: 1,
        previous: first.digest,
        offset: 1,
        prefix: sha([1]),
        status: BtCheckpointStatus.active,
      );
      first.validateNext(active);
      final back = record(
        identity(),
        generation: 2,
        previous: active.digest,
        status: BtCheckpointStatus.paused,
      );
      expect(() => active.validateNext(back), throwsStateError);
      final complete = record(
        identity(),
        generation: 2,
        previous: active.digest,
        offset: 3,
        prefix: sha([1, 2, 3]),
        status: BtCheckpointStatus.completed,
        reason: 'local-data-sealed',
      );
      active.validateNext(complete);
      final reopen = record(
        identity(),
        generation: 3,
        previous: complete.digest,
        offset: 3,
        prefix: sha([1, 2, 3]),
        status: BtCheckpointStatus.active,
      );
      expect(() => complete.validateNext(reopen), throwsStateError);
    });
  });
  group('P0 real host filesystem', () {
    test('create/load/reload and zero checkpoint', () async {
      final s = Sandbox();
      await s.init();
      final created = await s.store.createTask(s.task);
      expect(created.record.offset, 0);
      expect(created.record.generation, 0);
      final saved = await s.store.checkpoint(
        s.task,
        offset: 0,
        expectedGeneration: 0,
      );
      expect(saved.record.generation, 1);
      final fresh = BtCheckpointStore(baseDirectory: s.base);
      expect((await fresh.load(s.task)).record.digest, saved.record.digest);
      expect(saved.durabilityContract, contains('file-flush'));
    });
    test(
      'zero-byte source is valid, but local complete is not transfer ACK',
      () async {
        final s = Sandbox();
        await s.init();
        final empty = identity(size: 0, digest: sha([]));
        await s.store.createTask(empty);
        final r = await s.store.checkpoint(
          empty,
          offset: 0,
          expectedGeneration: 0,
          status: BtCheckpointStatus.completed,
          terminalReason: 'local-empty-data-sealed',
        );
        expect(r.record.status, BtCheckpointStatus.completed);
        expect(r.record.toJson().keys, isNot(contains('ack')));
      },
    );
    test('increasing checkpoints, exact end, source preserved', () async {
      final s = Sandbox();
      await s.init();
      final data = await s.filled();
      final a = await s.store.checkpoint(
        s.task,
        offset: 1,
        expectedGeneration: 0,
      );
      final b = await s.store.checkpoint(
        s.task,
        offset: 3,
        expectedGeneration: a.record.generation,
      );
      expect(b.record.generation, 2);
      expect(b.record.prefixSha256, sha([1, 2, 3]));
      expect(await data.readAsBytes(), [1, 2, 3]);
      expect(
        await s.generation(0).exists(),
        isTrue,
      ); // No unique-state overwrite.
    });
    test(
      'duplicate update is idempotent including lost local response retry',
      () async {
        final s = Sandbox();
        await s.init();
        await s.filled();
        final a = await s.store.checkpoint(
          s.task,
          offset: 1,
          expectedGeneration: 0,
        );
        final b = await s.store.checkpoint(
          s.task,
          offset: 1,
          expectedGeneration: 0,
        );
        expect(a.record.digest, b.record.digest);
        expect(b.record.generation, 1);
        expect(await s.generation(2).exists(), isFalse);
      },
    );
    test('task IDs unique even for identical metadata', () async {
      final s = Sandbox();
      await s.init();
      await s.filled();
      await expectLater(s.store.createTask(s.task), error('task_exists'));
    });
    test('negative, beyond file and checkpoint rollback rejected', () async {
      final s = Sandbox();
      await s.init();
      await s.filled();
      for (final n in [-1, 4]) {
        await expectLater(
          s.store.checkpoint(s.task, offset: n, expectedGeneration: 0),
          error('offset_regression_or_range'),
        );
      }
      await s.store.checkpoint(s.task, offset: 2, expectedGeneration: 0);
      await expectLater(
        s.store.checkpoint(s.task, offset: 1, expectedGeneration: 1),
        error('offset_regression_or_range'),
      );
      expect((await s.store.load(s.task)).record.offset, 2);
    });
    for (final field in [
      'peer',
      'local',
      'size',
      'sha',
      'name',
      'source',
      'role',
    ]) {
      test('identity mismatch $field rejects checkpoint', () async {
        final s = Sandbox();
        await s.init();
        await s.filled();
        final m = s.task.toJson();
        switch (field) {
          case 'peer':
            m['peer'] = 'c' * 64;
          case 'local':
            m['local'] = 'c' * 64;
          case 'size':
            m['size'] = 4;
          case 'sha':
            m['sha256'] = 'c' * 64;
          case 'name':
            m['name'] = 'other.txt';
          case 'source':
            m['sourceBinding'] = 'c' * 32;
          case 'role':
            m['role'] = 'sender';
            m['sourceBinding'] = 'c' * 32;
        }
        final wrong = BtCheckpointIdentity.fromJson(m);
        await expectLater(s.store.load(wrong), error('identity_mismatch'));
      });
    }
    test('different task cannot claim same file binding', () async {
      final s = Sandbox();
      await s.init();
      await s.filled();
      await expectLater(
        s.store.load(identity(id: '2' * 32)),
        error('unsafe_directory'),
      );
    });
    for (final change in [
      'truncated',
      'checksum',
      'schema',
      'missing',
      'route',
      'generation',
      'extra',
    ]) {
      test('corrupt/unsupported record $change never falls back', () async {
        final s = Sandbox();
        await s.init();
        await s.filled();
        await s.store.checkpoint(s.task, offset: 1, expectedGeneration: 0);
        final f = s.generation(1);
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final r = m['record'] as Map<String, dynamic>;
        switch (change) {
          case 'truncated':
            await f.writeAsString('{');
          case 'checksum':
            m['sha256'] = '0' * 64;
            await f.writeAsString(jsonEncode(m));
          case 'schema':
            r['schema'] = 'future';
            await f.writeAsString(jsonEncode(m));
          case 'missing':
            r.remove('offset');
            await f.writeAsString(jsonEncode(m));
          case 'route':
            (r['identity'] as Map)['transport'] = 'lan';
            await f.writeAsString(jsonEncode(m));
          case 'generation':
            r['generation'] = 9;
            await f.writeAsString(jsonEncode(m));
          case 'extra':
            r['unknown'] = 'x';
            await f.writeAsString(jsonEncode(m));
        }
        await expectLater(
          s.store.load(s.task),
          throwsA(isA<BtCheckpointException>()),
        );
        expect(await s.generation(0).exists(), isTrue);
      });
    }
    test('missing generation is not an implicit reset', () async {
      final s = Sandbox();
      await s.init();
      await s.filled();
      await s.store.checkpoint(s.task, offset: 1, expectedGeneration: 0);
      await s.store.checkpoint(s.task, offset: 2, expectedGeneration: 1);
      await s.generation(1).delete();
      await expectLater(s.store.load(s.task), error('record_gap_or_oversize'));
    });
    test('shorter file and modified confirmed prefix are rejected', () async {
      final s = Sandbox();
      await s.init();
      final f = await s.filled();
      await s.store.checkpoint(s.task, offset: 2, expectedGeneration: 0);
      await f.writeAsBytes([1]);
      await expectLater(s.store.load(s.task), error('data_length_mismatch'));
      await f.writeAsBytes([9, 2, 3]);
      await expectLater(s.store.load(s.task), error('data_prefix_mismatch'));
      expect(await f.exists(), isTrue);
    });
    test('unconfirmed suffix is not counted or truncated', () async {
      final s = Sandbox();
      await s.init();
      final f = await s.filled();
      final r = await s.store.checkpoint(
        s.task,
        offset: 1,
        expectedGeneration: 0,
      );
      expect(r.record.offset, 1);
      expect(await f.length(), 3);
      expect((await s.store.load(s.task)).record.offset, 1);
    });
    test('received count cannot save data not actually written', () async {
      final s = Sandbox();
      await s.init();
      await s.store.createTask(s.task);
      await expectLater(
        s.store.checkpoint(s.task, offset: 3, expectedGeneration: 0),
        error('data_length_mismatch'),
      );
      expect((await s.store.load(s.task)).record.offset, 0);
    });
    test('whole SHA mismatch cannot produce end checkpoint', () async {
      final s = Sandbox();
      await s.init();
      final wrong = identity(digest: 'c' * 64);
      await s.store.createTask(wrong);
      final f = await s.store.dataFile(wrong);
      await f.writeAsBytes([1, 2, 3]);
      await expectLater(
        s.store.checkpoint(wrong, offset: 3, expectedGeneration: 0),
        error('whole_sha256_mismatch'),
      );
      expect((await s.store.load(wrong)).record.offset, 0);
    });
    for (final target in [
      BtCheckpointStatus.cancelled,
      BtCheckpointStatus.failed,
      BtCheckpointStatus.expired,
    ]) {
      test('terminal $target never deletes data or allows reopening', () async {
        final s = Sandbox();
        await s.init();
        final f = await s.filled();
        await s.store.checkpoint(
          s.task,
          offset: 0,
          expectedGeneration: 0,
          status: target,
          terminalReason: 'explicit-local-terminal',
        );
        await expectLater(
          s.store.checkpoint(s.task, offset: 1, expectedGeneration: 1),
          error('terminal_task'),
        );
        expect(await f.readAsBytes(), [1, 2, 3]);
      });
    }
    test(
      'completed cannot become failed/cancelled/active and unrelated file stays',
      () async {
        final s = Sandbox();
        await s.init();
        final f = await s.filled();
        final old = await File(
          '${s.base.path}/already_received.txt',
        ).writeAsString('KEEP');
        await s.store.checkpoint(
          s.task,
          offset: 3,
          expectedGeneration: 0,
          status: BtCheckpointStatus.completed,
          terminalReason: 'local-data-sealed',
        );
        for (final target in [
          BtCheckpointStatus.active,
          BtCheckpointStatus.cancelled,
          BtCheckpointStatus.failed,
        ]) {
          await expectLater(
            s.store.checkpoint(
              s.task,
              offset: 3,
              expectedGeneration: 1,
              status: target,
              terminalReason: target.isTerminal ? 'not-permitted' : null,
            ),
            error('terminal_task'),
          );
        }
        expect(await old.readAsString(), 'KEEP');
        expect(await f.readAsBytes(), [1, 2, 3]);
      },
    );
    test(
      'concurrent identical requests across instances write one generation',
      () async {
        final s = Sandbox();
        await s.init();
        await s.filled();
        final other = BtCheckpointStore(baseDirectory: s.base);
        final rs = await Future.wait(
          List.generate(
            8,
            (i) => (i.isEven ? s.store : other).checkpoint(
              s.task,
              offset: 1,
              expectedGeneration: 0,
            ),
          ),
        );
        expect(rs.map((r) => r.record.digest).toSet().length, 1);
        expect(await s.generation(2).exists(), isFalse);
      },
    );
    test(
      'concurrent different requests use generation compare-and-set',
      () async {
        final s = Sandbox();
        await s.init();
        await s.filled();
        final rs = await Future.wait(
          [1, 2].map(
            (n) => s.store
                .checkpoint(s.task, offset: n, expectedGeneration: 0)
                .then<Object>((v) => v, onError: (Object e) => e),
          ),
        );
        expect(rs.whereType<BtPersistedCheckpoint>().length, 1);
        expect(rs.whereType<BtCheckpointException>().length, 1);
        expect((await s.store.load(s.task)).record.generation, 1);
      },
    );
    test('stale external lock is not deleted or guessed stale', () async {
      final s = Sandbox();
      await s.init();
      await s.filled();
      final f = await File(
        '${s.root.path}/.writer_lock',
      ).writeAsString('unknown-owner');
      await expectLater(s.store.load(s.task), error('busy_or_stale_lock'));
      expect(await f.readAsString(), 'unknown-owner');
    });
    test('bounded namespace task quota', () async {
      final s = Sandbox();
      await s.init();
      for (var i = 1; i <= 4; i++) {
        await s.store.createTask(identity(id: i.toString().padLeft(32, '0')));
      }
      await expectLater(
        s.store.createTask(identity(id: '5' * 32)),
        error('task_quota'),
      );
    });
    test(
      'metadata quota rejects oversize without allocating file data',
      () async {
        final s = Sandbox();
        await s.init();
        await s.filled();
        await s.generation(0).writeAsBytes(List.filled(8193, 0));
        await expectLater(
          s.store.load(s.task),
          error('record_gap_or_oversize'),
        );
      },
    );
    test(
      '10MiB data verified by bounded streaming, not a file-wide list',
      () async {
        final s = Sandbox();
        await s.init();
        final seed = File('${s.base.path}/source.bin');
        final writer = await seed.open(mode: FileMode.writeOnly);
        final block = List.generate(65536, (i) => i % 251);
        try {
          for (var i = 0; i < 160; i++) {
            await writer.writeFrom(block);
          }
          await writer.flush();
        } finally {
          await writer.close();
        }
        final digest = (await hashes.sha256.bind(seed.openRead()).first)
            .toString();
        final task = identity(size: 10485760, digest: digest);
        await s.store.createTask(task);
        final f = await s.store.dataFile(task);
        await seed.openRead().pipe(f.openWrite());
        final r = await s.store.checkpoint(
          task,
          offset: 10485760,
          expectedGeneration: 0,
        );
        expect(r.record.prefixSha256, digest);
        expect((await s.store.load(task)).record.offset, 10485760);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
  test(
    'P0 cooperating separate isolate cannot bypass active writer lock',
    () async {
      var armed = false;
      final entered = Completer<void>();
      final release = Completer<void>();
      final s = Sandbox();
      await s.init(
        fault: (point) async {
          if (armed && point == BtCheckpointFaultPoint.afterDataVerified) {
            entered.complete();
            await release.future;
          }
        },
      );
      await s.filled();
      final basePath = s.base.path;
      final taskJson = s.task.toJson();
      armed = true;
      final writing = s.store.checkpoint(
        s.task,
        offset: 1,
        expectedGeneration: 0,
      );
      await entered.future;
      try {
        final code = await loadFromSeparateIsolate(basePath, taskJson);
        expect(code, 'busy_or_stale_lock');
      } finally {
        release.complete();
        await writing;
      }
      expect((await s.store.load(s.task)).record.generation, 1);
    },
  );
  group('P0 injected IO failures (NOT hardware power failures)', () {
    for (final point in BtCheckpointFaultPoint.values) {
      test(
        'failure at $point never returns new persisted checkpoint',
        () async {
          var armed = false;
          final s = Sandbox();
          await s.init(
            fault: (p) async {
              if (armed && p == point) {
                throw const FileSystemException(
                  'injected ENOSPC',
                  '',
                  OSError('ENOSPC', 28),
                );
              }
            },
          );
          await s.filled();
          final original = await s.generation(0).readAsString();
          armed = true;
          await expectLater(
            s.store.checkpoint(s.task, offset: 1, expectedGeneration: 0),
            error('io_failure'),
          );
          expect(await s.generation(0).readAsString(), original);
          armed = false;
          if (point.index >=
              BtCheckpointFaultPoint.afterTransactionBegin.index) {
            await expectLater(
              s.store.load(s.task),
              error('unsettled_transaction'),
            );
          } else {
            expect((await s.store.load(s.task)).record.generation, 0);
          }
        },
      );
    }
    test(
      'data flushed/verified before metadata; final data mismatch rejects publication',
      () async {
        var armed = false;
        File? data;
        final seen = <BtCheckpointFaultPoint>[];
        final s = Sandbox();
        await s.init(
          fault: (p) async {
            if (!armed) return;
            seen.add(p);
            if (p == BtCheckpointFaultPoint.afterDataFlush) {
              expect(await s.generation(1).exists(), isFalse);
            }
            if (p == BtCheckpointFaultPoint.afterPublish) {
              await data!.writeAsBytes([9, 2, 3], flush: true);
            }
          },
        );
        data = await s.filled();
        armed = true;
        await expectLater(
          s.store.checkpoint(s.task, offset: 1, expectedGeneration: 0),
          error('data_prefix_mismatch'),
        );
        expect(
          seen.indexOf(BtCheckpointFaultPoint.afterDataVerified),
          lessThan(seen.indexOf(BtCheckpointFaultPoint.afterRecordWrite)),
        );
        armed = false;
        await expectLater(s.store.load(s.task), error('unsettled_transaction'));
      },
    );
    test('confirmed prefix cannot change during data-flush window', () async {
      var armed = false;
      File? data;
      final s = Sandbox();
      await s.init(
        fault: (p) async {
          if (armed && p == BtCheckpointFaultPoint.afterDataFlush) {
            await data!.writeAsBytes([9, 2, 3]);
          }
        },
      );
      data = await s.filled();
      await s.store.checkpoint(s.task, offset: 1, expectedGeneration: 0);
      armed = true;
      await expectLater(
        s.store.checkpoint(s.task, offset: 2, expectedGeneration: 1),
        error('data_prefix_mismatch'),
      );
      expect(await s.generation(2).exists(), isFalse);
    });
  });
}
