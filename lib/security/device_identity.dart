/// LINYUE DEV4: local identity enrollment, NOT online authenticated pairing.
/// The live HTTP transfer still has no encryption or cryptographic peer check.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'secure_core.dart' show publicKeyFingerprint, secureRandomBytes;

const String _identitySeedKey = 'linyue.dev4.identity.ed25519.seed.v1';
const String _identityPublicKey = 'linyue.dev4.identity.ed25519.public.v1';
const String _trustedKey = 'linyue.dev4.trusted.identities.v1';
const String _cardPrefix = 'LINYUE-ID1:';

/// Injected in unit tests; production uses the OS-specific secure plugin.
abstract class IdentityVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PublicIdentityCard {
  const PublicIdentityCard(this.key);
  final SimplePublicKey key;

  String get fingerprint => publicKeyFingerprint(key);
  String get encoded => '$_cardPrefix${base64Url.encode(key.bytes).replaceAll('=', '')}';

  static PublicIdentityCard parse(String raw) {
    final value = raw.trim();
    if (!value.startsWith(_cardPrefix) || value.length > 160) {
      throw const FormatException('身份卡格式错误（应以 LINYUE-ID1: 开头）');
    }
    final token = value.substring(_cardPrefix.length);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const FormatException('身份卡编码无效');
    }
    final bytes = base64Url.decode(base64Url.normalize(token));
    if (bytes.length != 32) throw const FormatException('公钥长度错误');
    final card = PublicIdentityCard(SimplePublicKey(bytes, type: KeyPairType.ed25519));
    if (card.encoded != value) throw const FormatException('身份卡不是规范编码');
    return card;
  }
}

class SavedIdentity {
  const SavedIdentity({required this.keyPair, required this.publicKey});
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;
  String get fingerprint => publicKeyFingerprint(publicKey);
  String get card => PublicIdentityCard(publicKey).encoded;

  Future<Signature> sign(List<int> challenge) => Ed25519().sign(challenge, keyPair: keyPair);
}

class RegisteredIdentity {
  RegisteredIdentity({required this.name, required this.card, required this.registeredAt});
  final String name;
  final PublicIdentityCard card;
  final DateTime registeredAt;
  String get fingerprint => card.fingerprint;

  Map<String, dynamic> toJson() => {
    'name': name,
    'card': card.encoded,
    'registeredAt': registeredAt.toUtc().toIso8601String(),
  };

  static RegisteredIdentity fromJson(Object? object) {
    if (object is! Map<String, dynamic> || object['name'] is! String ||
        object['card'] is! String || object['registeredAt'] is! String) {
      throw const FormatException('身份登记列表结构损坏');
    }
    final name = (object['name'] as String).trim();
    final registeredAt = DateTime.tryParse(object['registeredAt'] as String);
    if (name.isEmpty || name.length > 40 || registeredAt == null) {
      throw const FormatException('身份登记条目无效');
    }
    return RegisteredIdentity(
      name: name,
      card: PublicIdentityCard.parse(object['card'] as String),
      registeredAt: registeredAt.toUtc(),
    );
  }
}

class DeviceIdentityManager {
  DeviceIdentityManager(this.vault);
  final IdentityVault vault;
  SavedIdentity? _local;
  List<RegisteredIdentity> _entries = [];
  // E30: serialize simultaneous LAN and Bluetooth trust commits. Keep all
  // existing fingerprint validation and storage format unchanged.
  Future<void> _trustUpdates = Future<void>.value();
  Future<void> _updateTrust(Future<void> Function() action) {
    final operation = _trustUpdates.then((_) => action());
    _trustUpdates = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  SavedIdentity get local {
    final value = _local;
    if (value == null) throw StateError('设备身份尚未初始化');
    return value;
  }
  List<RegisteredIdentity> get entries => List.unmodifiable(_entries);

  /// Never silently replace a key whose secure-storage value is corrupted.
  Future<void> initialize() async {
    final seedValue = await vault.read(_identitySeedKey);
    final storedPublic = await vault.read(_identityPublicKey);
    if ((seedValue == null) != (storedPublic == null)) {
      throw StateError('密钥存储不完整，请先备份诊断信息，禁止自动重置设备身份');
    }
    List<int> seed;
    if (seedValue == null) {
      seed = secureRandomBytes(32);
    } else {
      try {
        seed = base64Url.decode(seedValue);
      } catch (_) {
        throw StateError('本机身份私钥读取失败，禁止自动生成替代密钥');
      }
      if (seed.length != 32) throw StateError('本机私钥长度异常，禁止自动重置');
    }
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final public = await keyPair.extractPublicKey();
    final encodedPublic = base64Url.encode(public.bytes);
    if (storedPublic != null && storedPublic != encodedPublic) {
      throw StateError('身份公私钥不匹配，禁止覆盖');
    }
    if (seedValue == null) {
      // Key material is stored only in platform-protected storage.
      await vault.write(_identitySeedKey, base64Url.encode(seed));
      await vault.write(_identityPublicKey, encodedPublic);
    }
    _local = SavedIdentity(keyPair: keyPair, publicKey: public);
    final saved = await vault.read(_trustedKey);
    if (saved == null) {
      _entries = [];
    } else {
      final decoded = jsonDecode(saved);
      if (decoded is! List || decoded.length > 200) {
        throw const FormatException('身份登记列表数据无效');
      }
      final entries = decoded.map(RegisteredIdentity.fromJson).toList();
      final keys = entries.map((e) => e.fingerprint).toSet();
      if (keys.length != entries.length) throw const FormatException('登记列表存在重复公钥');
      _entries = entries;
    }
  }

  Future<void> register({
    required String displayName,
    required String identityCard,
    required String independentlyCheckedFingerprint,
  }) => _updateTrust(() async {
    final name = displayName.trim();
    if (name.isEmpty || name.length > 40 || RegExp(r'[\x00-\x1F]').hasMatch(name)) {
      throw const FormatException('设备备注名称必须为 1～40 个有效字符');
    }
    final card = PublicIdentityCard.parse(identityCard);
    if (card.fingerprint == local.fingerprint) {
      throw StateError('不能把本机身份登记为其他设备');
    }
    // Full fingerprint MUST come from an independent display on the other device.
    if (independentlyCheckedFingerprint.trim().toLowerCase() != card.fingerprint) {
      throw StateError('完整指纹不一致，拒绝登记');
    }
    if (_entries.any((e) => e.fingerprint == card.fingerprint)) {
      throw StateError('此身份已登记，不能重复登记');
    }
    if (_entries.length >= 100) throw StateError('身份登记数量已达到开发版上限');
    final next = [
      ..._entries,
      RegisteredIdentity(name: name, card: card, registeredAt: DateTime.now().toUtc()),
    ];
    await vault.write(_trustedKey, jsonEncode(next.map((e) => e.toJson()).toList()));
    _entries = next;
  });

  Future<void> revoke(String fingerprint) => _updateTrust(() async {
    final next = _entries.where((e) => e.fingerprint != fingerprint).toList();
    if (next.length == _entries.length) throw StateError('指定身份不存在');
    await vault.write(_trustedKey, jsonEncode(next.map((e) => e.toJson()).toList()));
    _entries = next;
  });
}
