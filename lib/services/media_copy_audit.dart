import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// DEV13D2E9: READ-ONLY preflight for gallery/camera staging copies.
/// This file deliberately contains NO file.delete, rename or move API.
/// Old + unreferenced only means "review candidate", NOT safe to delete.
/// One *read-only* review item, not an authorization to delete it.
final class MediaCopyReviewItem {
  const MediaCopyReviewItem({
    required this.name,
    required this.bytes,
    required this.modified,
    this.provenanceVerified = false,
  });

  /// A display-only basename. No filesystem operation is exposed.
  final String name;
  final int bytes;
  final DateTime modified;
  /// Created by this app and independently registered in E11 or later.
  /// Does not prove the copy has no historic readers or is safe to delete.
  final bool provenanceVerified;
}

final class MediaCopyAuditResult {
  const MediaCopyAuditResult({
    required this.complete,
    required this.totalFiles,
    required this.totalBytes,
    required this.referencedFiles,
    required this.referencedBytes,
    required this.reviewFiles,
    required this.reviewBytes,
    required this.otherFiles,
    required this.recentFiles,
    this.reviewDetails = const [],
    this.reviewDetailsTruncated = false,
    this.registeredReviewFiles = 0,
    this.registeredReviewBytes = 0,
    this.registeredFiles = 0,
    this.registeredBytes = 0,
  });

  final bool complete;
  final int totalFiles;
  final int totalBytes;
  final int referencedFiles;
  final int referencedBytes;
  final int reviewFiles;
  final int reviewBytes;
  final int otherFiles;
  final int recentFiles;
  /// Only when complete can these be presented as a full review sample.
  final List<MediaCopyReviewItem> reviewDetails;
  final bool reviewDetailsTruncated;
  final int registeredReviewFiles;
  final int registeredReviewBytes;
  final int registeredFiles;
  final int registeredBytes;
}

final class MediaCopyAudit {
  MediaCopyAudit._();

  static const Duration minimumReviewAge = Duration(days: 7);
  static const int maximumEntries = 2500;
  // Only app-generated files from MobileMediaSourcePolicy.stageFile() qualify
  // for a read-only review. Unknown files are always excluded from candidates.
  static final RegExp _generatedName = RegExp(
    r'^\d{13,20}_\d{1,12}_.+\.(jpg|jpeg|png|gif|webp|heic|heif|bmp|mp4|m4v|mov|3gp|3g2|webm|mkv|avi|wmv|mpg|mpeg)$',
    caseSensitive: false,
  );

  static String _key(String path) {
    final absolute = File(path).absolute.path;
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  static Future<MediaCopyAuditResult> inspect({
    required Directory pickedMediaDirectory,
    required Set<String> referencedPaths,
    Directory? receiptDirectory,
    DateTime? now,
    Duration minimumAge = minimumReviewAge,
    int maxEntries = maximumEntries,
    int maxDetails = 12,
  }) async {
    if (minimumAge < minimumReviewAge) {
      throw ArgumentError('媒体副本只读预检的参考保留期不得低于 7 天');
    }
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
    if (maxDetails < 1 || maxDetails > 100) {
      throw ArgumentError.value(maxDetails, 'maxDetails');
    }
    final kind = await FileSystemEntity.type(
      pickedMediaDirectory.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      return const MediaCopyAuditResult(
        complete: true, totalFiles: 0, totalBytes: 0,
        referencedFiles: 0, referencedBytes: 0, reviewFiles: 0,
        reviewBytes: 0, otherFiles: 0, recentFiles: 0);
    }
    if (kind != FileSystemEntityType.directory) {
      return const MediaCopyAuditResult(
        complete: false, totalFiles: 0, totalBytes: 0,
        referencedFiles: 0, referencedBytes: 0, reviewFiles: 0,
        reviewBytes: 0, otherFiles: 0, recentFiles: 0);
    }

    // Missing receipts are expected for legacy versions: keep them unregistered.
    // Refuse to present a supposedly complete provenance list if the receipt
    // directory itself is abnormal or resolves to a symlink.
    if (receiptDirectory != null) {
      final kind = await FileSystemEntity.type(
          receiptDirectory.path, followLinks: false);
      if (kind != FileSystemEntityType.notFound &&
          kind != FileSystemEntityType.directory) {
        return const MediaCopyAuditResult(
          complete: false, totalFiles: 0, totalBytes: 0,
          referencedFiles: 0, referencedBytes: 0,
          reviewFiles: 0, reviewBytes: 0, otherFiles: 0, recentFiles: 0);
      }
    }
    final cutoff = (now ?? DateTime.now()).subtract(minimumAge);
    final keep = referencedPaths.map(_key).toSet();
    var complete = true;
    var visited = 0;
    var totalFiles = 0;
    var totalBytes = 0;
    var referencedFiles = 0;
    var referencedBytes = 0;
    var reviewFiles = 0;
    var reviewBytes = 0;
    var otherFiles = 0;
    var recentFiles = 0;
    var registeredReviewFiles = 0;
    var registeredReviewBytes = 0;
    var registeredFiles = 0;
    var registeredBytes = 0;
    final reviews = <MediaCopyReviewItem>[];
    try {
      await for (final entry in pickedMediaDirectory.list(followLinks: false)) {
        if (visited >= maxEntries) { complete = false; break; }
        visited++;
        try {
          if (await FileSystemEntity.type(entry.path, followLinks: false) !=
              FileSystemEntityType.file) {
            complete = false; // symlink or nested/unknown entity: no confidence
            continue;
          }
          final stat = await entry.stat();
          if (stat.type != FileSystemEntityType.file || stat.size < 0) {
            complete = false;
            continue;
          }
          totalFiles++;
          totalBytes += stat.size;
          final registered = receiptDirectory != null &&
              await _hasValidReceipt(entry, stat.size, receiptDirectory);
          if (registered) {
            registeredFiles++;
            registeredBytes += stat.size;
          }
          if (keep.contains(_key(entry.path))) {
            referencedFiles++;
            referencedBytes += stat.size;
          } else if (!_generatedName.hasMatch(entry.uri.pathSegments.last)) {
            otherFiles++;
          } else if (stat.modified.isAfter(cutoff)) {
            recentFiles++;
          } else {
            reviewFiles++;
            reviewBytes += stat.size;
            // Bounded display memory; preserve the largest candidates to show
            // where space may be consumed. No path is returned for deletion.
            final leaf = entry.path.split(Platform.pathSeparator).last;
            final safeLeaf = leaf.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '_');
            if (registered) {
              registeredReviewFiles++;
              registeredReviewBytes += stat.size;
            }
            reviews.add(MediaCopyReviewItem(
              name: safeLeaf.length > 96 ? safeLeaf.substring(0, 96) : safeLeaf,
              bytes: stat.size, modified: stat.modified,
              provenanceVerified: registered,
            ));
            reviews.sort((a, b) => b.bytes.compareTo(a.bytes));
            if (reviews.length > maxDetails) reviews.removeLast();
          }
        } catch (_) { complete = false; }
      }
    } catch (_) { complete = false; }
    // If the scan was incomplete, candidate size could be misleading. The UI
    // explicitly labels this as a partial observation and never allows delete.
    return MediaCopyAuditResult(
      complete: complete, totalFiles: totalFiles, totalBytes: totalBytes,
      referencedFiles: referencedFiles, referencedBytes: referencedBytes,
      reviewFiles: reviewFiles, reviewBytes: reviewBytes,
      otherFiles: otherFiles, recentFiles: recentFiles,
      // An incomplete scan must never imply the displayed list is exhaustive.
      reviewDetails: complete ? List<MediaCopyReviewItem>.unmodifiable(reviews) : const [],
      reviewDetailsTruncated: complete && reviewFiles > reviews.length,
      registeredReviewFiles: complete ? registeredReviewFiles : 0,
      registeredReviewBytes: complete ? registeredReviewBytes : 0,
      registeredFiles: complete ? registeredFiles : 0,
      registeredBytes: complete ? registeredBytes : 0,
    );
  }

  /// Pure read-only provenance check. A valid receipt still cannot establish
  /// the absence of older rotated history references.
  static Future<bool> _hasValidReceipt(
      FileSystemEntity source, int size, Directory receiptRoot) async {
    try {
      final storedName = source.uri.pathSegments.last;
      final digest = sha256.convert(utf8.encode(storedName));
      final receipt = File('${receiptRoot.path}${Platform.pathSeparator}$digest.json');
      if (await FileSystemEntity.type(receipt.path, followLinks: false) !=
          FileSystemEntityType.file) return false;
      final stat = await receipt.stat();
      if (stat.size <= 0 || stat.size > 4096) return false;
      final decoded = jsonDecode(await receipt.readAsString());
      if (decoded is! Map<String, dynamic>) return false;
      final timestamp = decoded['createdAtUtc'];
      return decoded['schema'] == 1 &&
          decoded['producer'] == 'linyue-mobile-stage' &&
          decoded['storedName'] == storedName &&
          decoded['bytes'] == size &&
          timestamp is String && DateTime.tryParse(timestamp) != null;
    } catch (_) {
      return false; // Missing/corrupt receipt stays unregistered.
    }
  }
}
