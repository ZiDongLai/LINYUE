/// DEV10-E1: persistent sender-side task journal for future cross-launch resume.
///
/// This module deliberately does NOT start a network transfer. The E2
/// integration must authenticate a trusted peer, re-verify the source file,
/// and pass the SAME task ID to sendStreamFile. Never treat local JSON as
/// peer authorization, a cryptographic receipt, or proof of source integrity.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

const int outboundResumeMinFileBytes = 20 * 1024 * 1024 + 1;
const int outboundResumeMaxFileBytes = 1024 * 1024 * 1024; // DEV12-D2
const int outboundResumeMaxItems = 60;
const String _journalVersion = 'linyue-outbound-resume-v1';

final RegExp _idPattern = RegExp(r'^[a-f0-9]{32}$');
final RegExp _shaPattern = RegExp(r'^[a-f0-9]{64}$');

String _generateId() {
  final rng = Random.secure();
  return List<int>.generate(16, (_) => rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _fileBasename(String path) => File(path).uri.pathSegments.last;

// cleanupPending is a durable, fail-closed cleanup intent. Old snapshots with
// pending/sending/interrupted remain readable without migration.
enum OutboundResumeStatus { pending, sending, interrupted, cleanupPending }

enum OutboundRestoreCheck {
  ready,
  expired,
  peerUntrusted,
  sourceMissing,
  sourceChanged,
}

class OutboundResumeRecord {
  const OutboundResumeRecord({
    required this.taskId,
    required this.peerFingerprint,
    required this.sourcePath,
    required this.fileName,
    required this.fileBytes,
    required this.fileSha256,
    required this.createdUtc,
    required this.status,
  });

  final String taskId;
  final String peerFingerprint;
  final String sourcePath;
  final String fileName;
  final int fileBytes;
  final String fileSha256;
  final DateTime createdUtc;
  final OutboundResumeStatus status;

  OutboundResumeRecord withStatus(OutboundResumeStatus next) =>
      OutboundResumeRecord(
        taskId: taskId,
        peerFingerprint: peerFingerprint,
        sourcePath: sourcePath,
        fileName: fileName,
        fileBytes: fileBytes,
        fileSha256: fileSha256,
        createdUtc: createdUtc,
        status: next,
      );

  void validate({required int minBytes, required int maxBytes}) {
    if (!_idPattern.hasMatch(taskId) ||
        !_shaPattern.hasMatch(peerFingerprint) ||
        !_shaPattern.hasMatch(fileSha256) ||
        sourcePath.isEmpty || sourcePath.length > 4096 ||
        sourcePath.contains('\x00') ||
        File(sourcePath).absolute.path != sourcePath ||
        fileName.isEmpty || fileName.length > 120 ||
        fileName == '.' || fileName == '..' ||
        RegExp(r'[\\/:*?"<>|\x00-\x1f]').hasMatch(fileName) ||
        // SecureFileChannel uses the basename from File.uri, so a renamed or
        // altered file is not silently mapped onto the original task ID.
        _fileBasename(sourcePath) != fileName ||
        fileBytes < minBytes || fileBytes > maxBytes ||
        createdUtc.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 5))) ||
        createdUtc.isBefore(DateTime.utc(2020))) {
      throw const FormatException('invalid outbound resume record');
    }
  }

  Map<String, Object> toJson() => {
    'taskId': taskId,
    'peer': peerFingerprint,
    'path': sourcePath,
    'name': fileName,
    'bytes': fileBytes,
    'sha256': fileSha256,
    'createdUtc': createdUtc.toUtc().toIso8601String(),
    'status': status.name,
  };

  factory OutboundResumeRecord.fromJson(Map<String, dynamic> json,
      {required int minBytes, required int maxBytes}) {
    if (json['taskId'] is! String || json['peer'] is! String ||
        json['path'] is! String || json['name'] is! String ||
        json['bytes'] is! int || json['sha256'] is! String ||
        json['createdUtc'] is! String || json['status'] is! String) {
      throw const FormatException('outbound record fields missing');
    }
    final created = DateTime.tryParse(json['createdUtc'] as String);
    final stateName = json['status'] as String;
    final states = OutboundResumeStatus.values.where((s) => s.name == stateName);
    if (created == null || states.isEmpty) {
      throw const FormatException('invalid outbound status/timestamp');
    }
    final record = OutboundResumeRecord(
      taskId: json['taskId'] as String,
      peerFingerprint: json['peer'] as String,
      sourcePath: json['path'] as String,
      fileName: json['name'] as String,
      fileBytes: json['bytes'] as int,
      fileSha256: json['sha256'] as String,
      createdUtc: created.toUtc(),
      status: states.single,
    );
    record.validate(minBytes: minBytes, maxBytes: maxBytes);
    return record;
  }
}

class OutboundResumeJournal {
  OutboundResumeJournal(this.directory, {
    this.minBytes = outboundResumeMinFileBytes,
    this.maxBytes = outboundResumeMaxFileBytes,
    this.maxAge = const Duration(hours: 24),
  }) {
    if (minBytes < 0 || maxBytes < minBytes ||
        maxBytes > outboundResumeMaxFileBytes) {
      throw ArgumentError('invalid resume transfer size limits');
    }
  }

  final Directory directory;
  final int minBytes;
  final int maxBytes;
  final Duration maxAge;

  File _slot(int generation) => File(
    '${directory.path}${Platform.pathSeparator}'
    '.linyue_outbound_resume_${generation.isEven ? 'a' : 'b'}.json');

  Future<_Snapshot?> _readSlot(File file) async {
    if (!await file.exists()) return null;
    if (await file.length() > 128 * 1024) {
      throw const FormatException('outbound journal too large');
    }
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, dynamic> || raw['format'] != _journalVersion ||
        raw['generation'] is! int || raw['tasks'] is! List ||
        raw['checksum'] is! String) {
      throw const FormatException('invalid outbound journal');
    }
    final generation = raw['generation'] as int;
    final taskJson = raw['tasks'] as List;
    if (generation < 0 || taskJson.length > outboundResumeMaxItems) {
      throw const FormatException('invalid outbound journal generation/count');
    }
    final payload = <String, Object>{
      'format': _journalVersion,
      'generation': generation,
      'tasks': taskJson,
    };
    final checksum = crypto.sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    if (checksum != raw['checksum']) {
      throw const FormatException('outbound journal checksum mismatch');
    }
    final seen = <String>{};
    final entries = <OutboundResumeRecord>[];
    for (final item in taskJson) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('invalid outbound task');
      }
      final record = OutboundResumeRecord.fromJson(item,
          minBytes: minBytes, maxBytes: maxBytes);
      if (!seen.add(record.taskId)) {
        throw const FormatException('duplicate outbound resume ID');
      }
      entries.add(record);
    }
    return _Snapshot(generation, entries);
  }

  Future<_Snapshot> _latest() async {
    _Snapshot? first;
    _Snapshot? second;
    Object? badFirst;
    Object? badSecond;
    try { first = await _readSlot(_slot(0)); } catch (e) { badFirst = e; }
    try { second = await _readSlot(_slot(1)); } catch (e) { badSecond = e; }
    if (first == null && second == null) {
      if (badFirst != null || badSecond != null) {
        throw StateError('发送恢复记录损坏：两份日志均不可用（$badFirst / $badSecond）');
      }
      return const _Snapshot(-1, []);
    }
    if (first == null) return second!;
    if (second == null) return first;
    return first.generation > second.generation ? first : second;
  }

  Future<List<OutboundResumeRecord>> load() async =>
      List<OutboundResumeRecord>.unmodifiable((await _latest()).items);

  /// Atomic slot rotation. Previous valid slot is not touched until the new
  /// snapshot is flushed and renamed. Do not write these records to a shared
  /// drive or allow simultaneous writers in multiple app processes.
  Future<void> save(List<OutboundResumeRecord> items) async {
    if (items.length > outboundResumeMaxItems) {
      throw StateError('未完成的发送任务不能超过 $outboundResumeMaxItems 项');
    }
    final seen = <String>{};
    for (final item in items) {
      item.validate(minBytes: minBytes, maxBytes: maxBytes);
      if (!seen.add(item.taskId)) {
        throw StateError('同一断点任务不能重复保存');
      }
    }
    final old = await _latest();
    final generation = old.generation + 1;
    final payload = <String, Object>{
      'format': _journalVersion,
      'generation': generation,
      'tasks': items.map((r) => r.toJson()).toList(),
    };
    final snapshot = jsonEncode({
      ...payload,
      'checksum': crypto.sha256.convert(utf8.encode(jsonEncode(payload))).toString(),
    });
    await directory.create(recursive: true);
    final target = _slot(generation);
    final temp = File('${target.path}.tmp.${_generateId()}');
    try {
      await temp.writeAsString(snapshot, flush: true);
      // On Windows replacing an existing destination with File.rename may
      // fail; deleting only the OLDER slot preserves the latest good slot.
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  /// Record a real local source for a future E2 restart-safe send.
  /// Android content URI streams must first be copied to a durable
  /// app-private source file; a temporary picker cache path is NOT durable.
  Future<OutboundResumeRecord> inspectNewSource({
    required File file,
    required String peerFingerprint,
  }) async {
    if (!_shaPattern.hasMatch(peerFingerprint)) {
      throw const FormatException('invalid trusted peer fingerprint');
    }
    final source = File(file.absolute.path);
    if (!await source.exists()) {
      throw StateError('源文件不存在，无法建立恢复任务');
    }
    final length = await source.length();
    if (length < minBytes || length > maxBytes) {
      throw StateError('仅支持当前大文件试运行范围内的恢复记录');
    }
    final digest = (await crypto.sha256.bind(source.openRead()).first).toString();
    if (await source.length() != length) {
      throw StateError('检查文件期间源文件发生变化');
    }
    final record = OutboundResumeRecord(
      taskId: _generateId(),
      peerFingerprint: peerFingerprint,
      sourcePath: source.path,
      fileName: _fileBasename(source.path),
      fileBytes: length,
      fileSha256: digest,
      createdUtc: DateTime.now().toUtc(),
      status: OutboundResumeStatus.pending,
    );
    record.validate(minBytes: minBytes, maxBytes: maxBytes);
    return record;
  }

  /// Revalidate immediately BEFORE a later attempt: no implicit send, no
  /// automatic trusting of a saved peer/IP, no fallback to plaintext.
  Future<OutboundRestoreCheck> checkForRestore(OutboundResumeRecord record, {
    required Set<String> trustedFingerprints,
    DateTime? now,
  }) async {
    record.validate(minBytes: minBytes, maxBytes: maxBytes);
    final at = (now ?? DateTime.now()).toUtc();
    if (at.difference(record.createdUtc) > maxAge) {
      return OutboundRestoreCheck.expired;
    }
    if (!trustedFingerprints.contains(record.peerFingerprint)) {
      return OutboundRestoreCheck.peerUntrusted;
    }
    final source = File(record.sourcePath);
    if (!await source.exists()) return OutboundRestoreCheck.sourceMissing;
    if (await source.length() != record.fileBytes) {
      return OutboundRestoreCheck.sourceChanged;
    }
    final actual = (await crypto.sha256.bind(source.openRead()).first).toString();
    if (await source.length() != record.fileBytes ||
        actual != record.fileSha256) {
      return OutboundRestoreCheck.sourceChanged;
    }
    return OutboundRestoreCheck.ready;
  }
}

class _Snapshot {
  const _Snapshot(this.generation, this.items);
  final int generation;
  final List<OutboundResumeRecord> items;
}
