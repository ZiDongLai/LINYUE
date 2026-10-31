import 'dart:io';

import 'transfer_history.dart';

/// E20-A: a read-only preflight for a future Windows Shell CF_HDROP COPY drag.
///
/// This class does NOT start a drag, copy/move a file, or change a transfer
/// record. E20-B must repeat the check immediately before exposing the path to
/// the native Windows drag source, and must offer COPY only (never MOVE).
enum ReceivedDragOutBlock {
  notReceived,
  notCompleted,
  noLocalPath,
  noReceiveRoot,
  invalidReceiveRoot,
  fileMissing,
  notRegularFile,
  outsideReceiveRoot,
  unreadable,
  changedSize,
}

final class ReceivedDragOutInspection {
  const ReceivedDragOutInspection._({
    this.block,
    this.absolutePath,
    this.fileName,
    this.sizeBytes,
  });

  final ReceivedDragOutBlock? block;
  final String? absolutePath;
  final String? fileName;
  final int? sizeBytes;

  bool get canDrag => block == null && absolutePath != null;

  static ReceivedDragOutInspection denied(ReceivedDragOutBlock why) =>
      ReceivedDragOutInspection._(block: why);

  static ReceivedDragOutInspection ready({
    required String absolutePath,
    required String fileName,
    required int sizeBytes,
  }) => ReceivedDragOutInspection._(
        absolutePath: absolutePath,
        fileName: fileName,
        sizeBytes: sizeBytes,
      );
}

final class WindowsReceivedDragOutPolicy {
  const WindowsReceivedDragOutPolicy._();

  /// Deliberately platform-neutral, to allow isolated unit tests on macOS or
  /// Linux as well. The UI/native drag entry points MUST additionally check
  /// Platform.isWindows; this check does not authorize an OS operation.
  static Future<ReceivedDragOutInspection> inspect({
    required TransferRecord record,
    required Directory? receiveRoot,
  }) async {
    if (record.direction != 'receive') {
      return ReceivedDragOutInspection.denied(ReceivedDragOutBlock.notReceived);
    }
    if (record.status != 'success') {
      return ReceivedDragOutInspection.denied(ReceivedDragOutBlock.notCompleted);
    }
    final path = record.localPath;
    if (path == null || path.trim().isEmpty) {
      return ReceivedDragOutInspection.denied(ReceivedDragOutBlock.noLocalPath);
    }
    if (receiveRoot == null) {
      return ReceivedDragOutInspection.denied(ReceivedDragOutBlock.noReceiveRoot);
    }

    String canonicalRoot;
    try {
      if (await FileSystemEntity.type(receiveRoot.path) !=
          FileSystemEntityType.directory) {
        return ReceivedDragOutInspection.denied(
            ReceivedDragOutBlock.invalidReceiveRoot);
      }
      canonicalRoot = await receiveRoot.absolute.resolveSymbolicLinks();
    } on FileSystemException {
      return ReceivedDragOutInspection.denied(
          ReceivedDragOutBlock.invalidReceiveRoot);
    }

    // Do not follow a leaf symlink. A record must reference a real, existing
    // local received file; broken links and directories are not exported.
    FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(path, followLinks: false);
    } on FileSystemException {
      return ReceivedDragOutInspection.denied(ReceivedDragOutBlock.fileMissing);
    }
    if (type == FileSystemEntityType.notFound) {
      return ReceivedDragOutInspection.denied(ReceivedDragOutBlock.fileMissing);
    }
    if (type != FileSystemEntityType.file) {
      return ReceivedDragOutInspection.denied(ReceivedDragOutBlock.notRegularFile);
    }

    try {
      final source = File(path);
      final canonicalSource = await source.absolute.resolveSymbolicLinks();
      if (!_isChildOf(canonicalSource, canonicalRoot)) {
        return ReceivedDragOutInspection.denied(
            ReceivedDragOutBlock.outsideReceiveRoot);
      }
      final stat = await source.stat();
      if (stat.type != FileSystemEntityType.file) {
        return ReceivedDragOutInspection.denied(
            ReceivedDragOutBlock.notRegularFile);
      }
      // A size mismatch means the file referenced by the historical record
      // is no longer the same sized object. Size is NOT a cryptographic proof;
      // no drag is authorized without a new inspection at drag-start.
      if (stat.size != record.bytes) {
        return ReceivedDragOutInspection.denied(ReceivedDragOutBlock.changedSize);
      }
      final access = await source.open(mode: FileMode.read);
      await access.close();
      final name = File(canonicalSource).uri.pathSegments.last;
      if (name.isEmpty) {
        return ReceivedDragOutInspection.denied(
            ReceivedDragOutBlock.notRegularFile);
      }
      return ReceivedDragOutInspection.ready(
        absolutePath: canonicalSource,
        fileName: name,
        sizeBytes: stat.size,
      );
    } on FileSystemException {
      return ReceivedDragOutInspection.denied(ReceivedDragOutBlock.unreadable);
    }
  }

  static bool _isChildOf(String filePath, String directoryPath) {
    final separator = Platform.pathSeparator;
    final root = _trimTrailingSeparators(directoryPath);
    final source = _trimTrailingSeparators(filePath);
    // Windows file paths are case-insensitive on the default file systems.
    final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
    final normalizedSource = Platform.isWindows ? source.toLowerCase() : source;
    final prefix = normalizedRoot.endsWith(separator)
        ? normalizedRoot
        : '$normalizedRoot$separator';
    return normalizedSource.startsWith(prefix) &&
        normalizedSource != normalizedRoot;
  }

  static String _trimTrailingSeparators(String path) {
    // Preserve filesystem root (e.g. C:\\ or /) while normalizing prefixes.
    final root = Directory(path).absolute.path;
    var result = root;
    while (result.length > 1 &&
        result.endsWith(Platform.pathSeparator) &&
        !RegExp(r'^[A-Za-z]:\\$').hasMatch(result)) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
