import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/transfer_history.dart';
import 'package:nearlink/services/windows_received_drag_out_policy.dart';

void main() {
  late Directory root;
  late Directory sibling;
  late File original;

  TransferRecord record({
    String? path,
    String direction = 'receive',
    String status = 'success',
    int? bytes,
  }) => TransferRecord(
        name: '报告 2026 📷.txt',
        peerName: '已配对设备',
        direction: direction,
        status: status,
        bytes: bytes ?? 12,
        timestamp: DateTime.utc(2026, 10, 20),
        localPath: path ?? original.path,
      );

  setUp(() async {
    final home = await Directory.systemTemp.createTemp('linyue_e20a_');
    root = await Directory('${home.path}${Platform.pathSeparator}recv').create();
    sibling = await Directory('${home.path}${Platform.pathSeparator}recv_extra').create();
    original = File('${root.path}${Platform.pathSeparator}报告 2026 📷.txt');
    await original.writeAsString('hello world!');
  });
  tearDown(() async {
    await root.parent.delete(recursive: true);
  });

  test('completed received original in selected folder can be inspected read-only', () async {
    final before = await original.readAsBytes();
    final result = await WindowsReceivedDragOutPolicy.inspect(
        record: record(), receiveRoot: root);
    expect(result.canDrag, isTrue);
    expect(result.block, isNull);
    expect(result.sizeBytes, before.length);
    expect(result.absolutePath, await original.absolute.resolveSymbolicLinks());
    expect(await original.readAsBytes(), before); // never moves or changes source
  });

  test('sent record and incomplete received record are rejected', () async {
    final sent = await WindowsReceivedDragOutPolicy.inspect(
        record: record(direction: 'send'), receiveRoot: root);
    expect(sent.block, ReceivedDragOutBlock.notReceived);
    final failed = await WindowsReceivedDragOutPolicy.inspect(
        record: record(status: 'failed'), receiveRoot: root);
    expect(failed.block, ReceivedDragOutBlock.notCompleted);
  });

  test('missing path and receive root are rejected', () async {
    final missingPath = await WindowsReceivedDragOutPolicy.inspect(
        record: record(path: ' '), receiveRoot: root);
    expect(missingPath.block, ReceivedDragOutBlock.noLocalPath);
    final missingRoot = await WindowsReceivedDragOutPolicy.inspect(
        record: record(), receiveRoot: null);
    expect(missingRoot.block, ReceivedDragOutBlock.noReceiveRoot);
  });

  test('outside path and sibling directory sharing prefix are rejected', () async {
    final another = File('${sibling.path}${Platform.pathSeparator}another.txt');
    await another.writeAsString('hello world!');
    final result = await WindowsReceivedDragOutPolicy.inspect(
        record: record(path: another.path), receiveRoot: root);
    expect(result.block, ReceivedDragOutBlock.outsideReceiveRoot);
  });

  test('missing original and directories are not draggable', () async {
    await original.delete();
    final missing = await WindowsReceivedDragOutPolicy.inspect(
        record: record(), receiveRoot: root);
    expect(missing.block, ReceivedDragOutBlock.fileMissing);
    final directory = await WindowsReceivedDragOutPolicy.inspect(
        record: record(path: root.path), receiveRoot: root);
    expect(directory.block, ReceivedDragOutBlock.notRegularFile);
  });

  test('changed file size blocks exporting stale transfer record', () async {
    await original.writeAsString('size definitely changed since receipt');
    final result = await WindowsReceivedDragOutPolicy.inspect(
        record: record(), receiveRoot: root);
    expect(result.block, ReceivedDragOutBlock.changedSize);
  });

  test('deleted receive root is invalid and source is never removed', () async {
    final notRoot = Directory('${root.parent.path}${Platform.pathSeparator}not_here');
    final result = await WindowsReceivedDragOutPolicy.inspect(
        record: record(), receiveRoot: notRoot);
    expect(result.block, ReceivedDragOutBlock.invalidReceiveRoot);
    expect(await original.exists(), isTrue);
  });

  test('leaf symlink is rejected when symlinks are supported', () async {
    final link = Link('${root.path}${Platform.pathSeparator}linked.txt');
    try {
      await link.create(original.path);
    } on FileSystemException {
      // Windows machines without symlink creation permission can skip this
      // one platform-specific assertion while running the rest of the suite.
      return;
    }
    final result = await WindowsReceivedDragOutPolicy.inspect(
        record: record(path: link.path), receiveRoot: root);
    expect(result.block, ReceivedDragOutBlock.notRegularFile);
  });
}
