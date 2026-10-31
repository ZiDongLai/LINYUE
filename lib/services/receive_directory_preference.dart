import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Only stores a user-selected Windows folder path, not access credentials.
/// Android continues using its app-private inbox and existing SAF "save as".
class ReceiveDirectoryPreference {
  Future<File> _settingsFile() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}linyue_receive_directory.json');
  }

  Future<Directory> load(Directory fallback) async {
    if (!Platform.isWindows) return fallback;
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return fallback;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['version'] != 1 || json['path'] is! String) {
        return fallback;
      }
      final path = (json['path'] as String).trim();
      if (path.isEmpty) return fallback;
      final dir = Directory(path);
      return await dir.exists() ? dir : fallback;
    } catch (_) {
      return fallback;
    }
  }

  Future<void> save(Directory dir) async {
    if (!Platform.isWindows) throw UnsupportedError('仅 Windows 端支持接收目录切换');
    if (!await dir.exists()) throw FileSystemException('接收文件夹不存在', dir.path);
    final test = File('${dir.path}${Platform.pathSeparator}.linyue_write_test_${DateTime.now().microsecondsSinceEpoch}');
    try {
      await test.writeAsBytes([76, 89], flush: true);
    } finally {
      try { if (await test.exists()) await test.delete(); } catch (_) {}
    }
    final file = await _settingsFile();
    await file.writeAsString(jsonEncode({'version': 1, 'path': dir.absolute.path}), flush: true);
  }
}
