import 'dart:convert';
import 'dart:io';

import '../security/device_identity.dart';
import '../security/secure_core.dart' show secureRandomBytes;
import 'encrypted_text_history_store.dart';

/// DEV13D2E18-B: binds the E18-A encrypted history store to the OS secure vault.
/// The AES key is never written beside the encrypted message database.
final class EncryptedTextHistoryRuntime {
  EncryptedTextHistoryRuntime({required this.vault, required this.directory});

  static const String _keyName = 'linyue.dev13d2e18.text-history.aes256gcm.v1';

  final IdentityVault vault;
  final Directory directory;
  EncryptedTextHistoryStore? _store;
  Future<EncryptedTextHistoryStore>? _initializing;

  bool get isInitialized => _store != null;

  EncryptedTextHistoryStore get store {
    final value = _store;
    if (value == null) throw StateError('Encrypted text history is not initialized');
    return value;
  }

  Future<EncryptedTextHistoryStore> initialize() {
    final existing = _store;
    if (existing != null) return Future.value(existing);
    return _initializing ??= _initializeOnce();
  }

  Future<EncryptedTextHistoryStore> _initializeOnce() async {
    final key = await _loadOrCreateKey();
    final created = EncryptedTextHistoryStore(directory: directory, encryptionKey: key);
    _store = created;
    return created;
  }

  Future<List<int>> _loadOrCreateKey() async {
    final saved = await vault.read(_keyName);
    if (saved != null) {
      late final List<int> key;
      try {
        key = base64Url.decode(saved);
      } catch (_) {
        throw StateError('本机聊天历史密钥格式损坏，禁止自动替换');
      }
      if (key.length != 32) {
        throw StateError('本机聊天历史密钥长度异常，禁止自动替换');
      }
      return key;
    }

    // A missing key alongside existing history means key loss, not a fresh install.
    if (await directory.exists()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File && RegExp(r'^peer_[0-9a-f]{64}\.(enc|previous|pending)$')
            .hasMatch(entity.uri.pathSegments.last)) {
          throw StateError('发现本机加密聊天历史但安全密钥缺失，禁止生成替代密钥或覆盖记录');
        }
      }
    }

    final key = secureRandomBytes(32);
    final encoded = base64Url.encode(key);
    await vault.write(_keyName, encoded);
    final verified = await vault.read(_keyName);
    if (verified != encoded) {
      throw StateError('本机聊天历史密钥无法安全回读，已停止文字收发');
    }
    return key;
  }
}
