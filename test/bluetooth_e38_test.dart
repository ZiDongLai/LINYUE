import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_file_policy.dart';
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';
import 'package:nearlink/bluetooth/bluetooth_file_results.dart';
import 'package:nearlink/bluetooth/bluetooth_source_stage.dart';
import 'bluetooth_e36_test.dart' show aPeer, bPeer;
import 'bluetooth_e37_test.dart' show ExpansionWire, sourceFile, digest;

Future<ExpansionWire> formalWire({bool negotiateSize = true}) async {
  final w = ExpansionWire();
  await w.init(); // Production store default; no E37 opt-in or explicit max.
  expect(w.aStore.maxBytes, 10485760);
  expect(w.bStore.maxBytes, 10485760);
  if (negotiateSize) {
    for (final p in [(w.a, w.b), (w.b, w.a)]) {
      p.$1.observeSize(p.$2.sizeCapability);
      p.$1.confirmSize(p.$2.sizeCapability, p.$1.sizeCapability);
    }
  }
  return w;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'E38 formal default independent of E37 Debug flag; fallback stays legacy',
    () async {
      expect(bluetoothBuildFileLimit(), 10485760);
      expect(bluetoothFileMaxBytes, 1048576); // E36 wire, NOT local default.
      final w = await formalWire(negotiateSize: false);
      expect(w.a.maxFileBytes, 1048576);
      expect(w.b.maxFileBytes, 1048576);
      final tooLarge = await sourceFile(w.root, 1048577);
      await expectLater(w.a.send(tooLarge), throwsStateError);
      await expectLater(w.b.send(tooLarge), throwsStateError);
      expect(w.sent, isEmpty);
    },
  );
  for (final reverse in [false, true]) {
    test(
      'E38 default stores real file/receipt/history 10MiB reverse=$reverse',
      () async {
        final w = await formalWire();
        expect(w.a.maxFileBytes, 10485760);
        expect(w.b.maxFileBytes, 10485760);
        final f = await sourceFile(w.root, 10485760);
        final offer = await w.transfer(f, reverse: reverse);
        final history = reverse ? w.aHistory : w.bHistory;
        final saved = File(history.records.single.localPath!);
        expect(await saved.length(), 10485760);
        expect(await digest(saved), await digest(f));
        expect(w.commitCount, 1);
        expect(w.finalReplies.length, 1);
        // No opt-in needed to read a >1MiB E37 completion record in E38.
        final store = reverse ? w.aStore : w.bStore;
        final reloaded = await BluetoothFileResults(
          store.work,
          store.inbox,
        ).load(reverse ? bPeer : aPeer, offer.id);
        expect(reloaded?.phase, 'ackQueued');
        expect(reloaded?.offer.size, 10485760);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
    test('E38 actual PNG183001 both roles reverse=$reverse', () async {
      final w = await formalWire();
      final input = await File(
        'test/fixtures/e38_183001.png',
      ).copy('${w.root.path}/中文图片.png');
      expect(await input.length(), 183001);
      final receipt = await w.transfer(input, reverse: reverse);
      final h = reverse ? w.aHistory : w.bHistory;
      final saved = File(h.records.single.localPath!);
      expect(receipt.name, '中文图片.png');
      expect(
        await digest(saved),
        '48dd45ebf02483ecc78892da910c3827a9706ed68a0a7abbb0042a29e5676369',
      );
      final stream = await saved.open();
      expect(await stream.read(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      await stream.close();
      expect(w.commitCount, 1);
    });
  }
  test(
    'E38 source snapshot streams 10MiB using negotiated local default',
    () async {
      final w = await formalWire();
      final input = await sourceFile(w.root, 10485760);
      final snapshot = await BluetoothSourceStage.create(
        root: Directory('${w.root.path}/snapshot'),
        name: '来源.bin',
        declaredSize: 10485760,
        read: input.openRead,
        maxBytes: bluetoothBuildFileLimit(),
      );
      expect(await digest(snapshot.file), await digest(input));
      await snapshot.dispose();
      expect(await snapshot.file.exists(), isFalse);
    },
  );
  test('E38 unknown or unconfirmed extension never raises limit', () async {
    final w = await formalWire();
    w.a.observeSize({'v': 'unknown', 'max': 10485760});
    w.b.confirmSize(w.a.sizeCapability, {
      'v': 'linyue-bt-limit-e37-v1',
      'max': 104857600,
    });
    expect(w.a.maxFileBytes, 1048576);
    expect(w.b.maxFileBytes, 1048576);
    final f = await sourceFile(w.root, 1048577);
    await expectLater(w.a.send(f), throwsStateError);
    await expectLater(w.b.send(f), throwsStateError);
    expect(w.sent, isEmpty);
  });
  test(
    'E38 default stores >10MiB rejected before wire in both directions',
    () async {
      final w = await formalWire();
      final f = await sourceFile(w.root, 10485761);
      await expectLater(w.a.send(f), throwsStateError);
      await expectLater(w.b.send(f), throwsStateError);
      expect(w.sent, isEmpty);
      expect(w.commitCount, 0);
    },
  );
  test('E38 native commit contract requires no candidate flag', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    const android = MethodChannel('nearlink/files');
    const windows = MethodChannel('nearlink/bluetooth_file_commit');
    Future<Object?> handler(MethodCall call) async {
      calls.add(call);
      return {'path': 'completed.bin', 'size': 10485760, 'sha256': 'a' * 64};
    }

    messenger.setMockMethodCallHandler(android, handler);
    messenger.setMockMethodCallHandler(windows, handler);
    addTearDown(() {
      messenger.setMockMethodCallHandler(android, null);
      messenger.setMockMethodCallHandler(windows, null);
    });
    final offer = BluetoothFileOffer(
      id: '1' * 32,
      name: 'a.bin',
      size: 10485760,
      sha256: 'a' * 64,
      maxBytes: bluetoothBuildFileLimit(),
      commitNonce: 'b' * 32,
    );
    await BluetoothFileStore.commitAndroid(File('temp'), offer);
    await BluetoothFileStore.commitWindows(
      File('temp'),
      offer,
      Directory('inbox'),
    );
    expect(calls.length, 2);
    for (final c in calls) {
      final args = c.arguments as Map;
      expect(args['size'], 10485760);
      expect(args['commitNonce'], 'b' * 32);
      expect(args.containsKey('candidate10MiB'), isFalse);
    }
  });
}
