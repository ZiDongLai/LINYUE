import 'dart:io';

import 'package:open_filex/open_filex.dart';

import 'received_file_actions.dart';

/// Opens one explicitly selected, safe-format received file through Android's
/// ACTION_VIEW flow. Files outside the active receive directory are rejected.
final class AndroidReceivedOpen {
  AndroidReceivedOpen._();

  static bool isSupportedName(String fileName) =>
      ReceivedFileActions.mayOpenWithSystem(fileName, allowUnknown: true);

  static const _documentMimeTypes = <String, String>{
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'csv': 'text/csv',
    'txt': 'text/plain',
  };

  /// Override only common documents; preserve the plugin's existing media and
  /// unknown-format handling. A MIME value never grants permission to open.
  static String? documentMimeType(String fileName) {
    if (!isSupportedName(fileName)) return null;
    final name = fileName.trim();
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    return _documentMimeTypes[name.substring(dot + 1).toLowerCase()];
  }

  /// Returns the canonical path only if the file is a direct regular child of
  /// the active receive directory. This rejects missing files, directories,
  /// and paths/symlinks that escape the receive root.
  static Future<String> validateFile({
    required File file,
    required Directory receiveDirectory,
  }) async {
    if (!isSupportedName(file.uri.pathSegments.last)) {
      throw StateError('此文件类型暂不支持用其他应用打开');
    }
    if (!await receiveDirectory.exists() || !await file.exists()) {
      throw FileSystemException('接收文件或接收目录不存在', file.path);
    }
    final root = await receiveDirectory.resolveSymbolicLinks();
    final canonical = await file.resolveSymbolicLinks();
    if (File(canonical).parent.path != root) {
      throw StateError('仅允许打开当前接收目录中的文件');
    }
    if (!isSupportedName(File(canonical).uri.pathSegments.last)) {
      throw StateError('为安全起见，此类型不支持直接打开');
    }
    final stat = await File(canonical).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw StateError('不支持打开非普通文件');
    }
    return canonical;
  }

  /// Validates a file that was explicitly selected by the user from the
  /// outgoing side of the conversation. Unlike a received file, it does not
  /// need to live in the receive folder; executable/installer/script formats
  /// are still rejected by the shared open policy.
  static Future<String> validateLocalFile({required File file}) async {
    if (!isSupportedName(file.uri.pathSegments.last)) {
      throw StateError('为安全起见，此类型不支持直接打开');
    }
    if (!await file.exists()) {
      throw FileSystemException('所选文件不存在', file.path);
    }
    final canonical = await file.resolveSymbolicLinks();
    final stat = await File(canonical).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw StateError('仅支持打开普通文件');
    }
    return canonical;
  }

  static Future<OpenResult> openFile({
    required File file,
    required Directory receiveDirectory,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅 Android 支持此系统打开方式');
    }
    final canonical = await validateFile(
      file: file,
      receiveDirectory: receiveDirectory,
    );
    return OpenFilex.open(canonical,
      type: documentMimeType(File(canonical).uri.pathSegments.last),
    );
  }

  static Future<OpenResult> openLocalFile(File file) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅 Android 支持此系统打开方式');
    }
    final canonical = await validateLocalFile(file: file);
    return OpenFilex.open(canonical);
  }
}
