import 'dart:io';

import 'received_file_actions.dart';

/// Safe local management for files received into LINYUE's active receive root.
/// It never accesses network transfer state or a sender's original file.
final class LocalReceivedFileManager {
  LocalReceivedFileManager._();

  /// Renames a received file without overwriting another file.
  ///
  /// The destination is exclusively created and streamed, then length-checked
  /// before the old copy is removed. This avoids reading large files into RAM
  /// and avoids relying on platform-specific rename-overwrite behavior.
  static Future<File> renameReceivedFile({
    required File file,
    required Directory receiveDirectory,
    required String newName,
  }) async {
    final validatedName = ReceivedFileActions.validateFileName(newName);
    final source = await _validateReceivedFile(file, receiveDirectory);
    final oldName = source.uri.pathSegments.last;
    if (oldName == validatedName ||
        (Platform.isWindows && oldName.toLowerCase() == validatedName.toLowerCase())) {
      return source;
    }

    final root = Directory(await receiveDirectory.resolveSymbolicLinks());
    final target = File('${root.path}${Platform.pathSeparator}$validatedName');
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException('同名文件已存在，不会覆盖原文件', target.path);
    }

    try {
      // Exclusive creation closes the ordinary check-then-create overwrite gap.
      await target.create(exclusive: true);
    } on FileSystemException {
      throw FileSystemException('目标文件已存在或无法创建，不会覆盖原文件', target.path);
    }

    IOSink? sink;
    try {
      final originalLength = await source.length();
      sink = target.openWrite();
      await sink.addStream(source.openRead());
      await sink.flush();
      await sink.close();
      sink = null;
      if (await target.length() != originalLength) {
        throw FileSystemException('重命名副本长度校验失败', target.path);
      }
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // Preserve the original copy error.
        }
      }
      try {
        await target.delete();
      } catch (_) {
        // Preserve the original copy error; a leftover partial copy is surfaced
        // to the caller through the failed operation and can be inspected.
      }
      rethrow;
    }

    try {
      await source.delete();
    } catch (_) {
      // If the source still exists, preserve it and remove the new duplicate.
      // If another actor already removed the source, keep the verified copy.
      if (await source.exists()) {
        try {
          await target.delete();
        } catch (_) {
          // Do not hide the source-delete failure.
        }
        rethrow;
      }
    }
    return target;
  }

  /// Deletes only one ordinary file that is a direct child of the receive root.
  /// It deliberately does not touch transfer history or files outside that root.
  static Future<void> deleteReceivedFile({
    required File file,
    required Directory receiveDirectory,
  }) async {
    final validated = await _validateReceivedFile(file, receiveDirectory);
    await validated.delete();
  }

  static Future<File> _validateReceivedFile(
    File file,
    Directory receiveDirectory,
  ) async {
    if (await FileSystemEntity.type(
          receiveDirectory.path,
          followLinks: false,
        ) != FileSystemEntityType.directory) {
      throw FileSystemException('接收目录不存在或不是普通目录', receiveDirectory.path);
    }
    final rootPath = await receiveDirectory.resolveSymbolicLinks();
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('接收文件不存在或不是普通文件', file.path);
    }
    final canonicalFilePath = await file.resolveSymbolicLinks();
    final canonicalFile = File(canonicalFilePath);
    final canonicalParentPath = await canonicalFile.parent.resolveSymbolicLinks();
    if (!_samePath(canonicalParentPath, rootPath)) {
      throw FileSystemException('出于安全考虑，只能管理当前接收目录中的文件', file.path);
    }
    final stat = await canonicalFile.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('不支持管理非普通文件', file.path);
    }
    return canonicalFile;
  }

  static bool _samePath(String first, String second) {
    final a = _normalizePath(first);
    final b = _normalizePath(second);
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }

  static String _normalizePath(String path) {
    var result = File(path).absolute.path;
    while (result.length > 1 &&
        (result.endsWith('/') || result.endsWith(r'\'))) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
