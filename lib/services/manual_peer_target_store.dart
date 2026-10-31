import 'dart:convert';
import 'dart:io';

import 'same_platform_connection_policy.dart';

/// Stores only manually entered LAN addresses as reconnect hints.
/// An address is never an identity, pairing grant, or transfer authorization.
final class ManualPeerTargetStore {
  ManualPeerTargetStore({required this.directory});

  final Directory directory;

  static const int maxTargets = 32;
  static const String _fileName = 'targets.json';
  Future<void> _saveTail = Future<void>.value();

  File get _primary => File(
      '${directory.path}${Platform.pathSeparator}$_fileName');
  File get _backup => File('${_primary.path}.bak');
  File get _temporary => File('${_primary.path}.tmp');

  List<String> _sanitize(Object? decoded) {
    if (decoded is! List) {
      throw const FormatException('手动连接目标格式无效');
    }
    final unique = <String>{};
    for (final value in decoded) {
      if (value is! String) continue;
      final address = value.trim();
      if (SamePlatformConnectionPolicy.isPlausibleLanAddress(address)) {
        unique.add(address);
      }
    }
    final result = unique.toList()..sort();
    if (result.length > maxTargets) {
      result.removeRange(maxTargets, result.length);
    }
    return result;
  }

  /// Reads the primary slot first, then a backup if the primary is unreadable.
  /// A corrupt file is left untouched for diagnostics; this store never touches
  /// device identities, cryptographic keys, chat history, or received files.
  Future<List<String>> load() async {
    for (final file in <File>[_primary, _backup]) {
      if (!await file.exists()) continue;
      try {
        final decoded = jsonDecode(await file.readAsString());
        return _sanitize(decoded);
      } catch (_) {
        // Try the backup slot without deleting or rewriting either file.
      }
    }
    return const <String>[];
  }

  Future<void> save(Iterable<String> addresses) {
    final normalized = <String>{};
    for (final raw in addresses) {
      final address = raw.trim();
      if (SamePlatformConnectionPolicy.isPlausibleLanAddress(address)) {
        normalized.add(address);
      }
    }
    final sorted = normalized.toList()..sort();
    if (sorted.length > maxTargets) {
      sorted.removeRange(maxTargets, sorted.length);
    }
    // A pairing callback and the manual-IP button can both request a save.
    // Serialize writes so their temporary/backup slots never race each other.
    final next = _saveTail
        .catchError((Object _) {})
        .then((_) => _writeSnapshot(sorted));
    _saveTail = next;
    return next;
  }

  Future<void> _writeSnapshot(List<String> sorted) async {
    await directory.create(recursive: true);
    await _temporary.writeAsString(jsonEncode(sorted), flush: true);
    var movedPrimaryToBackup = false;
    try {
      if (await _primary.exists()) {
        if (await _backup.exists()) await _backup.delete();
        await _primary.rename(_backup.path);
        movedPrimaryToBackup = true;
      }
      await _temporary.rename(_primary.path);
      if (await _backup.exists()) await _backup.delete();
    } catch (_) {
      if (!await _primary.exists() &&
          movedPrimaryToBackup &&
          await _backup.exists()) {
        await _backup.rename(_primary.path);
      }
      rethrow;
    } finally {
      if (await _temporary.exists()) await _temporary.delete();
    }
  }
}
