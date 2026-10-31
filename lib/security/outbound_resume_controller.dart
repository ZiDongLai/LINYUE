/// DEV10-E2: serial, crash-safe sender source staging and journal operations.
/// Files are copied into application-private storage BEFORE entering the
/// transfer queue. No content URIs, cryptographic keys or authorization
/// tokens are persisted in the recovery record.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'outbound_resume_journal.dart';


/// DEV11-A: reported results of an explicit, user-confirmed cleanup.
/// A skipped task remains in the journal; nothing outside the private staging
/// directory is ever intentionally deleted.
class ExpiredResumeCleanupReport {
  const ExpiredResumeCleanupReport({
    required this.removedTasks,
    required this.deletedFiles,
    required this.freedBytes,
    required this.skippedTasks,
  });
  final int removedTasks;
  final int deletedFiles;
  final int freedBytes;
  final int skippedTasks;
}

/// DEV12-D4B2: a cleanup replay only touches journal-authorized, private
/// source paths. A failed task remains cleanupPending and cannot be resent.
class OutboundCleanupReplayReport {
  const OutboundCleanupReplayReport({required this.completed,
    required this.failedTaskIds});
  final int completed;
  final List<String> failedTaskIds;
  int get failed => failedTaskIds.length;
}

class OutboundResumeController {
  OutboundResumeController({required this.journal, required this.sourcesDirectory,
    this.maxStagedBytes = 2560 * 1024 * 1024});

  final OutboundResumeJournal journal;
  final Directory sourcesDirectory;
  final int maxStagedBytes;
  Future<void> _tail = Future<void>.value();

  Future<T> _exclusive<T>(Future<T> Function() task) async {
    final previous = _tail;
    final signal = Completer<void>();
    _tail = signal.future;
    await previous;
    try { return await task(); } finally { signal.complete(); }
  }

  Future<List<OutboundResumeRecord>> load() => _exclusive(journal.load);

  String _safeFilename(String input) {
    final name = input.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (name.isEmpty || name == '.' || name == '..') {
      throw const FormatException('invalid staged file name');
    }
    return name.length <= 120 ? name : name.substring(name.length - 120);
  }

  String _randomFolder() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Reserve a durable private copy of a 20 MiB–1 GiB picker/drop source.
  /// Serializing staging with journal writes prevents lost updates when a
  /// second drag arrives during the first copy. No user source is deleted.
  Future<OutboundResumeRecord> prepare({
    required Stream<List<int>> source,
    required String name,
    required int expectedBytes,
    required String peerFingerprint,
  }) => _exclusive(() async {
    if (expectedBytes < journal.minBytes || expectedBytes > journal.maxBytes) {
      throw StateError('only 20 MiB–1 GiB files can be staged for resume');
    }
    final existing = await journal.load();
    if (existing.length >= outboundResumeMaxItems ||
        existing.fold<int>(0, (sum, r) => sum + r.fileBytes) + expectedBytes > maxStagedBytes) {
      throw StateError('未完成任务占用空间过多，请先完成队列中的文件');
    }
    final folder = Directory('${sourcesDirectory.path}${Platform.pathSeparator}${_randomFolder()}');
    await folder.create(recursive: true);
    final file = File('${folder.path}${Platform.pathSeparator}${_safeFilename(name)}');
    final temp = File('${file.path}.writing');
    try {
      final sink = temp.openWrite();
      var copied = 0;
      try {
        await for (final chunk in source) {
          copied += chunk.length;
          if (copied > expectedBytes || copied > journal.maxBytes) {
            throw StateError('source length changed while staging');
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (copied != expectedBytes || await temp.length() != expectedBytes) {
        throw StateError('incomplete staged file');
      }
      await temp.rename(file.path);
      final record = await journal.inspectNewSource(file: file,
        peerFingerprint: peerFingerprint);
      await journal.save([...existing, record]);
      return record;
    } catch (_) {
      if (await folder.exists()) {
        try { await folder.delete(recursive: true); } catch (_) {}
      }
      rethrow;
    }
  });

  Future<void> mark(OutboundResumeRecord record, OutboundResumeStatus status) =>
    _exclusive(() async {
      final records = await journal.load();
      final matching = [for (final r in records)
        if (r.taskId == record.taskId) r];
      if (matching.length != 1 ||
          matching.single.status == OutboundResumeStatus.cleanupPending ||
          status == OutboundResumeStatus.cleanupPending) {
        throw StateError('resume task missing or cleanup already pending');
      }
      await journal.save([
        for (final item in records)
          item.taskId == record.taskId ? item.withStatus(status) : item,
      ]);
    });

  /// Finalize a finished, refused or explicitly cancelled transfer.
  ///
  /// Crash-safe order: validate the EXACT journal source first, persist a
  /// cleanupPending intent, delete ONLY that regular private source, then
  /// remove its journal entry. A restart replays only cleanupPending entries.
  /// No unknown or orphan source is ever deleted.
  Future<void> forget(OutboundResumeRecord record) =>
      _exclusive(() => _forgetUnlocked(record));

  Future<void> _forgetUnlocked(OutboundResumeRecord record) async {
    final records = await journal.load();
    final matching = <OutboundResumeRecord>[
      for (final r in records) if (r.taskId == record.taskId) r,
    ];
    if (matching.isEmpty) return;
    if (matching.length != 1) {
      throw StateError('duplicate resume task; refusing cleanup');
    }
    final saved = matching.single;
    if (saved.sourcePath != record.sourcePath ||
        saved.peerFingerprint != record.peerFingerprint ||
        saved.fileSha256 != record.fileSha256 ||
        saved.fileBytes != record.fileBytes) {
      throw StateError('resume task changed; refusing cleanup');
    }
    // Validate before recording the destructive intent, including on replay.
    final file = await _checkedCleanupFile(saved, records);
    if (saved.status != OutboundResumeStatus.cleanupPending) {
      await journal.save([
        for (final r in records)
          r.taskId == saved.taskId
            ? r.withStatus(OutboundResumeStatus.cleanupPending) : r,
      ]);
    }
    // If this deletion has already happened before a crash, the missing file
    // is safe to accept only because the journal persists cleanupPending.
    final kind = await FileSystemEntity.type(file.path, followLinks: false);
    if (kind == FileSystemEntityType.file) {
      await file.delete();
    } else if (kind != FileSystemEntityType.notFound) {
      throw StateError('staged source changed type; cleanup stopped');
    }
    final latest = await journal.load();
    final intent = [for (final r in latest) if (r.taskId == saved.taskId) r];
    if (intent.length != 1 ||
        intent.single.status != OutboundResumeStatus.cleanupPending ||
        intent.single.sourcePath != saved.sourcePath ||
        latest.any((r) => r.taskId != saved.taskId &&
            r.sourcePath == saved.sourcePath)) {
      throw StateError('cleanup intent changed; journal retained');
    }
    await journal.save([
      for (final r in latest) if (r.taskId != saved.taskId) r,
    ]);
    try {
      final folder = file.parent;
      if (await folder.list(followLinks: false).isEmpty) {
        await folder.delete();
      }
    } catch (_) { /* Pruning an EMPTY directory is best effort only. */ }
  }

  Future<File> _checkedCleanupFile(OutboundResumeRecord saved,
      List<OutboundResumeRecord> records) async {
    if (records.any((r) => r.taskId != saved.taskId &&
        r.sourcePath == saved.sourcePath)) {
      throw StateError('staged source referenced by another task');
    }
    final file = File(saved.sourcePath);
    final folder = file.parent;
    final root = sourcesDirectory.absolute.path;
    final folderName = folder.uri.pathSegments
        .where((part) => part.isNotEmpty).last;
    if (saved.sourcePath.split(Platform.pathSeparator).contains('..') ||
        file.absolute.path != saved.sourcePath ||
        folder.parent.absolute.path != root ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(folderName) ||
        file.uri.pathSegments.last != saved.fileName) {
      throw StateError('resume source outside private staging root');
    }
    final rootKind = await FileSystemEntity.type(root, followLinks: false);
    final folderKind = await FileSystemEntity.type(folder.path,
        followLinks: false);
    final fileKind = await FileSystemEntity.type(file.path,
        followLinks: false);
    if (rootKind != FileSystemEntityType.directory ||
        folderKind != FileSystemEntityType.directory ||
        (fileKind != FileSystemEntityType.file &&
         fileKind != FileSystemEntityType.notFound) ||
        await sourcesDirectory.resolveSymbolicLinks() !=
            await folder.parent.resolveSymbolicLinks()) {
      throw StateError('unsafe source path; cleanup refused');
    }
    return file;
  }

  /// Invoke ONCE during startup BEFORE enqueuing any restored jobs.
  /// Only previously authorized cleanupPending records can be finalized.
  /// Invalid paths, shared sources and journal corruption remain untouched.
  Future<OutboundCleanupReplayReport> reconcileCleanupIntents() =>
      _exclusive(() async {
        final records = await journal.load(); // Corrupt journal fails closed.
        final failures = <String>[];
        var completed = 0;
        for (final record in records) {
          if (record.status != OutboundResumeStatus.cleanupPending) continue;
          try {
            await _forgetUnlocked(record);
            completed++;
          } catch (_) {
            failures.add(record.taskId);
          }
        }
        return OutboundCleanupReplayReport(completed: completed,
          failedTaskIds: List.unmodifiable(failures));
      });

  /// Explicit cleanup of out-of-date recovery sources, never an automatic
  /// background deletion. The caller MUST protect queued/active task IDs and
  /// avoid starting a new send while the cleanup is in progress.
  ///
  /// Only the exact journal-listed file directly inside a random 32-hex
  /// subdirectory of [sourcesDirectory] can be removed. We never delete a
  /// user's picker original, a symlink, or an unrelated sibling file.
  /// Journal corruption fails closed before deleting any file.
  Future<ExpiredResumeCleanupReport> cleanupExpired({
    DateTime? now,
    Set<String> protectedTaskIds = const <String>{},
  }) => _exclusive(() async {
    final at = (now ?? DateTime.now()).toUtc();
    final records = await journal.load();
    final expired = <OutboundResumeRecord>[
      for (final r in records)
        if (at.difference(r.createdUtc) > journal.maxAge &&
            !protectedTaskIds.contains(r.taskId)) r,
    ];
    var removed = 0;
    var deleted = 0;
    var freedBytes = 0;
    var skipped = 0;
    for (final record in expired) {
      try {
        // No in-flight task may share this path, nor any active task's
        // staging directory. Unknown siblings are NEVER removed.
        final others = await journal.load();
        final ownFolder = File(record.sourcePath).parent.absolute.path;
        if (others.any((r) => r.taskId != record.taskId &&
            (r.sourcePath == record.sourcePath ||
             (protectedTaskIds.contains(r.taskId) &&
              File(r.sourcePath).parent.absolute.path == ownFolder)))) {
          skipped++;
          continue;
        }
        final file = await _checkedCleanupFile(record, others);
        final exists = await FileSystemEntity.type(file.path,
            followLinks: false) == FileSystemEntityType.file;
        final size = exists ? await file.length() : 0;
        await _forgetUnlocked(record);
        removed++;
        if (exists) {
          deleted++;
          freedBytes += size;
        }
      } catch (_) {
        // If the deletion was interrupted, cleanupPending is left behind;
        // a later startup will safely replay it. Never guess deletions.
        skipped++;
      }
    }
    return ExpiredResumeCleanupReport(removedTasks: removed,
      deletedFiles: deleted, freedBytes: freedBytes, skippedTasks: skipped);
  });

  Future<OutboundRestoreCheck> verify(OutboundResumeRecord record,
      {required String authenticatedFingerprint}) async {
    if (record.status == OutboundResumeStatus.cleanupPending) {
      return OutboundRestoreCheck.sourceMissing;
    }
    if (record.peerFingerprint != authenticatedFingerprint) {
      return OutboundRestoreCheck.peerUntrusted;
    }
    return journal.checkForRestore(record,
      trustedFingerprints: {authenticatedFingerprint});
  }
}
