import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/transfer_history.dart';

void main() {
  test('history roundtrip, clear and reopen', () async {
    final dir = await Directory.systemTemp.createTemp('linyue_history_test_');
    addTearDown(() async { await dir.delete(recursive: true); });
    final store = TransferHistoryStore(customDirectory: dir);
    await store.load();
    await store.append(TransferRecord(
      name: '照片.png',
      peerName: 'Android · 我的手机',
      direction: 'send',
      status: 'success',
      bytes: 12345,
      timestamp: DateTime.utc(2026, 10, 17, 9),
      sourcePath: r'C:\Users\tester\Pictures\照片.png',
      managedShareCopy: true,
    ));
    final reopened = TransferHistoryStore(customDirectory: dir);
    await reopened.load();
    expect(reopened.records, hasLength(1));
    expect(reopened.records.single.name, '照片.png');
    expect(reopened.records.single.bytes, 12345);
    expect(reopened.records.single.direction, 'send');
    expect(reopened.records.single.sourcePath,
      r'C:\Users\tester\Pictures\照片.png');
    expect(reopened.records.single.managedShareCopy, isTrue);
    await reopened.clear();
    final empty = TransferHistoryStore(customDirectory: dir);
    await empty.load();
    expect(empty.records, isEmpty);
  });

  test('renaming a received copy updates only matching receive history', () async {
    final dir = await Directory.systemTemp.createTemp('linyue_history_rename_');
    addTearDown(() async { await dir.delete(recursive: true); });
    final store = TransferHistoryStore(customDirectory: dir);
    await store.load();
    final oldPath = '${dir.path}${Platform.pathSeparator}old.pdf';
    final newPath = '${dir.path}${Platform.pathSeparator}new.pdf';
    final time = DateTime.utc(2026, 10, 19, 12);
    await store.append(TransferRecord(
      name: 'old.pdf', peerName: 'Windows', direction: 'receive',
      status: 'success', bytes: 20, timestamp: time, localPath: oldPath,
    ));
    await store.append(TransferRecord(
      name: 'old.pdf', peerName: 'Android', direction: 'send',
      status: 'success', bytes: 20, timestamp: time, sourcePath: oldPath,
    ));

    await store.renameReceivedFilePath(
      oldPath: oldPath, newPath: newPath, newName: 'new.pdf');

    expect(store.records[1].name, 'new.pdf');
    expect(store.records[1].localPath, newPath);
    expect(store.records[0].name, 'old.pdf');
    expect(store.records[0].sourcePath, oldPath);
    final reopened = TransferHistoryStore(customDirectory: dir);
    await reopened.load();
    expect(reopened.records[1].localPath, newPath);
    expect(reopened.records[1].name, 'new.pdf');
  });

  test('store caps history to 200 records', () async {
    final dir = await Directory.systemTemp.createTemp('linyue_history_cap_');
    addTearDown(() async { await dir.delete(recursive: true); });
    final store = TransferHistoryStore(customDirectory: dir);
    await store.load();
    for (var i = 0; i < 205; i++) {
      await store.append(TransferRecord(
        name: 'file_$i.txt',
        peerName: '测试设备',
        direction: 'receive',
        status: 'success',
        bytes: i,
        timestamp: DateTime.utc(2026, 10, 17),
      ));
    }
    expect(store.records, hasLength(200));
    expect(store.records.first.name, 'file_204.txt');
    expect(store.records.last.name, 'file_5.txt');
  });
}
