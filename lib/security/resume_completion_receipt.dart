/// DEV10-D3: immutable, receiver-side completion intent for a resumed transfer.
///
/// A signed/paired channel must authenticate the peer before calling this API.
/// This journal alone does NOT authorize a file upload or prove a remote identity.
/// A receipt is only acknowledged after the final file has been independently
/// re-hashed on disk. The intent is persisted *before* renaming the verified
/// .part file; if the app closes after the rename but before the ACK, a new
/// authenticated offer can recover the completed result without re-saving it.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'resume_checkpoint.dart';
import 'linear_resume_checkpoint.dart';
import 'resume_format_router.dart';

class ResumeCompletionReceipt {
  const ResumeCompletionReceipt({required this.taskId, required this.peer,
    required this.sha256, required this.size, required this.originalName,
    required this.savedName});

  final String taskId, peer, sha256, originalName, savedName;
  final int size;

  Map<String, Object> toJson() => <String, Object>{
    'v': 'linyue-resume-completion-intent-v1',
    'taskId': taskId,
    'peer': peer,
    'sha256': sha256,
    'size': size,
    'originalName': originalName,
    'savedName': savedName,
  };

  factory ResumeCompletionReceipt.fromJson(Map<String, dynamic> data) {
    if (data['v'] != 'linyue-resume-completion-intent-v1' ||
        data['taskId'] is! String || data['peer'] is! String ||
        data['sha256'] is! String || data['size'] is! int ||
        data['originalName'] is! String || data['savedName'] is! String) {
      throw const FormatException('invalid completed-transfer record');
    }
    final value = ResumeCompletionReceipt(
      taskId: data['taskId'] as String,
      peer: data['peer'] as String,
      sha256: data['sha256'] as String,
      size: data['size'] as int,
      originalName: data['originalName'] as String,
      savedName: data['savedName'] as String,
    );
    value.validate();
    return value;
  }

  static bool safeFileName(String name) => name.isNotEmpty &&
      name != '.' && name != '..' && name.length <= 220 &&
      !RegExp(r'[\\/:*?"<>|\x00-\x1f]').hasMatch(name);

  void validate() {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(taskId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(peer) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        size <= 0 || size > linearCheckpointMaxBytes ||
        !safeFileName(originalName) || !safeFileName(savedName)) {
      throw const FormatException('invalid completed-transfer metadata');
    }
  }

  bool matches({required String id, required String fingerprint,
      required String digest, required int total, required String name}) =>
    taskId == id && peer == fingerprint && sha256 == digest &&
    size == total && originalName == name;
}

class ResumeCompletionLedger {
  ResumeCompletionLedger(this.store, {this.linearStore});
  final ResumeCheckpointStore store;
  /// When supplied, V2 completion intents use the same receipt filename but
  /// must re-verify the V2 journal before finalization. V1 stays compatible.
  final LinearResumeCheckpointStore? linearStore;

  File receiptFile(String id) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
      throw const FormatException('invalid resume id');
    }
    return File('${store.directory.path}${Platform.pathSeparator}'
      '.linyue_resume_$id.receipt.json');
  }

  File _savedFile(String filename) {
    if (!ResumeCompletionReceipt.safeFileName(filename)) {
      throw const FormatException('unsafe saved filename');
    }
    return File('${store.directory.path}${Platform.pathSeparator}$filename');
  }

  Future<ResumeCompletionReceipt?> _read(String id) async {
    final file = receiptFile(id);
    if (!await file.exists()) return null;
    if (await file.length() > 4096) {
      throw const FormatException('oversize completion receipt');
    }
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, dynamic>) {
      throw const FormatException('invalid completion receipt JSON');
    }
    final receipt = ResumeCompletionReceipt.fromJson(data);
    if (receipt.taskId != id) throw StateError('completion ID mismatch');
    return receipt;
  }

  /// Called ONLY after decodeRemaining has verified every frame and committed
  /// a FULL SHA-256-verified checkpoint. The journal is written before rename.
  Future<void> prepare({required String id, required String fingerprint,
      required String digest, required int total, required String originalName,
      required String savedName}) async {
    final record = ResumeCompletionReceipt(taskId: id, peer: fingerprint,
      sha256: digest, size: total, originalName: originalName,
      savedName: savedName);
    record.validate();
    if (await receiptFile(id).exists()) {
      throw StateError('completion intent already exists');
    }
    final finalFile = _savedFile(savedName);
    if (await finalFile.exists()) {
      throw StateError('destination already exists');
    }
    if (linearStore != null) {
      final verified = await linearStore!.inspect(id: id,
        expectedPeer: fingerprint, expectedSha256: digest, expectedSize: total);
      if (verified.record.committed != total) {
        throw StateError('V2 file has not passed final verification');
      }
    } else {
      final verified = await store.inspect(id: id, expectedPeer: fingerprint,
        expectedSha256: digest, expectedSize: total);
      if (verified.checkpoint.committedBytes != total) {
        throw StateError('file has not passed final verification');
      }
    }
    await store.directory.create(recursive: true);
    final tmp = File('${receiptFile(id).path}.tmp.${Random.secure().nextInt(0x7fffffff)}');
    try {
      await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
      if (await receiptFile(id).exists()) {
        throw StateError('another completion record exists');
      }
      await tmp.rename(receiptFile(id).path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  /// Only a fully authenticated matching offer may call reconcile. The saved
  /// file is hashed on disk on EVERY query. Never blindly trust a JSON record.
  /// Returns null only when no prior completion intent exists.
  Future<File?> reconcile({required String id, required String fingerprint,
      required String digest, required int total, required String originalName}) async {
    final record = await _read(id);
    if (record == null) return null;
    if (!record.matches(id: id, fingerprint: fingerprint,
        digest: digest, total: total, name: originalName)) {
      throw StateError('completion receipt belongs to another peer/file');
    }
    final finalFile = _savedFile(record.savedName);
    if (await finalFile.exists()) {
      await _verifyFile(finalFile, record);
      return finalFile;
    }
    // Crash occurred AFTER writing the intent but BEFORE the final rename.
    // Only a completely committed and re-hashed .part may now be finalized.
    final chosen = linearStore == null
      ? ResumeCheckpointFormat.legacyV1
      : await ResumeFormatRouter(store.directory).choose(id);
    if (chosen == ResumeCheckpointFormat.linearV2) {
      final checkpoint = await linearStore!.inspect(id: id,
        expectedPeer: fingerprint, expectedSha256: digest, expectedSize: total);
      if (checkpoint.record.committed != total) {
        throw StateError('V2 completion intent lacks verified final bytes');
      }
    } else {
      final checkpoint = await store.inspect(id: id, expectedPeer: fingerprint,
        expectedSha256: digest, expectedSize: total);
      if (checkpoint.checkpoint.committedBytes != total) {
        throw StateError('completion intent lacks verified final bytes');
      }
    }
    if (await finalFile.exists()) {
      throw StateError('destination appeared during completion recovery');
    }
    await (chosen == ResumeCheckpointFormat.linearV2
      ? linearStore!.partFile(id) : store.partFile(id)).rename(finalFile.path);
    await _verifyFile(finalFile, record);
    return finalFile;
  }

  Future<void> _verifyFile(File file, ResumeCompletionReceipt record) async {
    if (!await file.exists() || await file.length() != record.size ||
        (await crypto.sha256.bind(file.openRead()).first).toString() != record.sha256) {
      throw StateError('completed transfer file was changed, missing or corrupted');
    }
  }
}
