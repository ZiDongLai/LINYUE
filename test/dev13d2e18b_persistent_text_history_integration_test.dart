import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'package:nearlink/services/encrypted_text_history_runtime.dart';

class _MemoryVault implements IdentityVault {
  final Map<String, String> values = {};
  bool failRead = false;
  bool failWrite = false;

  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('vault read denied');
    return values[key];
  }
  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('vault write denied');
    values[key] = value;
  }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

void main() {
  late Directory root;
  late _MemoryVault vault;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linyue_e18b_');
    vault = _MemoryVault();
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('E18-B secure vault key is created once and history survives runtime restart', () async {
    final runtime = EncryptedTextHistoryRuntime(vault: vault, directory: root);
    final store = await runtime.initialize();
    final message = TextChatMessage.create('持久化文字 😀\nline 2');
    await store.saveConfirmed(authenticatedFingerprint: 'peer-fingerprint-A',
        message: message, outbound: true);
    final savedKeyCount = vault.values.length;
    final restarted = EncryptedTextHistoryRuntime(vault: vault, directory: root);
    final loaded = await (await restarted.initialize()).loadPeer('peer-fingerprint-A');
    expect(loaded, hasLength(1));
    expect(loaded.single.message.body, message.body);
    expect(loaded.single.message.id, message.id);
    expect(vault.values.length, savedKeyCount);
  });

  test('E18-B lost key with existing history fails closed and does not mint a new key', () async {
    final runtime = EncryptedTextHistoryRuntime(vault: vault, directory: root);
    final msg = TextChatMessage.create('keep encrypted history');
    await (await runtime.initialize()).saveConfirmed(
        authenticatedFingerprint: 'peer-fingerprint-A', message: msg, outbound: false);
    vault.values.clear();
    final before = root.listSync().whereType<File>().single.readAsBytesSync();
    final restarted = EncryptedTextHistoryRuntime(vault: vault, directory: root);
    await expectLater(restarted.initialize(), throwsStateError);
    expect(vault.values, isEmpty);
    expect(root.listSync().whereType<File>().single.readAsBytesSync(), before);
  });

  test('E18-B malformed secure key is not silently replaced', () async {
    vault.values['linyue.dev13d2e18.text-history.aes256gcm.v1'] = 'not-a-key';
    final runtime = EncryptedTextHistoryRuntime(vault: vault, directory: root);
    await expectLater(runtime.initialize(), throwsStateError);
    expect(vault.values['linyue.dev13d2e18.text-history.aes256gcm.v1'], 'not-a-key');
  });

  test('E18-B unavailable secure vault blocks initialization', () async {
    vault.failRead = true;
    final runtime = EncryptedTextHistoryRuntime(vault: vault, directory: root);
    await expectLater(runtime.initialize(), throwsStateError);
  });
}
