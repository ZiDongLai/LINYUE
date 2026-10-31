// DEV13B3: An authenticated fingerprint is necessary but not sufficient for
// automatic receiving. A human must first authorize this exact identity.
// Grants live in the platform identity vault, not beside untrusted files.
import 'dart:convert';
import 'device_identity.dart';

const String _trustedAutoReceiveKey = 'linyue.dev13.trusted.auto.receive.v1';
final RegExp _fingerprintPattern = RegExp(r'^[a-f0-9]{64}$');

class TrustedAutoReceivePolicy {
  TrustedAutoReceivePolicy(this._vault);
  final IdentityVault _vault;
  bool _ready = false;
  bool _enabled = true;
  final Set<String> _authorized = <String>{};

  bool get ready => _ready;
  bool get enabled => _enabled;
  int get authorizedCount => _authorized.length;

  static bool isFingerprint(String value) => _fingerprintPattern.hasMatch(value);

  Future<void> load() async {
    // Fail closed: if read/JSON parsing fails, do not authorize any peer.
    _ready = false;
    _authorized.clear();
    _enabled = true;
    final raw = await _vault.read(_trustedAutoReceiveKey);
    if (raw != null) {
      if (raw.length > 4096) throw const FormatException('自动接收授权记录过大');
      final doc = jsonDecode(raw);
      if (doc is! Map<String, dynamic> || doc['version'] != 1 ||
          doc['enabled'] is! bool || doc['fingerprints'] is! List) {
        throw const FormatException('自动接收授权记录格式错误');
      }
      final values = doc['fingerprints'] as List<dynamic>;
      if (values.length > 40 || values.any((f) => f is! String || !isFingerprint(f))) {
        throw const FormatException('自动接收授权设备列表损坏');
      }
      if (values.toSet().length != values.length) {
        throw const FormatException('自动接收授权设备列表重复');
      }
      _enabled = doc['enabled'] as bool;
      _authorized.addAll(values.cast<String>());
    }
    _ready = true;
  }

  bool mayAutoAccept(String fingerprint, {
    required bool authenticatedRegisteredIdentity,
    required bool receivingAllowed,
  }) => _ready && _enabled && receivingAllowed &&
      authenticatedRegisteredIdentity && isFingerprint(fingerprint) &&
      _authorized.contains(fingerprint);

  Future<void> grant(String fingerprint) async {
    if (!isFingerprint(fingerprint)) throw ArgumentError.value(fingerprint, 'fingerprint');
    final next = {..._authorized, fingerprint};
    if (next.length > 40) throw StateError('自动接收授权设备过多');
    await _persist(_enabled, next);
  }

  Future<void> revokeAll() => _persist(_enabled, <String>{});

  Future<void> setEnabled(bool enabled) => _persist(enabled, _authorized);

  Future<void> _persist(bool enabled, Set<String> next) async {
    if (!_ready) throw StateError('自动接收授权尚未安全加载');
    final values = next.toList()..sort();
    final payload = jsonEncode({
      'version': 1,
      'enabled': enabled,
      'fingerprints': values,
    });
    // Only update in-memory grants AFTER durable vault write succeeds.
    await _vault.write(_trustedAutoReceiveKey, payload);
    _enabled = enabled;
    _authorized
      ..clear()
      ..addAll(values);
  }
}
