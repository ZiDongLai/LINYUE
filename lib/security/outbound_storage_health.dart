/// DEV11-B1: read-only inspection of application-private outbound staging.
/// Does not hash contents (DEV10-E2 checks SHA-256 before resuming),
/// delete files, probe global disk free space or reinterpret journal failures.
import 'dart:io';

import 'outbound_resume_controller.dart';
import 'outbound_resume_journal.dart';

class OutboundStorageHealthReport {
  const OutboundStorageHealthReport({
    required this.recordedTasks,
    required this.expiredTasks,
    required this.recordedBytes,
    required this.measuredStagingBytes,
    required this.orphanFolders,
    required this.orphanBytes,
    required this.missingSources,
    required this.sizeMismatchSources,
    required this.unsafeReferences,
    required this.unknownEntries,
    required this.scanComplete,
    required this.stagingQuotaBytes,
  });

  final int recordedTasks;
  final int expiredTasks;
  final int recordedBytes;
  /// Sum of sizes of regular files which the bounded scan could inspect.
  /// May be an underestimate when [scanComplete] is false.
  final int measuredStagingBytes;
  /// Candidate orphan folder: a direct private `sources/<32-hex>` directory
  /// with no journal reference. This is only a warning, never deletion proof.
  final int orphanFolders;
  final int orphanBytes;
  final int missingSources;
  final int sizeMismatchSources;
  final int unsafeReferences;
  final int unknownEntries;
  final bool scanComplete;
  /// Application staging budget, NOT device free-disk bytes.
  final int stagingQuotaBytes;

  bool get nearingQuota => recordedBytes >= stagingQuotaBytes * 8 ~/ 10;
  bool get hasProblems => orphanFolders > 0 || missingSources > 0 ||
      sizeMismatchSources > 0 || unsafeReferences > 0 ||
      unknownEntries > 0 || expiredTasks > 0 || !scanComplete || nearingQuota;
}

class OutboundStorageHealthInspector {
  const OutboundStorageHealthInspector(this.controller);
  final OutboundResumeController controller;

  static final RegExp _randomFolder = RegExp(r'^[a-f0-9]{32}$');
  static const int maxFolders = 500;
  static const int maxEntriesPerFolder = 100;

  /// Read-only. Caller should run when no send/prepare/cleanup operation is
  /// active. A damaged dual-slot journal throws; it is never 'repaired'.
  Future<OutboundStorageHealthReport> inspect({DateTime? now}) async {
    final records = await controller.load();
    final root = controller.sourcesDirectory;
    final rootPath = root.absolute.path;
    final clock = (now ?? DateTime.now()).toUtc();
    final referenced = <String>{};
    var unsafe = 0;
    var missing = 0;
    var mismatched = 0;
    var expired = 0;
    var recordedBytes = 0;

    // Journal entries are metadata, NOT proof of a valid on-disk source.
    // Validate lexical containment before accessing an entry's path.
    for (final record in records) {
      recordedBytes += record.fileBytes;
      if (clock.difference(record.createdUtc) > controller.journal.maxAge) {
        expired++;
      }
      final file = File(record.sourcePath);
      final folder = file.parent;
      final pathParts = record.sourcePath.split(Platform.pathSeparator);
      final folderName = folder.uri.pathSegments
          .where((p) => p.isNotEmpty).last;
      if (pathParts.contains('..') ||
          folder.parent.absolute.path != rootPath ||
          !_randomFolder.hasMatch(folderName) ||
          file.uri.pathSegments.last != record.fileName) {
        unsafe++;
        continue;
      }
      referenced.add(folderName);
      try {
        if (await FileSystemEntity.type(folder.path,
                followLinks: false) != FileSystemEntityType.directory ||
            await FileSystemEntity.type(file.path,
                followLinks: false) != FileSystemEntityType.file) {
          missing++;
          continue;
        }
        if (await file.length() != record.fileBytes) mismatched++;
      } on FileSystemException {
        missing++;
      }
    }

    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    // Missing root is normal on fresh installations with no persistent sends.
    if (rootType == FileSystemEntityType.notFound) {
      return OutboundStorageHealthReport(
        recordedTasks: records.length, expiredTasks: expired,
        recordedBytes: recordedBytes, measuredStagingBytes: 0,
        orphanFolders: 0, orphanBytes: 0,
        missingSources: missing, sizeMismatchSources: mismatched,
        unsafeReferences: unsafe, unknownEntries: 0,
        scanComplete: true, stagingQuotaBytes: controller.maxStagedBytes,
      );
    }
    // Never follow a symbolic-link staging root, including read-only scans.
    if (rootType != FileSystemEntityType.directory) {
      return OutboundStorageHealthReport(
        recordedTasks: records.length, expiredTasks: expired,
        recordedBytes: recordedBytes, measuredStagingBytes: 0,
        orphanFolders: 0, orphanBytes: 0,
        missingSources: missing, sizeMismatchSources: mismatched,
        unsafeReferences: unsafe + 1, unknownEntries: 0,
        scanComplete: false, stagingQuotaBytes: controller.maxStagedBytes,
      );
    }

    var orphanFolders = 0;
    var orphanBytes = 0;
    var measuredBytes = 0;
    var unknown = 0;
    var complete = true;
    var folderCount = 0;
    // Nonrecursive; never inspect data outside the managed staging root.
    await for (final child in root.list(followLinks: false)) {
      if (++folderCount > maxFolders) {
        complete = false;
        break;
      }
      final name = child.uri.pathSegments.where((p) => p.isNotEmpty).last;
      final type = await FileSystemEntity.type(child.path, followLinks: false);
      if (type != FileSystemEntityType.directory ||
          !_randomFolder.hasMatch(name)) {
        unknown++;
        continue;
      }
      final isOrphan = !referenced.contains(name);
      if (isOrphan) orphanFolders++;
      var entryCount = 0;
      try {
        await for (final entry in Directory(child.path).list(followLinks: false)) {
          if (++entryCount > maxEntriesPerFolder) {
            complete = false;
            break;
          }
          final kind = await FileSystemEntity.type(entry.path,
              followLinks: false);
          if (kind == FileSystemEntityType.file) {
            try {
              final bytes = await File(entry.path).length();
              measuredBytes += bytes;
              if (isOrphan) orphanBytes += bytes;
            } on FileSystemException {
              complete = false;
            }
          } else {
            // Subdirectories / links / unknown entries are not traversed.
            unknown++;
          }
        }
      } on FileSystemException {
        complete = false;
      }
    }
    return OutboundStorageHealthReport(
      recordedTasks: records.length,
      expiredTasks: expired,
      recordedBytes: recordedBytes,
      measuredStagingBytes: measuredBytes,
      orphanFolders: orphanFolders,
      orphanBytes: orphanBytes,
      missingSources: missing,
      sizeMismatchSources: mismatched,
      unsafeReferences: unsafe,
      unknownEntries: unknown,
      scanComplete: complete,
      stagingQuotaBytes: controller.maxStagedBytes,
    );
  }
}
