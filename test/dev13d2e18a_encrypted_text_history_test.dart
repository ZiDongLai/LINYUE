import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'package:nearlink/services/encrypted_text_history_store.dart';

void main() {
  late Directory root;
  final key = List<int>.generate(32, (i) => i + 1);

  setUp(() async => root = await Directory.systemTemp.createTemp('linyue_e18a_'));
  tearDown(() async { if (await root.exists()) await root.delete(recursive: true); });

  EncryptedTextHistoryStore store([List<int>? secret, int max = 500]) =>
      EncryptedTextHistoryStore(directory: root, encryptionKey: secret ?? key,
          maxMessagesPerPeer: max);

  test('E18-A encrypted content survives app instance restart, Unicode retained', () async {
    final original = TextChatMessage.create('中文 😀\nEnglish');
    expect(await store().saveConfirmed(
      authenticatedFingerprint: 'signed-peer-1', message: original, outbound: true), isTrue);
    final files = root.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(utf8.decode(await files.single.readAsBytes()).contains('中文'), isFalse);
    final reloaded = await store().loadPeer('signed-peer-1');
    expect(reloaded.single.message.id, original.id);
    expect(reloaded.single.message.body, original.body);
    expect(reloaded.single.outbound, isTrue);
  });

  test('E18-A identity-scoped histories never mix, duplicate ID idempotent', () async {
    final msg = TextChatMessage.create('same id');
    expect(await store().saveConfirmed(authenticatedFingerprint: 'peer-A',
        message: msg, outbound: false), isTrue);
    expect(await store().saveConfirmed(authenticatedFingerprint: 'peer-A',
        message: msg, outbound: false), isFalse);
    expect(await store().loadPeer('peer-B'), isEmpty);
    expect(await store().saveConfirmed(authenticatedFingerprint: 'peer-B',
        message: msg, outbound: true), isTrue);
    expect((await store().loadPeer('peer-A')).single.outbound, isFalse);
    expect((await store().loadPeer('peer-B')).single.outbound, isTrue);
  });

  test('E18-A wrong key or tampered ciphertext fails closed without erasure', () async {
    final msg = TextChatMessage.create('private text');
    await store().saveConfirmed(authenticatedFingerprint: 'peer-A',
        message: msg, outbound: false);
    expect(store(List<int>.filled(32, 77)).loadPeer('peer-A'), throwsFormatException);
    final file = root.listSync().whereType<File>().single;
    final envelope = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final ciphertext = envelope['ciphertext'] as String;
    envelope['ciphertext'] = '${ciphertext[0] == 'A' ? 'B' : 'A'}${ciphertext.substring(1)}';
    await file.writeAsString(jsonEncode(envelope), flush: true);
    final before = await file.readAsBytes();
    expect(store().loadPeer('peer-A'), throwsFormatException);
    expect(await file.readAsBytes(), before);
    expect(store().clearPeer('peer-A'), throwsFormatException);
  });

  test('E18-A deleting and clearing text does not delete other peer', () async {
    final a = TextChatMessage.create('A');
    final b = TextChatMessage.create('B');
    await store().saveConfirmed(authenticatedFingerprint: 'peer-A',message:a,outbound:true);
    await store().saveConfirmed(authenticatedFingerprint: 'peer-A',message:b,outbound:false);
    await store().saveConfirmed(authenticatedFingerprint: 'peer-B',message:a,outbound:false);
    expect(await store().deleteMessages(
      authenticatedFingerprint:'peer-A',messageIds:{a.id}), 1);
    expect((await store().loadPeer('peer-A')).single.message.body, 'B');
    await store().clearPeer('peer-A');
    expect(await store().loadPeer('peer-A'), isEmpty);
    expect(await store().loadPeer('peer-B'), hasLength(1));
    expect(await store().loadPeer('peer-A'), isEmpty);
  });

  test('E18-A concurrent inserts are serialized and bounded', () async {
    final s = store(null, 3);
    await Future.wait(List.generate(7, (n) => s.saveConfirmed(
      authenticatedFingerprint: 'peer-A',
      message: TextChatMessage.create('entry $n'), outbound: true)));
    final entries = await s.loadPeer('peer-A');
    expect(entries, hasLength(3));
    expect(entries.map((e) => e.message.body), ['entry 4', 'entry 5', 'entry 6']);
  });

  test('E18-A recovers last committed state when replacement was interrupted', () async {
    final msg = TextChatMessage.create('before interruption');
    await store().saveConfirmed(authenticatedFingerprint: 'peer-A',
        message: msg, outbound: true);
    final primary = root.listSync().whereType<File>().single;
    final backup = File(primary.path.replaceFirst('.enc', '.previous'));
    await primary.rename(backup.path);
    final incomplete = File(primary.path.replaceFirst('.enc', '.pending'));
    await incomplete.writeAsString('incomplete write', flush: true);
    final recovered = await store().loadPeer('peer-A');
    expect(recovered.single.message.body, 'before interruption');
    expect(await backup.exists(), isTrue);
  });

  test('E18-A missing identity and invalid encryption key are rejected', () async {
    expect(() => store(List<int>.filled(31, 0)), throwsArgumentError);
    expect(store().loadPeer(' '), throwsFormatException);
    expect(store().saveConfirmed(authenticatedFingerprint: '',
      message: TextChatMessage.create('invalid'),outbound: false),throwsFormatException);
  });
}
