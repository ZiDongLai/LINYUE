import 'dart:io';
import 'package:share_plus/share_plus.dart';

/// Android-only system-share adapter for an explicitly selected local file.
/// Sharing is supported for arbitrary ordinary files; opening/executing a file
/// is a separate action governed by AndroidReceivedOpen's stricter policy.
final class AndroidReceivedShare {
  AndroidReceivedShare._();

  static bool isSupportedName(String fileName) {
    // The OS decides which target apps can consume the shared MIME type.
    // Do not maintain an extension allow-list: users may share project files,
    // archives, fonts, data files, or future formats unknown to LINYUE.
    final name = fileName.trim();
    return name.isNotEmpty && name != '.' && name != '..' &&
        !name.contains('/') && !name.contains('\\') &&
        !name.contains('\u0000');
  }

  /// Returns the canonical filename only after the selected file is verified
  /// to be a direct regular child of the active receive directory.
  /// Resolving symlinks prevents a poisoned history path from escaping the root.
  static Future<String> validateFile({
    required File file,
    required Directory receiveDirectory,
  }) async {
    if (!isSupportedName(file.uri.pathSegments.last)) {
      throw StateError('文件名无效，无法分享');
    }
    if (!await receiveDirectory.exists() || !await file.exists()) {
      throw FileSystemException('接收文件或接收目录不存在', file.path);
    }
    final root = await receiveDirectory.resolveSymbolicLinks();
    final canonical = await file.resolveSymbolicLinks();
    if (File(canonical).parent.path != root) {
      throw StateError('仅允许分享当前接收目录中的文件');
    }
    final stat = await File(canonical).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw StateError('不支持分享非普通文件');
    }
    return canonical;
  }

  /// Validates a user-selected local source (for example, a file in the
  /// outgoing chat bubble). Unlike received-file sharing, the source need not
  /// live under LINYUE's receive directory, but it must resolve to a regular
  /// file. Call only in response to an explicit user share action.
  static Future<String> validateLocalFile({required File file}) async {
    if (!await file.exists()) {
      throw FileSystemException('所选文件不存在', file.path);
    }
    final canonical = await file.resolveSymbolicLinks();
    final stat = await File(canonical).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw StateError('仅支持分享普通文件');
    }
    if (!isSupportedName(File(canonical).uri.pathSegments.last)) {
      throw StateError('文件名无效，无法分享');
    }
    return canonical;
  }

  static Future<ShareResult> shareFile({
    required File file,
    required Directory receiveDirectory,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅支持 Android 系统分享');
    }
    final path = await validateFile(
      file: file, receiveDirectory: receiveDirectory,
    );
    // Only a single explicitly selected file is passed to the system share
    // sheet. No file bytes are loaded into Dart memory, including 1 GiB files.
    return SharePlus.instance.share(ShareParams(
      files: [XFile(path)],
      title: '分享文件',
    ));
  }

  /// Shares a user-selected local file that is not in LINYUE's receive folder.
  /// This is used for outgoing conversation cards and the pending-send queue.
  static Future<ShareResult> shareLocalFile(File file) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅支持 Android 系统分享');
    }
    final path = await validateLocalFile(file: file);
    return SharePlus.instance.share(ShareParams(
      files: [XFile(path)],
      title: '分享文件',
    ));
  }
}
