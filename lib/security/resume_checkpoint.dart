/// DEV10-D1: local, persistent resume checkpoints for authenticated chunked
/// transfers. Not yet connected to SecureFileChannel: DEV10-D2 must negotiate
/// a fresh authenticated session and validate both peers before resuming.
/// This journal contains NO encryption keys or transferable authorization.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

const int resumeCheckpointMaxBytes = 512 * 1024 * 1024;
const int resumeCheckpointChunkSize = 256 * 1024;
const String _emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

bool _isSha256(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool _isId(String value) => RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

class ResumeCheckpoint {
  const ResumeCheckpoint({
    required this.id,
    required this.peerFingerprint,
    required this.fileSha256,
    required this.totalBytes,
    required this.committedBytes,
    required this.committedSha256,
    required this.chunkBytes,
    required this.generation,
    required this.updatedUtc,
  });

  final String id;
  final String peerFingerprint;
  final String fileSha256;
  final int totalBytes;
  final int committedBytes;
  final String committedSha256;
  final int chunkBytes;
  final int generation;
  final DateTime updatedUtc;

  Map<String, Object> toJson() => <String, Object>{
        'format': 'linyue-resume-checkpoint-v1',
        'id': id,
        'peer': peerFingerprint,
        'sha256': fileSha256,
        'total': totalBytes,
        'committed': committedBytes,
        'prefixSha256': committedSha256,
        'chunkBytes': chunkBytes,
        'generation': generation,
        'updatedUtc': updatedUtc.toUtc().toIso8601String(),
      };

  factory ResumeCheckpoint.fromJson(Map<String, dynamic> data) {
    final id = data['id'];
    final peer = data['peer'];
    final sha = data['sha256'];
    final total = data['total'];
    final committed = data['committed'];
    final prefix = data['prefixSha256'];
    final chunk = data['chunkBytes'];
    final gen = data['generation'];
    final date = data['updatedUtc'];
    if (data['format'] != 'linyue-resume-checkpoint-v1' ||
        id is! String || !_isId(id) ||
        peer is! String || !_isSha256(peer) ||
        sha is! String || !_isSha256(sha) ||
        total is! int || total <= 0 || total > resumeCheckpointMaxBytes ||
        committed is! int || committed < 0 || committed > total ||
        (committed % resumeCheckpointChunkSize != 0 && committed != total) ||
        prefix is! String || !_isSha256(prefix) ||
        (committed == 0 && prefix != _emptySha256) ||
        chunk != resumeCheckpointChunkSize ||
        gen is! int || gen < 0 ||
        date is! String) {
      throw const FormatException('invalid resume checkpoint');
    }
    final when = DateTime.tryParse(date);
    if (when == null || when.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 5)))) {
      throw const FormatException('invalid resume checkpoint timestamp');
    }
    return ResumeCheckpoint(
      id: id, peerFingerprint: peer, fileSha256: sha,
      totalBytes: total, committedBytes: committed, committedSha256: prefix,
      chunkBytes: chunk, generation: gen, updatedUtc: when.toUtc(),
    );
  }
}

class ResumePoint {
  const ResumePoint(this.checkpoint, this.uncommittedBytes);
  final ResumeCheckpoint checkpoint;
  /// Bytes beyond a durable checkpoint are untrusted and must be truncated
  /// before a new encrypted session begins. Never use them as acknowledged.
  final int uncommittedBytes;
}

/// Two alternating journal slots ensure an interrupted write cannot destroy
/// the last complete checkpoint. The .part bytes are rehashed on *every*
/// recovery attempt; a journal by itself is never proof of received content.
class ResumeCheckpointStore {
  ResumeCheckpointStore(this.directory, {this.maxAge = const Duration(hours: 24)});
  final Directory directory;
  final Duration maxAge;

  static String newId() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  File partFile(String id) {
    _checkId(id);
    return File('${directory.path}${Platform.pathSeparator}.linyue_resume_$id.part');
  }

  File _slot(String id, int generation) {
    _checkId(id);
    final suffix = generation.isEven ? 'a' : 'b';
    return File('${directory.path}${Platform.pathSeparator}.linyue_resume_$id.$suffix.json');
  }

  static void _checkId(String id) {
    if (!_isId(id)) throw const FormatException('invalid resume id');
  }

  static void _checkMetadata(String fingerprint, String digest, int bytes) {
    if (!_isSha256(fingerprint) || !_isSha256(digest) ||
        bytes <= 0 || bytes > resumeCheckpointMaxBytes) {
      throw const FormatException('invalid resume peer/hash/size');
    }
  }

  Future<ResumeCheckpoint> create({
    required String id,
    required String peerFingerprint,
    required String fileSha256,
    required int totalBytes,
  }) async {
    _checkId(id);
    _checkMetadata(peerFingerprint, fileSha256, totalBytes);
    if (await partFile(id).exists() || await _slot(id, 0).exists() ||
        await _slot(id, 1).exists()) {
      throw StateError('resume id already exists; never overwrite an unfinished file');
    }
    await directory.create(recursive: true);
    await partFile(id).writeAsBytes(const <int>[], flush: true);
    final initial = ResumeCheckpoint(id: id, peerFingerprint: peerFingerprint,
      fileSha256: fileSha256, totalBytes: totalBytes, committedBytes: 0,
      committedSha256: _emptySha256, chunkBytes: resumeCheckpointChunkSize,
      generation: 0, updatedUtc: DateTime.now().toUtc());
    await _write(initial);
    return initial;
  }

  Future<void> _write(ResumeCheckpoint entry) async {
    // Always write the INACTIVE slot; an interrupted overwrite leaves the
    // previously active slot recoverable. Files contain metadata only.
    await _slot(entry.id, entry.generation)
        .writeAsString(jsonEncode(entry.toJson()), flush: true);
  }

  Future<ResumeCheckpoint?> _latest(String id) async {
    _checkId(id);
    final entries = <ResumeCheckpoint>[];
    for (final gen in <int>[0, 1]) {
      final file = _slot(id, gen);
      if (!await file.exists()) continue;
      try {
        if (await file.length() > 4096) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) continue;
        final record = ResumeCheckpoint.fromJson(decoded);
        if (record.id == id && record.generation.isEven == gen.isEven) {
          entries.add(record);
        }
      } catch (_) {
        // Corrupt inactive slot is ignored; part contents are NEVER trusted
        // until independently hashed below.
      }
    }
    if (entries.isEmpty) return null;
    entries.sort((a, b) => b.generation.compareTo(a.generation));
    return entries.first;
  }

  /// Called only after a receiver wrote and flushed a COMPLETE verified chunk.
  /// This intentionally rehashes local bytes instead of trusting caller input.
  /// DEV10-D2 should commit only periodically to control disk I/O.
  Future<ResumeCheckpoint> commit(String id, int confirmedBytes) async {
    final old = await _latest(id);
    if (old == null) throw StateError('no saved resume checkpoint');
    final file = partFile(id);
    if (confirmedBytes < old.committedBytes || confirmedBytes > old.totalBytes ||
        (confirmedBytes % old.chunkBytes != 0 && confirmedBytes != old.totalBytes)) {
      throw StateError('invalid or regressing commit offset');
    }
    if (!await file.exists() || await file.length() != confirmedBytes) {
      throw StateError('partial file length must match the commit offset');
    }
    // Existing committed prefix must still match before recording progress.
    final previous = await _sha256Prefix(file, old.committedBytes);
    if (previous != old.committedSha256) {
      throw StateError('previous durable chunk content changed');
    }
    final current = await _sha256Prefix(file, confirmedBytes);
    if (confirmedBytes == old.totalBytes && current != old.fileSha256) {
      throw StateError('final file digest differs from original source');
    }
    final entry = ResumeCheckpoint(
      id: old.id, peerFingerprint: old.peerFingerprint,
      fileSha256: old.fileSha256, totalBytes: old.totalBytes,
      committedBytes: confirmedBytes, committedSha256: current,
      chunkBytes: old.chunkBytes, generation: old.generation + 1,
      updatedUtc: DateTime.now().toUtc(),
    );
    await _write(entry);
    return entry;
  }

  Future<ResumePoint> inspect({
    required String id,
    required String expectedPeer,
    required String expectedSha256,
    required int expectedSize,
  }) async {
    _checkMetadata(expectedPeer, expectedSha256, expectedSize);
    final checkpoint = await _latest(id);
    if (checkpoint == null) throw StateError('resume journal missing or corrupted');
    if (checkpoint.committedBytes == checkpoint.totalBytes &&
        checkpoint.committedSha256 != checkpoint.fileSha256) {
      throw StateError('finished checkpoint has an incorrect final digest');
    }
    if (checkpoint.peerFingerprint != expectedPeer ||
        checkpoint.fileSha256 != expectedSha256 ||
        checkpoint.totalBytes != expectedSize) {
      throw StateError('resume file or authenticated peer mismatch');
    }
    final age = DateTime.now().toUtc().difference(checkpoint.updatedUtc);
    if (age > maxAge || age < const Duration(minutes: -5)) {
      throw StateError('resume checkpoint expired or clock invalid');
    }
    final file = partFile(id);
    if (!await file.exists()) throw StateError('incomplete file missing');
    final currentSize = await file.length();
    if (currentSize < checkpoint.committedBytes || currentSize > checkpoint.totalBytes) {
      throw StateError('incomplete file length invalid');
    }
    final digest = await _sha256Prefix(file, checkpoint.committedBytes);
    if (digest != checkpoint.committedSha256) {
      throw StateError('durably committed prefix was modified');
    }
    return ResumePoint(checkpoint, currentSize - checkpoint.committedBytes);
  }

  /// Sender must separately verify the entire source file against the offer
  /// before agreeing to resume at an authenticated receiver offset.
  Future<void> verifySource(File source, ResumeCheckpoint entry) async {
    if (!await source.exists() || await source.length() != entry.totalBytes) {
      throw StateError('source file was removed or resized');
    }
    final digest = (await crypto.sha256.bind(source.openRead()).first).toString();
    if (digest != entry.fileSha256) throw StateError('source file contents changed');
  }

  /// DEV10-D2 calls this only AFTER new-session identity authentication and
  /// peer/offer verification. Uncommitted suffix bytes are discarded; no
  /// previously-used AES-GCM nonce or session key is ever reused here.
  Future<int> truncateUncommitted(ResumePoint point) async {
    final inspected = await inspect(id: point.checkpoint.id,
      expectedPeer: point.checkpoint.peerFingerprint,
      expectedSha256: point.checkpoint.fileSha256,
      expectedSize: point.checkpoint.totalBytes);
    if (inspected.checkpoint.generation != point.checkpoint.generation) {
      throw StateError('resume checkpoint changed after inspection');
    }
    final file = await partFile(point.checkpoint.id).open(mode: FileMode.append);
    try {
      await file.truncate(point.checkpoint.committedBytes);
      await file.flush();
    } finally {
      await file.close();
    }
    return point.checkpoint.committedBytes;
  }

  /// Deletes only the explicitly selected resume record (never the final
  /// received file), called on successful finalization or explicit discard.
  Future<void> discard(String id) async {
    _checkId(id);
    for (final file in <File>[partFile(id), _slot(id, 0), _slot(id, 1)]) {
      if (await file.exists()) await file.delete();
    }
  }

  static Future<String> _sha256Prefix(File file, int length) async {
    if (length == 0) return _emptySha256;
    return (await crypto.sha256.bind(file.openRead(0, length)).first).toString();
  }
}
