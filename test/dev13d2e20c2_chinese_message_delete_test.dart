import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../lib/services/conversation_deletion_policy.dart';
import '../lib/services/transfer_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('E20-C2 incoming file deletion is eligible only for a saved receive', () {
    expect(ConversationDeletionPolicy.canDeleteReceivedCopy(
      direction: 'receive', status: 'success', localPath: r'C:\Received\a.png'), isTrue);
    for (final tuple in <(String, String, String?)>[
      ('send', 'success', r'C:\MyPictures\a.png'),
      ('receive', 'failed', r'C:\Received\a.png'),
      ('receive', 'success', null),
      ('receive', 'success', '   '),
    ]) {
      expect(ConversationDeletionPolicy.canDeleteReceivedCopy(
        direction: tuple.$1, status: tuple.$2, localPath: tuple.$3), isFalse);
    }
    expect(ConversationDeletionPolicy.canRemoveLocalRecord(
      direction: 'send', status: 'failed'), isTrue);
    expect(ConversationDeletionPolicy.canRemoveLocalRecord(
      direction: 'receive', status: 'success'), isTrue);
  });

  test('E20-C2 removing one file bubble preserves both source and received file bytes', () async {
    final root = await Directory.systemTemp.createTemp('linyue_e20c2_record_');
    try {
      final outbound = File('${root.path}${Platform.pathSeparator}sent.txt');
      final inbound = File('${root.path}${Platform.pathSeparator}received.png');
      await outbound.writeAsString('my original source');
      await inbound.writeAsBytes([1, 2, 3, 4]);
      final store = TransferHistoryStore(customDirectory: root);
      await store.load();
      final ts = DateTime.utc(2026, 10, 20, 20, 0);
      final sent = TransferRecord(name: 'sent.txt', peerName: '手机',
          direction: 'send', status: 'success', bytes: 18,
          timestamp: ts, sourcePath: outbound.path);
      final received = TransferRecord(name: 'received.png', peerName: '电脑',
          direction: 'receive', status: 'success', bytes: 4,
          timestamp: ts, localPath: inbound.path);
      await store.append(sent);
      await store.append(received);
      final selected = store.records.firstWhere((r) => r.direction == 'send');
      expect(await store.removeRecord(selected), isTrue);
      expect(await store.removeRecord(selected), isFalse);
      expect(store.records.length, 1);
      expect(store.records.single.name, 'received.png');
      expect(await outbound.readAsString(), 'my original source');
      expect(await inbound.readAsBytes(), [1, 2, 3, 4]);
      final reloaded = TransferHistoryStore(customDirectory: root);
      await reloaded.load();
      expect(reloaded.records.single.name, 'received.png');
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('E20-C2 identical-looking records are not removed by a reconstructed object', () async {
    final root = await Directory.systemTemp.createTemp('linyue_e20c2_identity_');
    try {
      final store = TransferHistoryStore(customDirectory: root);
      await store.load();
      final ts = DateTime.utc(2026, 10, 20);
      TransferRecord record() => TransferRecord(name: 'same.pdf', peerName: 'peer',
          direction: 'receive', status: 'success', bytes: 7, timestamp: ts);
      final first = record();
      final second = record();
      await store.append(first);
      await store.append(second);
      expect(await store.removeRecord(record()), isFalse);
      expect(await store.removeRecord(second), isTrue);
      expect(store.records.length, 1);
      expect(identical(store.records.single, first), isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
