/// DEV12-D4B1: read-only inspection of outbound resume storage.
///
/// This does NOT trust a journal as authorization, hash source contents,
/// delete files, rewrite journal slots, or resume transfers. The sender must
/// still rehash sources and reauthenticate the peer before each real resume.
import 'dart:io';

import 'outbound_resume_journal.dart';

enum OutboundAuditCode {
  journalUnreadable,
  unsafeStagingRoot,
  stagingRootMissing,
  outsideStagingRoot,
  duplicateSource,
  unsafeSourcePath,
  sourceMissing,
  sourceSizeChanged,
  orphanDirectory,
  unexpectedStagingEntry,
}

class OutboundAuditIssue {
  const OutboundAuditIssue(this.code, {required this.path, this.taskId});
  final OutboundAuditCode code;
  final String path;
  final String? taskId;
}

class OutboundAuditReport {
  const OutboundAuditReport({required this.issues, required this.tasksRead,
    required this.activeTasksSkipped});
  final List<OutboundAuditIssue> issues;
  final int tasksRead;
  final int activeTasksSkipped;
  bool get clean => issues.isEmpty;
  bool has(OutboundAuditCode code) => issues.any((i) => i.code == code);
}

/// A bounded, metadata-only snapshot; NEVER performs automatic cleanup.
///
/// In-flight file lengths can change; pass the IDs of all queued/active
/// tasks to avoid mistaking a legitimate write for corruption. Path checks
/// are lexical plus no-follow filesystem types; this is a diagnostic, not a
/// secure delete authorization, and it does not claim to eliminate TOCTOU.
class OutboundConsistencyAudit {
  const OutboundConsistencyAudit({required this.journal,
    required this.sourcesDirectory});
  final OutboundResumeJournal journal;
  final Directory sourcesDirectory;

  static final RegExp _folderId = RegExp(r'^[a-f0-9]{32}$');
  static final RegExp _parentHop = RegExp(r'(^|[\\/])\.\.([\\/]|$)');

  Future<OutboundAuditReport> inspect({
    Set<String> activeTaskIds = const <String>{},
  }) async {
    final issues = <OutboundAuditIssue>[];
    List<OutboundResumeRecord> records;
    try {
      records = await journal.load();
    } catch (_) {
      // Do not scan for orphans when the task journal is untrustworthy.
      return OutboundAuditReport(issues: [OutboundAuditIssue(
        OutboundAuditCode.journalUnreadable, path: journal.directory.path,
      )], tasksRead: 0, activeTasksSkipped: 0);
    }
    final root = sourcesDirectory.absolute;
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType == FileSystemEntityType.notFound) {
      // Missing staging root is itself an issue, but it must NOT mask
      // journal entries that refer to paths outside the staging boundary.
      // Continue with per-record validation; never create/scan this root.
      if (records.isNotEmpty) {
        issues.add(OutboundAuditIssue(OutboundAuditCode.stagingRootMissing,
          path: root.path));
      }
    } else if (rootType != FileSystemEntityType.directory) {
      return OutboundAuditReport(issues: [OutboundAuditIssue(
        OutboundAuditCode.unsafeStagingRoot, path: root.path,
      )], tasksRead: records.length, activeTasksSkipped: 0);
    }

    final referencedFolders = <String>{};
    final sourceOwners = <String, String>{};
    var activeSkipped = 0;
    for (final record in records) {
      final source = File(record.sourcePath);
      final folder = source.parent.absolute;
      final folderName = folder.path.split(Platform.pathSeparator).last;
      final valid = !_parentHop.hasMatch(record.sourcePath) &&
          source.absolute.path == record.sourcePath &&
          folder.parent.absolute.path == root.path &&
          _folderId.hasMatch(folderName) &&
          source.path.split(Platform.pathSeparator).last == record.fileName;
      if (!valid) {
        issues.add(OutboundAuditIssue(OutboundAuditCode.outsideStagingRoot,
          path: record.sourcePath, taskId: record.taskId));
        continue;
      }
      referencedFolders.add(folder.path);
      final previousOwner = sourceOwners[record.sourcePath];
      if (previousOwner != null && previousOwner != record.taskId) {
        issues.add(OutboundAuditIssue(OutboundAuditCode.duplicateSource,
          path: record.sourcePath, taskId: record.taskId));
      }
      sourceOwners[record.sourcePath] = record.taskId;
      final folderType = await FileSystemEntity.type(folder.path,
        followLinks: false);
      if (folderType == FileSystemEntityType.notFound) {
        issues.add(OutboundAuditIssue(OutboundAuditCode.sourceMissing,
          path: record.sourcePath, taskId: record.taskId));
        continue;
      }
      if (folderType != FileSystemEntityType.directory) {
        issues.add(OutboundAuditIssue(OutboundAuditCode.unsafeSourcePath,
          path: folder.path, taskId: record.taskId));
        continue;
      }
      final type = await FileSystemEntity.type(source.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        issues.add(OutboundAuditIssue(OutboundAuditCode.sourceMissing,
          path: source.path, taskId: record.taskId));
      } else if (type != FileSystemEntityType.file) {
        issues.add(OutboundAuditIssue(OutboundAuditCode.unsafeSourcePath,
          path: source.path, taskId: record.taskId));
      } else if (activeTaskIds.contains(record.taskId)) {
        activeSkipped++;
      } else {
        try {
          if (await source.length() != record.fileBytes) {
            issues.add(OutboundAuditIssue(OutboundAuditCode.sourceSizeChanged,
              path: source.path, taskId: record.taskId));
          }
        } on FileSystemException {
          issues.add(OutboundAuditIssue(OutboundAuditCode.unsafeSourcePath,
            path: source.path, taskId: record.taskId));
        }
      }
    }

    if (rootType == FileSystemEntityType.directory) {
      try {
        await for (final entity in root.list(followLinks: false)) {
        final type = await FileSystemEntity.type(entity.path, followLinks: false);
        final name = entity.path.split(Platform.pathSeparator).last;
        if (type == FileSystemEntityType.directory &&
            _folderId.hasMatch(name)) {
          if (!referencedFolders.contains(Directory(entity.path).absolute.path)) {
            issues.add(OutboundAuditIssue(OutboundAuditCode.orphanDirectory,
              path: entity.path));
          }
        } else {
          issues.add(OutboundAuditIssue(OutboundAuditCode.unexpectedStagingEntry,
            path: entity.path));
        }
      }
      } on FileSystemException {
        issues.add(OutboundAuditIssue(OutboundAuditCode.unsafeStagingRoot,
          path: root.path));
      }
    }
    return OutboundAuditReport(issues: List.unmodifiable(issues),
      tasksRead: records.length, activeTasksSkipped: activeSkipped);
  }
}
