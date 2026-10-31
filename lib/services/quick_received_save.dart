import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'received_file_actions.dart';

/// E13 local-only policy. Only successful *received* originals have a Save
/// action; sent history and presentation thumbnails are never export sources.
final class QuickReceivedSavePolicy {
  QuickReceivedSavePolicy._();

  static const _pictures = <String>{'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif'};
  static const _videos = <String>{'mp4', 'm4v', 'mov', '3gp', '3g2', 'webm', 'mkv', 'avi', 'wmv', 'mpg', 'mpeg'};

  static String category(String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    if (_pictures.contains(ext)) return 'picture';
    if (_videos.contains(ext)) return 'video';
    return 'document';
  }

  static bool availableForRecord({required String direction, required String status, String? localPath}) =>
      direction == 'receive' && status == 'success' && localPath != null && localPath.isNotEmpty;

  static bool isCompletedName(String name) => name.isNotEmpty &&
      !name.startsWith('.linyue_part_') && !name.contains('.part.') &&
      !name.contains('/') && !name.contains('\\') && !name.contains('\u0000') &&
      name != '.' && name != '..';

  /// Export only a finished regular file from the active inbox. This does not
  /// alter the transfer protocol's integrity or completion rules.
  static Future<File> validateSource(File source, Directory receiveDirectory) async {
    if (!isCompletedName(source.uri.pathSegments.last) ||
        await FileSystemEntity.type(source.path, followLinks: false) != FileSystemEntityType.file) {
      throw FileSystemException('接收文件不存在、不可访问或尚未完成', source.path);
    }
    final root = await receiveDirectory.resolveSymbolicLinks();
    final canonical = File(await source.resolveSymbolicLinks());
    final parent = await canonical.parent.resolveSymbolicLinks();
    final sameRoot = Platform.isWindows
        ? parent.toLowerCase() == root.toLowerCase() : parent == root;
    if (!sameRoot || !isCompletedName(canonical.uri.pathSegments.last)) {
      throw FileSystemException('只允许保存当前接收目录的已完成文件', source.path);
    }
    return canonical;
  }

  static Directory windowsFolder(Map<String, String> environment, String category, Directory downloads) {
    // Resolve Downloads through path_provider (including redirected folders),
    // rather than guessing Pictures/Videos from USERPROFILE.
    return downloads;
  }
}

/// Existing MediaStore bridge, used only after an explicit received-file save.
/// Its method/URI contract stays compatible with automatic media archiving.
final class AndroidQuickReceivedSave {
  AndroidQuickReceivedSave._();
  static const _channel = MethodChannel('nearlink/files');
  static final _active = <String, Future<AndroidQuickSaveResult>>{};

  static Future<AndroidQuickSaveResult> save(File file, Directory receiveDirectory) {
    final key = '${receiveDirectory.absolute.path}\u0000${file.absolute.path}';
    final pending = _active[key];
    if (pending != null) return pending;
    final operation = _save(file, receiveDirectory).whenComplete(() {
      _active.remove(key);
    });
    _active[key] = operation;
    return operation;
  }

  static Future<AndroidQuickSaveResult> _save(File file, Directory receiveDirectory) async {
    final source = await QuickReceivedSavePolicy.validateSource(file, receiveDirectory);
    final category = QuickReceivedSavePolicy.category(source.uri.pathSegments.last);
    final response = await _channel.invokeMethod<String>(
      category == 'document' ? 'quickSaveReceivedDocument' : 'archiveReceivedMedia',
      <String, Object>{'path': source.path},
    );
    final existing = response?.startsWith('existing:') ?? false;
    final saved = response?.startsWith('saved:') ?? false;
    final uri = Uri.tryParse(response == null ? '' : response.substring(response.indexOf(':') + 1));
    if ((!existing && !saved) || uri?.scheme != 'content' || uri!.authority.isEmpty) {
      throw StateError('系统没有返回有效保存结果');
    }
    return AndroidQuickSaveResult(source.uri.pathSegments.last, category, existing);
  }
}

final class AndroidQuickSaveResult {
  const AndroidQuickSaveResult(this.fileName, this.category, this.existing);
  final String fileName;
  final String category;
  final bool existing;
  String get message => existing ? '已保存：$fileName（无需重复下载）'
      : category == 'document' ? '已保存：$fileName → 下载/LinYue'
      : '已保存：$fileName → 系统相册 · 邻跃';
}

/// A bounded, best-effort local receipt for Windows one-click copies. It never
/// removes originals or user copies; if a saved destination was moved/changed,
/// a subsequent click creates a distinct new file through exclusive create.
final class QuickReceivedSaveIndex {
  QuickReceivedSaveIndex(this.indexFile);

  final File indexFile;
  static const maxIndexBytes = 512 * 1024;

  Future<Map<String, dynamic>> _read() async {
    if (!await indexFile.exists()) return <String, dynamic>{};
    if (await indexFile.length() > maxIndexBytes) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(await indexFile.readAsString());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<String?> lookup(File source) async {
    final map = await _read();
    final entry = map[source.absolute.path];
    if (entry is! Map<String, dynamic>) return null;
    try {
      final sourceStat = await source.stat();
      if (sourceStat.type != FileSystemEntityType.file ||
          entry['sourceBytes'] != sourceStat.size ||
          entry['sourceModified'] != sourceStat.modified.millisecondsSinceEpoch) return null;
      final path = entry['target'];
      if (path is! String || path.isEmpty || path == source.absolute.path) return null;
      final target = File(path);
      final targetStat = await target.stat();
      if (targetStat.type != FileSystemEntityType.file ||
          targetStat.size != entry['targetBytes'] ||
          targetStat.modified.millisecondsSinceEpoch != entry['targetModified']) return null;
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<void> remember(File source, File target) async {
    final from = await source.stat();
    final to = await target.stat();
    final map = await _read();
    if (map.length >= 1000) map.clear(); // never delete the user files
    map[source.absolute.path] = <String, dynamic>{
      'sourceBytes': from.size,
      'sourceModified': from.modified.millisecondsSinceEpoch,
      'target': target.absolute.path,
      'targetBytes': to.size,
      'targetModified': to.modified.millisecondsSinceEpoch,
    };
    await indexFile.parent.create(recursive: true);
    final temp = File('${indexFile.path}.tmp');
    await temp.writeAsString(jsonEncode(map), flush: true);
    // Atomic move on the same filesystem. A broken index cannot delete a user file.
    if (await indexFile.exists()) await indexFile.delete();
    await temp.rename(indexFile.path);
  }

  static Future<QuickReceivedSaveIndex> inAppSupport() async {
    final dir = await getApplicationSupportDirectory();
    return QuickReceivedSaveIndex(File('${dir.path}${Platform.pathSeparator}LinYueQuickSaved.json'));
  }

  static Future<File> saveWindows(File source, Directory directory, QuickReceivedSaveIndex index) async {
    final previous = await index.lookup(source);
    if (previous != null) return File(previous);
    if (!await directory.exists()) throw FileSystemException('默认保存文件夹不存在', directory.path);
    final copy = await ReceivedFileActions.saveCopyToDirectory(source, directory);
    try {
      await index.remember(source, copy);
    } catch (_) {
      // Index is auxiliary. Keep an already completed and valid user copy.
    }
    return copy;
  }
}
