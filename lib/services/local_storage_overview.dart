import 'dart:io';

/// DEV13D2E8: storage accounting for app-owned *local* directories only.
/// Public Android MediaStore copies (Pictures/Movies) are deliberately excluded:
/// their ownership and deletion rules are different from private cache files.
final class LocalStorageBucket {
  const LocalStorageBucket({
    required this.label,
    required this.fileCount,
    required this.bytes,
    required this.complete,
    required this.skippedEntries,
  });

  final String label;
  final int fileCount;
  final int bytes;
  final bool complete;
  final int skippedEntries;
}

final class LocalStorageSnapshot {
  const LocalStorageSnapshot(this.buckets);
  final List<LocalStorageBucket> buckets;

  int get measuredBytes =>
      buckets.fold<int>(0, (sum, item) => sum + item.bytes);
  bool get complete => buckets.every((item) => item.complete);
}

final class ThumbnailCleanupResult {
  const ThumbnailCleanupResult({required this.filesDeleted, required this.bytesFreed});
  final int filesDeleted;
  final int bytesFreed;
}

/// Never traverses subdirectories and never follows symbolic links.
/// An incomplete result is deliberately NOT advertised as the total size.
final class LocalStorageOverview {
  LocalStorageOverview._();

  static const String thumbnailDirectoryName = 'linyue_sent_thumbnails_v1';
  static const String pickedMediaDirectoryName = 'LinYuePickedImages';
  static const String shareCacheDirectoryName = 'NearLinkOutboundShareCache';
  static const int maxEntriesPerDirectory = 2500;
  static final RegExp _generatedThumbnail =
      RegExp(r'^sent_thumb_[0-9]+_[0-9]+\.png$');

  static String _pathKey(String path) {
    final value = File(path).absolute.path;
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  static Future<LocalStorageSnapshot> inspect({
    required Directory receivedDirectory,
    required Directory supportDirectory,
    int maxEntries = maxEntriesPerDirectory,
  }) async {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
    final separator = Platform.pathSeparator;
    final buckets = <LocalStorageBucket>[];
    for (final (label, dir) in <(String, Directory)>[
      ('邻跃接收原件', receivedDirectory),
      ('图库/相机待发送副本', Directory('${supportDirectory.path}${separator}$pickedMediaDirectoryName')),
      ('快捷分享临时副本', Directory('${supportDirectory.path}${separator}$shareCacheDirectoryName')),
      ('发送记录缩略图', Directory('${supportDirectory.path}${separator}$thumbnailDirectoryName')),
    ]) {
      buckets.add(await _inspectOne(label, dir, maxEntries));
    }
    return LocalStorageSnapshot(List.unmodifiable(buckets));
  }

  static Future<LocalStorageBucket> _inspectOne(
      String label, Directory directory, int maxEntries) async {
    final kind = await FileSystemEntity.type(directory.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      return LocalStorageBucket(label: label, fileCount: 0,
          bytes: 0, complete: true, skippedEntries: 0);
    }
    if (kind != FileSystemEntityType.directory) {
      return LocalStorageBucket(label: label, fileCount: 0,
          bytes: 0, complete: false, skippedEntries: 1);
    }
    var total = 0;
    var count = 0;
    var visited = 0;
    var skipped = 0;
    var complete = true;
    try {
      await for (final entry in directory.list(followLinks: false)) {
        if (visited >= maxEntries) { complete = false; break; }
        visited++;
        try {
          if (await FileSystemEntity.type(entry.path, followLinks: false) !=
              FileSystemEntityType.file) {
            skipped++;
            continue;
          }
          final stat = await entry.stat();
          if (stat.type != FileSystemEntityType.file || stat.size < 0) {
            skipped++;
            continue;
          }
          count++;
          total += stat.size;
        } catch (_) { skipped++; complete = false; }
      }
    } catch (_) { complete = false; }
    if (skipped > 0) complete = false;
    return LocalStorageBucket(label: label, fileCount: count,
        bytes: total, complete: complete, skippedEntries: skipped);
  }

  /// Deletes ONLY orphaned, older-than-24-hour *generated thumbnails*.
  /// Does not touch received originals, selected media, share copies, active
  /// resume staging, or public Pictures/Movies files. Entire directory is
  /// validated before any deletion to avoid partial scans masquerading as safe.
  static Future<ThumbnailCleanupResult> pruneOrphanThumbnails({
    required Directory thumbnailDirectory,
    required Set<String> retainedPaths,
    Duration minimumAge = const Duration(hours: 24),
    DateTime? now,
    int maxEntries = maxEntriesPerDirectory,
  }) async {
    if (minimumAge < const Duration(hours: 24)) {
      throw ArgumentError('安全清理不得小于 24 小时保留期');
    }
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
    final kind = await FileSystemEntity.type(
        thumbnailDirectory.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      return const ThumbnailCleanupResult(filesDeleted: 0, bytesFreed: 0);
    }
    if (kind != FileSystemEntityType.directory) {
      throw StateError('缩略图缓存目录异常，清理已取消');
    }
    final root = await thumbnailDirectory.resolveSymbolicLinks();
    final references = retainedPaths.map(_pathKey).toSet();
    final cutoff = (now ?? DateTime.now()).subtract(minimumAge);
    final candidates = <File>[];
    var entries = 0;
    await for (final item in thumbnailDirectory.list(followLinks: false)) {
      if (++entries > maxEntries) throw StateError('缩略图数量过多，已取消本次清理');
      if (await FileSystemEntity.type(item.path, followLinks: false) !=
          FileSystemEntityType.file) continue;
      final file = File(item.path);
      final name = file.uri.pathSegments.last;
      if (!_generatedThumbnail.hasMatch(name) ||
          references.contains(_pathKey(file.path))) continue;
      final parent = await file.parent.resolveSymbolicLinks();
      if (parent != root) continue;
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.file &&
          !stat.modified.isAfter(cutoff)) candidates.add(file);
    }
    var filesDeleted = 0;
    var bytesFreed = 0;
    for (final file in candidates) {
      // Re-check the file at deletion time. This also refuses symlink swaps.
      if (references.contains(_pathKey(file.path)) ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) continue;
      try {
        final stat = await file.stat();
        if (stat.modified.isAfter(cutoff)) continue;
        await file.delete();
        filesDeleted++;
        bytesFreed += stat.size;
      } catch (_) {
        // One failed deletion must not delete or rewrite any other file.
      }
    }
    return ThumbnailCleanupResult(
        filesDeleted: filesDeleted, bytesFreed: bytesFreed);
  }
}
