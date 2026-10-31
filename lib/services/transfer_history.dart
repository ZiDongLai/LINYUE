import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Local-only record of a completed or failed transfer.
/// No file bytes, authorization tokens, or remote IP addresses are persisted.
class TransferRecord {
  const TransferRecord({
    required this.name,
    required this.peerName,
    required this.direction,
    required this.status,
    required this.bytes,
    required this.timestamp,
    this.localPath,
    this.thumbnailPath,
    this.sourcePath,
    this.managedShareCopy = false,
    this.transport, this.peerFingerprint, this.transferId, this.sha256,
  });

  final String name;
  final String peerName;
  final String direction; // send / receive
  final String status; // success / failed
  final int bytes;
  final DateTime timestamp;
  final String? localPath;
  // App-private preview generated locally for a successfully sent image.
  // It is not the original file and never grants access to the remote device.
  final String? thumbnailPath;
  // Local original used for direct sharing from a sent chat card. It may be a
  // user-selected source path or a managed app-private fallback copy.
  final String? sourcePath;
  // Only true for sourcePath files stored in NearLinkOutboundShareCache.
  // This lets LINYUE safely prune its own cache without deleting user files.
  final bool managedShareCopy;
  // Optional E32 attribution; legacy records remain unattributed.
  final String? transport, peerFingerprint, transferId, sha256;

  Map<String, Object?> toJson() => {
    'name': name,
    'peerName': peerName,
    'direction': direction,
    'status': status,
    'bytes': bytes,
    'timestamp': timestamp.toIso8601String(),
    'localPath': localPath,
    'thumbnailPath': thumbnailPath,
    'sourcePath': sourcePath,
    'managedShareCopy': managedShareCopy,
    if (transport != null) 'transport': transport,
    if (peerFingerprint != null) 'peerFingerprint': peerFingerprint,
    if (transferId != null) 'transferId': transferId,
    if (sha256 != null) 'sha256': sha256,
  };

  factory TransferRecord.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final peer = json['peerName'];
    final direction = json['direction'];
    final status = json['status'];
    final bytes = json['bytes'];
    final timestamp = json['timestamp'];
    if (name is! String || name.isEmpty || name.length > 255 ||
        peer is! String || peer.length > 120 ||
        (direction != 'send' && direction != 'receive') ||
        (status != 'success' && status != 'failed') ||
        bytes is! int || bytes < 0 ||
        timestamp is! String) {
      throw const FormatException('Invalid local history entry');
    }
    final date = DateTime.tryParse(timestamp);
    if (date == null) throw const FormatException('Invalid timestamp');
    final path = json['localPath'];
    final preview = json['thumbnailPath'];
    final source = json['sourcePath'];
    final managed = json['managedShareCopy'];
    if (json['transport'] != null && (json['transport'] != 'bluetooth' ||
        json['peerFingerprint'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['peerFingerprint']) ||
        json['transferId'] is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(json['transferId']) ||
        json['sha256'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['sha256']))) {
      throw const FormatException('Invalid Bluetooth file history attribution');
    }
    return TransferRecord(
      transport: json['transport'] as String?,
      peerFingerprint: json['transport'] == 'bluetooth' ? json['peerFingerprint'] as String? : null,
      transferId: json['transport'] == 'bluetooth' ? json['transferId'] as String? : null,
      sha256: json['transport'] == 'bluetooth' ? json['sha256'] as String? : null,
      name: name,
      peerName: peer,
      direction: direction as String,
      status: status as String,
      bytes: bytes,
      timestamp: date,
      localPath: path is String && path.isNotEmpty ? path : null,
      thumbnailPath: preview is String && preview.isNotEmpty ? preview : null,
      sourcePath: source is String && source.isNotEmpty ? source : null,
      managedShareCopy: managed == true,
    );
  }
}

class TransferHistoryStore {
  TransferHistoryStore({this.customDirectory});

  static const int maxEntries = 200;
  final Directory? customDirectory;
  final List<TransferRecord> _entries = [];
  Future<void> _writeQueue = Future<void>.value();
  File? _file;

  List<TransferRecord> get records => List<TransferRecord>.unmodifiable(_entries);

  Future<void> load() async {
    final base = customDirectory ?? await getApplicationDocumentsDirectory();
    await base.create(recursive: true);
    _file = File('${base.path}${Platform.pathSeparator}linyue_transfer_history_v1.json');
    final backup = File('${_file!.path}.bak');
    if (!await _file!.exists() && await backup.exists()) {
      await backup.rename(_file!.path);
    }
    if (!await _file!.exists()) return;

    final data = jsonDecode(await _file!.readAsString());
    if (data is! Map<String, dynamic> || data['schema'] != 1 || data['records'] is! List) {
      throw const FormatException('Unsupported local transfer history format');
    }
    final parsed = <TransferRecord>[];
    for (final item in data['records'] as List) {
      if (item is! Map<String, dynamic>) continue;
      try {
        parsed.add(TransferRecord.fromJson(item));
      } on FormatException {
        // Ignore individual malformed entries but retain other history.
      }
    }
    _entries
      ..clear()
      ..addAll(parsed.take(maxEntries));
  }

  Future<void> append(TransferRecord record) {
    _entries.insert(0, record);
    if (_entries.length > maxEntries) _entries.removeRange(maxEntries, _entries.length);
    return _enqueueWrite();
  }

  /// BT final receipt must wait for durable history; LAN append remains unchanged.
  Future<void> appendBluetoothConfirmed(TransferRecord record) {
    if (record.transport != 'bluetooth' || record.status != 'success') {
      throw ArgumentError('Expected attributed successful Bluetooth record');
    }
    TransferRecord.fromJson(record.toJson());
    final operation = _writeQueue.then((_) async {
      final old = _entries.where((e) => e.transport == 'bluetooth' &&
          e.peerFingerprint == record.peerFingerprint && e.transferId == record.transferId &&
          e.direction == record.direction).toList();
      if (old.isNotEmpty) {
        if (old.length != 1 || old.single.sha256 != record.sha256 ||
            old.single.bytes != record.bytes || old.single.localPath != record.localPath ||
            old.single.sourcePath != record.sourcePath) {
          throw StateError('Bluetooth history task identity conflict');
        }
        return;
      }
      _entries.insert(0, record);
      final evicted = _entries.length > maxEntries ? _entries.sublist(maxEntries) : <TransferRecord>[];
      if (_entries.length > maxEntries) _entries.removeRange(maxEntries, _entries.length);
      try { await _persist(); } catch (_) {
        _entries.removeWhere((e) => identical(e, record));
        for (final item in evicted) { if (!_entries.contains(item)) _entries.add(item); }
        if (_entries.length > maxEntries) _entries.removeRange(maxEntries, _entries.length);
        rethrow;
      }
    });
    _writeQueue = operation.catchError((Object _, StackTrace _) {});
    return operation;
  }

  /// E20-C2: removes exactly the selected local transfer-history record.
  /// This never deletes/renames any file or sends commands to a peer.
  /// An identity check avoids deleting a visually identical other record.
  Future<bool> removeRecord(TransferRecord record) async {
    final index = _entries.indexWhere((entry) => identical(entry, record));
    if (index < 0) return false;
    _entries.removeAt(index);
    try {
      await _enqueueWrite();
    } catch (_) {
      _entries.insert(index.clamp(0, _entries.length).toInt(), record);
      rethrow;
    }
    return true;
  }

  /// Updates receive-history references after a user renames a local copy.
  /// Sent records and unrelated receive records remain unchanged.
  Future<void> renameReceivedFilePath({
    required String oldPath,
    required String newPath,
    required String newName,
  }) async {
    final originals = <int, TransferRecord>{};
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry.direction != 'receive' || entry.localPath == null ||
          !_sameLocalPath(entry.localPath!, oldPath)) continue;
      originals[i] = entry;
      _entries[i] = TransferRecord(
        name: newName,
        peerName: entry.peerName,
        direction: entry.direction,
        status: entry.status,
        bytes: entry.bytes,
        timestamp: entry.timestamp,
        localPath: newPath,
        thumbnailPath: entry.thumbnailPath,
        sourcePath: entry.sourcePath,
        managedShareCopy: entry.managedShareCopy,
        transport: entry.transport, peerFingerprint: entry.peerFingerprint,
        transferId: entry.transferId, sha256: entry.sha256,
      );
    }
    if (originals.isEmpty) return;
    try {
      await _enqueueWrite();
    } catch (_) {
      for (final entry in originals.entries) {
        _entries[entry.key] = entry.value;
      }
      rethrow;
    }
  }

  bool _sameLocalPath(String first, String second) {
    final a = File(first).absolute.path;
    final b = File(second).absolute.path;
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }

  Future<void> clear() {
    _entries.clear();
    return _enqueueWrite();
  }

  Future<void> _enqueueWrite() {
    final operation = _writeQueue.then((_) => _persist());
    // A failed write must not permanently block later attempts.
    _writeQueue = operation.catchError((Object _, StackTrace __) {});
    return operation;
  }

  Future<void> _persist() async {
    final file = _file;
    if (file == null) throw StateError('History store not initialized');
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    final value = jsonEncode({
      'schema': 1,
      'records': _entries.map((r) => r.toJson()).toList(),
    });
    await temp.writeAsString(value, flush: true);

    if (await file.exists()) {
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
    }
    try {
      await temp.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }
}
