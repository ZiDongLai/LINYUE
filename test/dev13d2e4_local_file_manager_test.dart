import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/local_received_file_manager.dart';
import 'package:nearlink/services/transfer_history.dart';

void main() {
  group('DEV13-D2E4 local received-file management', () {
    test('rename streams bytes, removes old name, and preserves content', () async {
      final root = await Directory.systemTemp.createTemp('linyue_d2e4_rename_');
      addTearDown(() async => root.delete(recursive: true));
      final receive = await Directory('${root.path}${Platform.pathSeparator}receive').create();
      final original = File('${receive.path}${Platform.pathSeparator}source.bin');
      final bytes = List<int>.generate(512 * 1024, (i) => (i * 17) % 251);
      await original.writeAsBytes(bytes, flush: true);

      final renamed = await LocalReceivedFileManager.renameReceivedFile(
        file: original,
        receiveDirectory: receive,
        newName: 'renamed.bin',
      );

      expect(renamed.uri.pathSegments.last, 'renamed.bin');
      expect(await renamed.readAsBytes(), bytes);
      expect(await original.exists(), isFalse);
      print('[DEV13-D2E4] RENAME_BYTES_PRESERVED_PASS');
    });

    test('existing target is never overwritten', () async {
      final root = await Directory.systemTemp.createTemp('linyue_d2e4_collision_');
      addTearDown(() async => root.delete(recursive: true));
      final receive = await Directory('${root.path}${Platform.pathSeparator}receive').create();
      final source = File('${receive.path}${Platform.pathSeparator}source.txt');
      final target = File('${receive.path}${Platform.pathSeparator}target.txt');
      await source.writeAsString('source bytes');
      await target.writeAsString('keep existing bytes');

      await expectLater(
        LocalReceivedFileManager.renameReceivedFile(
          file: source,
          receiveDirectory: receive,
          newName: 'target.txt',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await source.readAsString(), 'source bytes');
      expect(await target.readAsString(), 'keep existing bytes');
      print('[DEV13-D2E4] NO_OVERWRITE_PASS');
    });

    test('delete removes only a direct received file', () async {
      final root = await Directory.systemTemp.createTemp('linyue_d2e4_delete_');
      addTearDown(() async => root.delete(recursive: true));
      final receive = await Directory('${root.path}${Platform.pathSeparator}receive').create();
      final received = File('${receive.path}${Platform.pathSeparator}received.pdf');
      final outside = File('${root.path}${Platform.pathSeparator}outside.pdf');
      await received.writeAsBytes(<int>[1, 2, 3, 4]);
      await outside.writeAsBytes(<int>[9, 8, 7]);

      await expectLater(
        LocalReceivedFileManager.deleteReceivedFile(file: outside, receiveDirectory: receive),
        throwsA(isA<FileSystemException>()),
      );
      expect(await outside.exists(), isTrue);
      await LocalReceivedFileManager.deleteReceivedFile(file: received, receiveDirectory: receive);
      expect(await received.exists(), isFalse);
      expect(await outside.readAsBytes(), <int>[9, 8, 7]);
      print('[DEV13-D2E4] DELETE_ROOT_GUARD_PASS');
    });

    test('deleting local copy leaves transfer history intact', () async {
      final root = await Directory.systemTemp.createTemp('linyue_d2e4_history_');
      addTearDown(() async => root.delete(recursive: true));
      final receive = await Directory('${root.path}${Platform.pathSeparator}receive').create();
      final received = File('${receive.path}${Platform.pathSeparator}kept-history.txt');
      await received.writeAsString('local copy');
      final store = TransferHistoryStore(customDirectory: root);
      await store.load();
      await store.append(TransferRecord(
        name: 'kept-history.txt', peerName: 'Windows', direction: 'receive',
        status: 'success', bytes: 10, timestamp: DateTime.utc(2026, 10, 19),
        localPath: received.path,
      ));

      await LocalReceivedFileManager.deleteReceivedFile(
        file: received, receiveDirectory: receive);
      expect(await received.exists(), isFalse);
      expect(store.records, hasLength(1));
      expect(store.records.single.name, 'kept-history.txt');
      expect(store.records.single.localPath, received.path);
      final reopened = TransferHistoryStore(customDirectory: root);
      await reopened.load();
      expect(reopened.records, hasLength(1));
      expect(reopened.records.single.localPath, received.path);
      print('[DEV13-D2E4] DELETE_HISTORY_RETAINED_PASS');
    });

    test('invalid names and missing files fail closed', () async {
      final root = await Directory.systemTemp.createTemp('linyue_d2e4_invalid_');
      addTearDown(() async => root.delete(recursive: true));
      final receive = await Directory('${root.path}${Platform.pathSeparator}receive').create();
      final source = File('${receive.path}${Platform.pathSeparator}source.txt');
      await source.writeAsString('safe');

      await expectLater(
        LocalReceivedFileManager.renameReceivedFile(
          file: source, receiveDirectory: receive, newName: '../escape.txt'),
        throwsA(isA<FormatException>()),
      );
      await source.delete();
      await expectLater(
        LocalReceivedFileManager.deleteReceivedFile(file: source, receiveDirectory: receive),
        throwsA(isA<FileSystemException>()),
      );
      print('[DEV13-D2E4] INVALID_AND_MISSING_FAIL_CLOSED_PASS');
    });
  });
}
