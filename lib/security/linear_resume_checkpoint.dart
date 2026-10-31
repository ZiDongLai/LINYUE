// DEV12-C3B V2 production checkpoint store, isolated from V1 records.
// Commits hash only newly authenticated spans; on resume inspect() verifies
// EVERY confirmed span. Finalization verifies the entire original SHA-256.
// Distinct filenames / format preserve legacy cross-launch resume tasks.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

const int linearCheckpointMaxBytes = 1024 * 1024 * 1024; // DEV12-D2 V2 only
const int linearCheckpointStepBytes = 4 * 1024 * 1024;
const int linearCheckpointChunkBytes = 256 * 1024;
const String _emptyDigest =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

final RegExp _hashFormat = RegExp(r'^[0-9a-f]{64}$');
final RegExp _idFormat = RegExp(r'^[0-9a-f]{32}$');

class LinearCheckpointSpan {
  const LinearCheckpointSpan(this.end, this.sha256);
  final int end;
  final String sha256;

  Map<String, Object> toJson() => {'end': end, 'sha256': sha256};

  factory LinearCheckpointSpan.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('invalid span');
    }
    final end = raw['end'];
    final digest = raw['sha256'];
    if (end is! int || end <= 0 ||
        digest is! String || !_hashFormat.hasMatch(digest)) {
      throw const FormatException('invalid span data');
    }
    return LinearCheckpointSpan(end, digest);
  }
}

class LinearCheckpointRecord {
  const LinearCheckpointRecord({
    required this.id,
    required this.peerFingerprint,
    required this.fileSha256,
    required this.total,
    required this.spans,
    required this.generation,
    required this.updatedUtc,
  });

  final String id;
  final String peerFingerprint;
  final String fileSha256;
  final int total;
  final List<LinearCheckpointSpan> spans;
  final int generation;
  final DateTime updatedUtc;
  int get committed => spans.isEmpty ? 0 : spans.last.end;

  Map<String, Object> toJson() => {
        'format': 'linyue-linear-checkpoint-v2',
        'id': id,
        'peer': peerFingerprint,
        'sourceSha256': fileSha256,
        'total': total,
        'step': linearCheckpointStepBytes,
        'generation': generation,
        'updatedUtc': updatedUtc.toUtc().toIso8601String(),
        'spans': spans.map((e) => e.toJson()).toList(),
      };

  factory LinearCheckpointRecord.fromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    final peer = raw['peer'];
    final digest = raw['sourceSha256'];
    final total = raw['total'];
    final generation = raw['generation'];
    final timestamp = raw['updatedUtc'];
    final spanList = raw['spans'];
    if (raw['format'] != 'linyue-linear-checkpoint-v2' ||
        id is! String || !_idFormat.hasMatch(id) ||
        peer is! String || !_hashFormat.hasMatch(peer) ||
        digest is! String || !_hashFormat.hasMatch(digest) ||
        total is! int || total <= 0 || total > linearCheckpointMaxBytes ||
        raw['step'] != linearCheckpointStepBytes ||
        generation is! int || generation < 0 ||
        timestamp is! String || spanList is! List ||
        spanList.length > (linearCheckpointMaxBytes ~/ linearCheckpointStepBytes) + 1) {
      throw const FormatException('invalid linear-v2 checkpoint');
    }
    final updated = DateTime.tryParse(timestamp)?.toUtc();
    if (updated == null || updated.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 5)))) {
      throw const FormatException('invalid checkpoint timestamp');
    }
    final spans = spanList.map((e) => LinearCheckpointSpan.fromJson(e)).toList(growable: false);
    var previous = 0;
    for (var i = 0; i < spans.length; i++) {
      final end = spans[i].end;
      final delta = end - previous;
      if (end > total || end <= previous ||
          (delta != linearCheckpointStepBytes && end != total) ||
          (end != total && end % linearCheckpointChunkBytes != 0) ||
          delta > linearCheckpointStepBytes) {
        throw const FormatException('misaligned or oversized checkpoint span');
      }
      previous = end;
    }
    if (spans.length > generation) {
      throw const FormatException('checkpoint generation lower than span count');
    }
    return LinearCheckpointRecord(id: id, peerFingerprint: peer,
      fileSha256: digest, total: total, spans: List.unmodifiable(spans),
      generation: generation, updatedUtc: updated);
  }
}

class LinearCheckpointInspection {
  const LinearCheckpointInspection(this.record, this.extraBytes);
  final LinearCheckpointRecord record;
  final int extraBytes;
}

/// V2 checkpoint: commit checks only newly flushed 4 MiB (or final tail).
/// Every inspect() re-reads and verifies EVERY committed span exactly once.
/// This is an integrity/performance tradeoff: changes to an OLD span during
/// an uninterrupted upload are detected at inspection or at final SHA-256,
/// not immediately on the next commit as in production v1.
///
/// Callers MUST flush authenticated plaintext BEFORE commit, and MUST use
/// inspect() and a fresh authenticated session before trusting resume offsets.
class LinearResumeCheckpointStore {
  LinearResumeCheckpointStore(this.directory, {this.maxAge = const Duration(hours: 24)});
  final Directory directory;
  final Duration maxAge;
  int commitHashedBytes = 0;
  int inspectionHashedBytes = 0;
  bool _committing = false;

  static String newId() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static void _id(String id) {
    if (!_idFormat.hasMatch(id)) throw const FormatException('invalid id');
  }

  File partFile(String id) {
    _id(id);
    return File('${directory.path}${Platform.pathSeparator}.linyue_resume_v2_$id.part');
  }

  File _slot(String id, int generation) {
    _id(id);
    return File('${directory.path}${Platform.pathSeparator}.linyue_resume_v2_$id.${generation.isEven ? 'a' : 'b'}.json');
  }

  Future<void> _write(LinearCheckpointRecord entry) async {
    final file = _slot(entry.id, entry.generation);
    await file.writeAsString(jsonEncode(entry.toJson()), flush: true);
  }

  Future<LinearCheckpointRecord?> _latest(String id) async {
    _id(id);
    final records = <LinearCheckpointRecord>[];
    for (var parity = 0; parity < 2; parity++) {
      final file = _slot(id, parity);
      if (!await file.exists()) continue;
      try {
        if (await file.length() > 32768) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) continue;
        final entry = LinearCheckpointRecord.fromJson(decoded);
        if (entry.id == id && entry.generation.isEven == parity.isEven) {
          records.add(entry);
        }
      } catch (_) {
        // A corrupt new slot never makes unverified suffix bytes trusted.
      }
    }
    if (records.isEmpty) return null;
    records.sort((a, b) => b.generation.compareTo(a.generation));
    return records.first;
  }

  Future<LinearCheckpointRecord> create({
    required String id,
    required String peerFingerprint,
    required String fileSha256,
    required int totalBytes,
  }) async {
    _id(id);
    if (!_hashFormat.hasMatch(peerFingerprint) || !_hashFormat.hasMatch(fileSha256) ||
        totalBytes <= 0 || totalBytes > linearCheckpointMaxBytes) {
      throw const FormatException('invalid peer, source SHA-256 or size');
    }
    await directory.create(recursive: true);
    if (await partFile(id).exists() || await _slot(id, 0).exists() ||
        await _slot(id, 1).exists()) {
      throw StateError('linear-v2 checkpoint already exists');
    }
    await partFile(id).writeAsBytes(const <int>[], flush: true);
    final record = LinearCheckpointRecord(id: id, peerFingerprint: peerFingerprint,
      fileSha256: fileSha256, total: totalBytes, spans: const [],
      generation: 0, updatedUtc: DateTime.now().toUtc());
    await _write(record);
    return record;
  }

  Future<LinearCheckpointRecord> commit(String id, int offset) async {
    if (_committing) throw StateError('parallel linear-v2 commits forbidden');
    _committing = true;
    try {
      final old = await _latest(id);
      if (old == null) throw StateError('linear-v2 checkpoint missing');
      final previous = old.committed;
      final delta = offset - previous;
      if (offset > old.total || delta <= 0 || delta > linearCheckpointStepBytes ||
          (delta != linearCheckpointStepBytes && offset != old.total) ||
          (offset != old.total && offset % linearCheckpointChunkBytes != 0)) {
        throw StateError('invalid commit offset or span size');
      }
      final file = partFile(id);
      if (!await file.exists() || await file.length() != offset) {
        throw StateError('linear-v2 file length does not equal committed offset');
      }
      // Only process newly flushed bytes, not the entire previous prefix.
      final fresh = (await crypto.sha256.bind(file.openRead(previous, offset)).first).toString();
      commitHashedBytes += delta;
      // Final source digest always verifies the ENTIRE file, even if older
      // committed bytes were modified since the last checkpoint.
      if (offset == old.total) {
        final whole = (await crypto.sha256.bind(file.openRead()).first).toString();
        commitHashedBytes += old.total;
        if (whole != old.fileSha256) {
          throw StateError('final original file SHA-256 mismatch');
        }
      }
      final updated = LinearCheckpointRecord(id: old.id,
        peerFingerprint: old.peerFingerprint, fileSha256: old.fileSha256,
        total: old.total,
        spans: List.unmodifiable([...old.spans, LinearCheckpointSpan(offset, fresh)]),
        generation: old.generation + 1, updatedUtc: DateTime.now().toUtc());
      await _write(updated);
      return updated;
    } finally {
      _committing = false;
    }
  }

  Future<LinearCheckpointInspection> inspect({
    required String id,
    required String expectedPeer,
    required String expectedSha256,
    required int expectedSize,
  }) async {
    final entry = await _latest(id);
    if (entry == null) throw StateError('checkpoint not found');
    if (entry.peerFingerprint != expectedPeer ||
        entry.fileSha256 != expectedSha256 || entry.total != expectedSize) {
      throw StateError('different authenticated peer or file identity');
    }
    final age = DateTime.now().toUtc().difference(entry.updatedUtc);
    if (age > maxAge || age < const Duration(minutes: -5)) {
      throw StateError('linear-v2 checkpoint expired');
    }
    final file = partFile(id);
    if (!await file.exists()) throw StateError('linear-v2 .part missing');
    final size = await file.length();
    if (size < entry.committed || size > entry.total) {
      throw StateError('V2 part length invalid');
    }
    var start = 0;
    for (final span in entry.spans) {
      final current = (await crypto.sha256.bind(file.openRead(start, span.end)).first).toString();
      inspectionHashedBytes += span.end - start;
      if (current != span.sha256) {
        throw StateError('previously committed data was modified');
      }
      start = span.end;
    }
    if (entry.committed == entry.total) {
      final actual = (await crypto.sha256.bind(file.openRead()).first).toString();
      inspectionHashedBytes += entry.total;
      if (actual != entry.fileSha256) {
        throw StateError('completed file SHA-256 mismatch');
      }
    }
    return LinearCheckpointInspection(entry, size - entry.committed);
  }

  /// Never trust bytes beyond the durable, re-verified V2 journal.
  /// Re-inspect immediately before truncation to catch intervening changes.
  Future<int> truncateUncommitted(LinearCheckpointInspection point) async {
    final fresh = await inspect(id: point.record.id,
      expectedPeer: point.record.peerFingerprint,
      expectedSha256: point.record.fileSha256,
      expectedSize: point.record.total);
    if (fresh.record.generation != point.record.generation ||
        fresh.record.committed != point.record.committed) {
      throw StateError('V2 checkpoint changed after inspection');
    }
    final writer = await partFile(point.record.id).open(mode: FileMode.append);
    try {
      await writer.truncate(fresh.record.committed);
      await writer.flush();
    } finally {
      await writer.close();
    }
    return fresh.record.committed;
  }

  Future<void> discard(String id) async {
    _id(id);
    for (final file in [partFile(id), _slot(id, 0), _slot(id, 1)]) {
      if (await file.exists()) await file.delete();
    }
  }
}
