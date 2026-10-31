import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'device_identity.dart';

/// Platform-protected storage adapter. No plaintext JSON file for key material.
/// Windows may require the ATL components in Visual Studio C++ workload.
class PlatformIdentityVault implements IdentityVault {
  const PlatformIdentityVault();
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
