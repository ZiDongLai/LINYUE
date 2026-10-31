import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'checkpoint_model.dart';
export 'checkpoint_model.dart';

enum BtCheckpointFaultPoint {
  beforeDataFlush,
  afterDataFlush,
  afterDataVerified,
  afterTransactionBegin,
  afterRecordWrite,
  beforePublish,
  afterPublish,
}

class BtCheckpointException implements Exception {
  const BtCheckpointException(this.code, this.phase, [this.details = const {}]);
  final String code, phase;
  final Map<String, Object?> details;
  @override
  String toString() => 'P0 checkpoint $code at $phase $details';
}

/// Returned only after actual prefix verification and the prescribed file
/// flush / metadata publication / readback contract. Not a remote ACK, final
/// inbox commit, parent-directory fsync or power-loss durability certificate.
class BtPersistedCheckpoint {
  const BtPersistedCheckpoint._(this.record);
  final BtCheckpointRecord record;
  String get durabilityContract => 'file-flush+immutable-rename+readback-p0-v1';
}

/// E40-P0 standalone primitive. No socket, LAN journal, recovery loop or delete
/// API. Caller supplies an isolated/private base; never pass an E38 work root.
/// Data writers must be quiescent during store calls. Only this namespace is
/// touched. A crash-stale lock/transaction is rejected, never auto-repaired.
class BtCheckpointStore {
  BtCheckpointStore({
    required this.baseDirectory,
    this.clock = DateTime.now,
    this.fault,
  });
  final Directory baseDirectory;
  final DateTime Function() clock;
  final Future<void> Function(BtCheckpointFaultPoint)? fault;
  static const namespace = '.linyue_bt_checkpoint_p0_v1';
  static const maxTasks = 4, maxRecords = 256, maxRecordBytes = 8192;
  static const maxRegisteredBytes = 4 * 10485760;
  static final _tails = <String, Future<void>>{};
  String _phase = 'idle';

  Future<void> _point(BtCheckpointFaultPoint p) async {
    _phase = p.name;
    await fault?.call(p);
  }

  Never _fail(String code, [Map<String, Object?> details = const {}]) =>
      throw BtCheckpointException(code, _phase, details);
  bool _samePath(String a, String b) =>
      Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  Future<void> _directory(Directory dir) async {
    if (await FileSystemEntity.type(dir.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !_samePath(await dir.resolveSymbolicLinks(), dir.absolute.path)) {
      _fail('unsafe_directory');
    }
  }

  Future<void> _file(File f) async {
    if (await FileSystemEntity.type(f.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !_samePath(await f.resolveSymbolicLinks(), f.absolute.path)) {
      _fail('missing_or_unsafe_file');
    }
  }

  Future<Directory> _root() async {
    _phase = 'namespace';
    await _directory(baseDirectory);
    final root = Directory(
      '${baseDirectory.absolute.path}${Platform.pathSeparator}$namespace',
    );
    final kind = await FileSystemEntity.type(root.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) await root.create();
    await _directory(root);
    final marker = File('${root.path}${Platform.pathSeparator}namespace.json');
    if (!await marker.exists()) {
      if (await root.list(followLinks: false).isEmpty != true) {
        _fail('unowned_namespace');
      }
      await marker.create(exclusive: true);
      await marker.writeAsString(
        jsonEncode({'schema': btCheckpointSchema}),
        flush: true,
      );
    }
    await _file(marker);
    if (await marker.length() > 1024 ||
        await marker.readAsString() !=
            jsonEncode({'schema': btCheckpointSchema})) {
      _fail('unsupported_namespace');
    }
    return root;
  }

  Future<T> _locked<T>(Future<T> Function(Directory root) action) async {
    // Shared-isolate serialization; exclusive file creation also protects
    // cooperating other isolates/processes (busy fails closed, no stale unlock).
    final key = baseDirectory.absolute.path.toLowerCase();
    final previous = _tails[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _tails[key] = gate.future;
    await previous;
    File? lock;
    String? owner;
    try {
      final root = await _root();
      lock = File('${root.path}${Platform.pathSeparator}.writer_lock');
      _phase = 'lock';
      if (await FileSystemEntity.type(lock.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _fail('busy_or_stale_lock');
      }
      try {
        await lock.create(exclusive: true);
      } on FileSystemException {
        _fail('busy_or_stale_lock');
      }
      owner = BtCheckpointIdentity.newId();
      await lock.writeAsString(owner, flush: true);
      return await action(root);
    } on FileSystemException catch (e) {
      throw BtCheckpointException('io_failure', _phase, {
        'osError': e.osError?.errorCode,
      });
    } finally {
      try {
        if (owner != null && lock != null) {
          await _file(lock);
          if (await lock.readAsString() != owner) _fail('lock_owner_changed');
          await lock
              .delete(); // Only the exact new lock owned by this operation.
        }
      } finally {
        gate.complete();
        if (identical(_tails[key], gate.future)) _tails.remove(key);
      }
    }
  }

  Directory _task(Directory root, BtCheckpointIdentity id) =>
      Directory('${root.path}${Platform.pathSeparator}${id.taskId}');
  File _data(Directory task, BtCheckpointIdentity id) =>
      File('${task.path}${Platform.pathSeparator}${id.dataBinding}.part');
  File _record(Directory task, int gen) => File(
    '${task.path}${Platform.pathSeparator}g${gen.toString().padLeft(3, '0')}.json',
  );
  File _transaction(Directory task) =>
      File('${task.path}${Platform.pathSeparator}.transaction');

  Future<String> _verifyData(
    Directory task,
    BtCheckpointRecord record, {
    bool flush = false,
  }) async {
    await _directory(task);
    final file = _data(task, record.identity);
    await _file(file);
    final length = await file.length();
    if (length < record.offset || length > record.identity.fileSize) {
      _fail('data_length_mismatch', {
        'generation': record.generation,
        'offset': record.offset,
        'actualLength': length,
      });
    }
    if (flush) {
      await _point(BtCheckpointFaultPoint.beforeDataFlush);
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      await _point(BtCheckpointFaultPoint.afterDataFlush);
    }
    final hash =
        (await hashes.sha256.bind(file.openRead(0, record.offset)).first)
            .toString();
    if (await file.length() != length) {
      _fail('data_changed_during_verification');
    }
    if (hash != record.prefixSha256) {
      _fail('data_prefix_mismatch', {'offset': record.offset});
    }
    return hash;
  }

  Future<BtCheckpointRecord> _read(
    Directory root,
    BtCheckpointIdentity expected,
  ) async {
    _phase = 'read';
    final dir = _task(root, expected);
    await _directory(dir);
    if (await FileSystemEntity.type(
          _transaction(dir).path,
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      _fail('unsettled_transaction');
    }
    final entries = await dir.list(followLinks: false).toList();
    if (entries.length > maxRecords + 1) _fail('record_quota');
    final paths = <File>[];
    for (final e in entries) {
      final name = e.uri.pathSegments.last;
      if (name == '${expected.dataBinding}.part') continue;
      if (e is! File || !RegExp(r'^g\d{3}\.json$').hasMatch(name)) {
        _fail('unknown_task_entry');
      }
      paths.add(e);
    }
    paths.sort((a, b) => a.path.compareTo(b.path));
    if (paths.isEmpty) _fail('missing_record');
    BtCheckpointRecord? last;
    for (var i = 0; i < paths.length; i++) {
      final file = paths[i];
      await _file(file);
      if (file.path != _record(dir, i).path ||
          await file.length() > maxRecordBytes) {
        _fail('record_gap_or_oversize');
      }
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is! Map<String, dynamic> ||
            raw.length != 2 ||
            raw['record'] is! Map<String, dynamic> ||
            raw['sha256'] is! String) {
          _fail('invalid_envelope');
        }
        final record = BtCheckpointRecord.fromJson(
          raw['record'] as Map<String, dynamic>,
        );
        if (record.digest != raw['sha256'] || record.generation != i) {
          _fail('checksum_or_generation_mismatch');
        }
        if (!record.identity.sameAs(expected)) _fail('identity_mismatch');
        if (last != null) {
          last.validateNext(record);
        } else if (record.generation != 0 ||
            record.offset != 0 ||
            record.status != BtCheckpointStatus.created) {
          _fail('invalid_initial_record');
        }
        last = record;
      } on BtCheckpointException {
        rethrow;
      } catch (_) {
        _fail('corrupt_or_unsupported_record');
      }
    }
    await _verifyData(dir, last!);
    return last;
  }

  Future<void> _publish(Directory task, BtCheckpointRecord record) async {
    // An unsettled marker is deliberately retained on ANY mid-commit error.
    // No read may guess an offset from old/candidate records in this state.
    _phase = 'transaction_begin';
    final transaction = _transaction(task);
    await transaction.create(exclusive: true);
    await transaction.writeAsString(
      jsonEncode({
        'schema': btCheckpointSchema,
        'generation': record.generation,
        'digest': record.digest,
      }),
      flush: true,
    );
    await _point(BtCheckpointFaultPoint.afterTransactionBegin);
    final target = _record(task, record.generation);
    final temp = File('${target.path}.writing');
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _fail('record_exists');
    }
    await temp.create(exclusive: true);
    final encoded = jsonEncode({
      'record': record.toJson(),
      'sha256': record.digest,
    });
    if (utf8.encode(encoded).length > maxRecordBytes) _fail('record_oversize');
    await temp.writeAsString(encoded, flush: true);
    if (await temp.readAsString() != encoded) _fail('metadata_readback');
    await _point(BtCheckpointFaultPoint.afterRecordWrite);
    await _point(BtCheckpointFaultPoint.beforePublish);
    await temp.rename(target.path); // Same-directory, immutable new generation.
    await _file(target);
    if (await target.readAsString() != encoded) _fail('published_readback');
    await _point(BtCheckpointFaultPoint.afterPublish);
    _phase = 'published_data_readback';
    await _verifyData(task, record);
    _phase = 'transaction_finish';
    await transaction.delete(); // Commit point, after data/metadata/readback.
  }

  /// Registers a NEW local task and an empty private data file. Never scans
  /// E38 receive/results directories and never overwrites an existing task.
  Future<BtPersistedCheckpoint> createTask(
    BtCheckpointIdentity identity,
  ) => _locked((root) async {
    _phase = 'create';
    final task = _task(root, identity);
    if (await FileSystemEntity.type(task.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _fail('task_exists');
    }
    final entries = await root.list(followLinks: false).toList();
    var count = 0, bytes = 0;
    for (final entry in entries) {
      final name = entry.path
          .split(RegExp(r'[/\\]'))
          .where((p) => p.isNotEmpty)
          .last;
      if (name == 'namespace.json' || name == '.writer_lock') continue;
      if (entry is! Directory || !RegExp(r'^[a-f0-9]{32}$').hasMatch(name)) {
        _fail('unknown_namespace_entry');
      }
      count++;
      // Quota includes terminal tasks: no automatic deletion in P0.
      final records = await entry
          .list(followLinks: false)
          .where(
            (e) =>
                e is File &&
                RegExp(r'^g\d{3}\.json$').hasMatch(e.uri.pathSegments.last),
          )
          .cast<File>()
          .toList();
      if (records.isEmpty || records.length > maxRecords) {
        _fail('unregistered_task_directory');
      }
      records.sort((a, b) => a.path.compareTo(b.path));
      await _file(records.last);
      if (await records.last.length() > maxRecordBytes) {
        _fail('record_oversize');
      }
      final raw =
          jsonDecode(await records.last.readAsString()) as Map<String, dynamic>;
      final other = BtCheckpointRecord.fromJson(
        raw['record'] as Map<String, dynamic>,
      );
      if (other.identity.taskId != name) _fail('task_directory_mismatch');
      await _read(root, other.identity);
      bytes += other.identity.fileSize;
    }
    if (count >= maxTasks || bytes + identity.fileSize > maxRegisteredBytes) {
      _fail('task_quota');
    }
    final now = clock().toUtc();
    final first = BtCheckpointRecord(
      identity: identity,
      generation: 0,
      previousHash: '',
      offset: 0,
      prefixSha256: btCheckpointEmptySha256,
      status: BtCheckpointStatus.created,
      createdUtc: now,
      updatedUtc: now,
    );
    await task.create();
    await _directory(task);
    await _data(task, identity).create(exclusive: true);
    await _verifyData(task, first, flush: true);
    await _point(BtCheckpointFaultPoint.afterDataVerified);
    await _publish(task, first);
    return BtPersistedCheckpoint._(first);
  });

  /// Caller-owned staging port, NOT a transport writer. The caller must stop
  /// writing before checkpoint/load; P0 never appends, truncates or deletes data.
  Future<File> dataFile(BtCheckpointIdentity expected) => _locked((root) async {
    await _read(root, expected);
    return _data(_task(root, expected), expected);
  });
  Future<BtPersistedCheckpoint> load(BtCheckpointIdentity expected) => _locked(
    (root) async => BtPersistedCheckpoint._(await _read(root, expected)),
  );

  /// No ACK/byte-count may create a receipt: file flush and disk prefix hash
  /// happen here. No reset/backwards update API or automatic recovery exists.
  Future<BtPersistedCheckpoint> checkpoint(
    BtCheckpointIdentity expected, {
    required int offset,
    required int expectedGeneration,
    BtCheckpointStatus status = BtCheckpointStatus.active,
    String? terminalReason,
  }) => _locked((root) async {
    final current = await _read(root, expected);
    final task = _task(root, expected);
    if (expectedGeneration < 0 || expectedGeneration > current.generation) {
      _fail('generation_conflict');
    }
    if (offset < current.offset || offset > expected.fileSize) {
      _fail('offset_regression_or_range');
    }
    final same =
        offset == current.offset &&
        status == current.status &&
        terminalReason == current.terminalReason;
    if (!same && expectedGeneration != current.generation) {
      _fail('generation_conflict');
    }
    if (current.status.isTerminal && !same) _fail('terminal_task');
    if (status == BtCheckpointStatus.created && !same) {
      _fail('invalid_transition');
    }
    // Derive digest from real bounded file data; never from a received ACK.
    final file = _data(task, expected);
    await _file(file);
    final length = await file.length();
    if (length < offset || length > expected.fileSize) {
      _fail('data_length_mismatch', {'offset': offset, 'actualLength': length});
    }
    await _point(BtCheckpointFaultPoint.beforeDataFlush);
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    await _point(BtCheckpointFaultPoint.afterDataFlush);
    await _verifyData(task, current);
    final prefix = (await hashes.sha256.bind(file.openRead(0, offset)).first)
        .toString();
    if (await file.length() != length) {
      _fail('data_changed_during_verification');
    }
    if (offset == expected.fileSize && prefix != expected.fileSha256) {
      _fail('whole_sha256_mismatch');
    }
    if (same) {
      if (prefix != current.prefixSha256) _fail('data_prefix_mismatch');
      return BtPersistedCheckpoint._(current);
    }
    if (current.generation + 1 >= maxRecords) _fail('record_quota');
    final next = BtCheckpointRecord(
      identity: expected,
      generation: current.generation + 1,
      previousHash: current.digest,
      offset: offset,
      prefixSha256: prefix,
      status: status,
      createdUtc: current.createdUtc,
      updatedUtc: clock().toUtc(),
      terminalReason: terminalReason,
    );
    current.validateNext(next);
    await _point(BtCheckpointFaultPoint.afterDataVerified);
    await _publish(task, next);
    return BtPersistedCheckpoint._(next);
  });
}
