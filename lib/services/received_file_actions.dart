import 'dart:io';

/// Local file actions that never access network transfer state.
/// Received files remain unchanged; the destination is always user-selected.
final class ReceivedFileActions {
  static const Set<String> _safeOpenExtensions = {
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp',
    'pdf', 'txt', 'csv', 'md', 'rtf',
    'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
    'mp3', 'wav', 'flac', 'm4a', 'ogg',
    'mp4', 'mov', 'mkv', 'avi', 'webm',
  };

  // Never route common installers, executables, scripts, or native libraries
  // through ACTION_VIEW. Sharing these files is still possible after an
  // explicit user action; this deny-list applies only to "open with app".
  static const Set<String> _blockedOpenExtensions = {
    'apk', 'apks', 'xapk', 'exe', 'msi', 'msp', 'com', 'scr', 'pif',
    'bat', 'cmd', 'ps1', 'psm1', 'psd1', 'psc1', 'sh', 'bash', 'zsh',
    'fish', 'jar', 'dex', 'odex', 'vdex', 'so', 'dll', 'dylib', 'sys',
    'cpl', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'reg', 'hta',
    'appx', 'msix', 'deb', 'rpm', 'pkg', 'dmg', 'lnk', 'url',
    'docm', 'dotm', 'xlsm', 'xltm', 'xlam', 'pptm', 'ppsm', 'potm', 'ppam',
  };

  /// Does not inspect file bytes. Windows keeps its existing common-format
  /// allow-list. Android may ask the OS to handle unknown formats, while
  /// still refusing common executable/installer/script types.
  static bool mayOpenWithSystem(String fileName, {bool allowUnknown = false}) {
    final name = fileName.trim();
    if (name.isEmpty || name == '.' || name == '..' ||
        name.contains('/') || name.contains('\\') ||
        name.contains('\u0000')) return false;
    final dot = name.lastIndexOf('.');
    final extension = dot >= 0 && dot < name.length - 1
        ? name.substring(dot + 1).toLowerCase()
        : '';
    if (_blockedOpenExtensions.contains(extension)) return false;
    if (extension.isEmpty) return allowUnknown;
    return _safeOpenExtensions.contains(extension) || allowUnknown;
  }

  static String validateFileName(String fileName) {
    final name = fileName.trim();
    if (name.isEmpty || name == '.' || name == '..') {
      throw const FormatException('文件名不能为空');
    }
    if (name.length > 240 || name.endsWith('.') || name.endsWith(' ')) {
      throw const FormatException('文件名过长或结尾不合法');
    }
    if (RegExp(r'[<>:"/\\|?*\x00-\x1F]').hasMatch(name)) {
      throw const FormatException('文件名包含不允许的路径字符');
    }
    final base = name.split('.').first.toUpperCase();
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(base)) {
      throw const FormatException('不支持系统保留文件名');
    }
    return name;
  }

  /// Stream-copies a received file (up to 1 GiB and beyond) without reading
  /// it all into memory. Never overwrites an existing destination.
  /// If an I/O error occurs, attempts to delete the incomplete new copy.
  static Future<File> saveCopyToDirectory(File source, Directory destination,
      {String? fileName}) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('原文件不存在或不是普通文件', source.path);
    }
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('目标文件夹不存在或不可使用', destination.path);
    }
    final name = validateFileName(fileName ?? source.uri.pathSegments.last);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';

    File? result;
    for (var suffix = 0; suffix < 1000; suffix++) {
      final candidate = suffix == 0 ? name : '$stem ($suffix)$extension';
      final file = File('${destination.path}${Platform.pathSeparator}$candidate');
      try {
        await file.create(exclusive: true);
        result = file;
        break;
      } on FileSystemException {
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        rethrow;
      }
    }
    if (result == null) throw StateError('目标文件夹中同名文件过多');

    IOSink? sink;
    try {
      final originalSize = await source.length();
      sink = result.openWrite();
      await sink.addStream(source.openRead());
      await sink.flush();
      await sink.close();
      sink = null;
      if (await result.length() != originalSize) {
        throw FileSystemException('另存长度校验失败', result.path);
      }
      return result;
    } catch (_) {
      // Release Windows file handles before cleaning up an incomplete copy.
      if (sink != null) {
        try { await sink.close(); } catch (_) { /* preserve original failure */ }
      }
      try { await result.delete(); } catch (_) { /* preserve original failure */ }
      rethrow;
    }
  }
}
