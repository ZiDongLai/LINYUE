import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'package:nearlink/services/encrypted_text_history_store.dart';
import 'package:nearlink/services/live_text_trial_ledger.dart';

void main() {
  late Directory root;
  late EncryptedTextHistoryStore store;
  const peerA = 'authenticated-peer-A';
  const peerB = 'authenticated-peer-B';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linyue_e18c_');
    store = EncryptedTextHistoryStore(
      directory: root,
      encryptionKey: List<int>.generate(32, (i) => i + 1),
    );
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> save(String peer, TextChatMessage msg, bool outgoing) =>
      store.saveConfirmed(
        authenticatedFingerprint: peer, message: msg, outbound: outgoing,
      ).then((_) {});

  test('E18-C local selected deletion retains unselected text and other peer', () async {
    final a = TextChatMessage.create('这条删除');
    final b = TextChatMessage.create('这条保留 😀');
    final c = TextChatMessage.create('另一个设备');
    await save(peerA, a, true);
    await save(peerA, b, false);
    await save(peerB, c, false);
    expect(await store.deleteMessages(
      authenticatedFingerprint: peerA, messageIds: {a.id}), 1);
    final afterA = await store.loadPeer(peerA);
    expect(afterA.map((v) => v.message.id), [b.id]);
    expect((await store.loadPeer(peerB)).single.message.id, c.id);
  });

  test('E18-C clearing one peer does not touch other peer or other files', () async {
    final a = TextChatMessage.create('one');
    final b = TextChatMessage.create('two');
    await save(peerA, a, true);
    await save(peerB, b, false);
    final received = File('${root.path}${Platform.pathSeparator}received_photo.jpg');
    await received.writeAsBytes(List<int>.generate(90, (i) => i));
    final before = await received.readAsBytes();
    await store.clearPeer(peerA);
    expect(await store.loadPeer(peerA), isEmpty);
    expect((await store.loadPeer(peerB)).single.message.id, b.id);
    expect(await received.readAsBytes(), before);
  });

  test('E18-C read verification failure refuses destructive operation', () async {
    final a = TextChatMessage.create('cannot erase tampered history');
    await save(peerA, a, true);
    final encrypted = root.listSync().whereType<File>().single;
    await encrypted.writeAsString('not authenticated json', flush: true);
    final before = await encrypted.readAsBytes();
    expect(store.deleteMessages(
      authenticatedFingerprint: peerA, messageIds: {a.id}), throwsFormatException);
    expect(store.clearPeer(peerA), throwsFormatException);
    expect(await encrypted.readAsBytes(), before);
  });

  test('E18-C ephemeral cache purge is strictly scoped by verified identity', () {
    final cache = LiveTextTrialLedger();
    final a = TextChatMessage.create('a');
    final b = TextChatMessage.create('b');
    cache.recordIncoming(authenticatedFingerprint: peerA, message: a);
    cache.recordOutgoingConfirmed(authenticatedFingerprint: peerB, message: b);
    expect(cache.removePeer(authenticatedFingerprint: peerA), 1);
    expect(cache.snapshot(), hasLength(1));
    expect(cache.snapshot().single.authenticatedFingerprint, peerB);
    expect(() => cache.removePeer(authenticatedFingerprint: '  '), throwsFormatException);
  });

  test('E18-C nonexistent ID is harmless and leaves encrypted history intact', () async {
    final a = TextChatMessage.create('kept');
    final missing = TextChatMessage.create('not present');
    await save(peerA, a, true);
    expect(await store.deleteMessages(authenticatedFingerprint: peerA,
        messageIds: {missing.id}), 0);
    expect((await store.loadPeer(peerA)).single.message.id, a.id);
  });
}
