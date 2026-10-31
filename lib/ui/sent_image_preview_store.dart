import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

import 'file_visual_badge.dart';

/// A *local-only*, reduced-size snapshot of a successfully sent image.
/// Never caches the original file, never scans remote paths, and never
/// changes upload encryption / content hashes / receiver files.
class SentImagePreviewStore {
  static const maxInputBytes = 25 * 1024 * 1024;
  static const cacheFolder = 'linyue_sent_thumbnails_v1';

  static Future<Directory> _cacheRoot(Directory? override) async {
    final dir = override ?? Directory(
      '${(await getApplicationSupportDirectory()).path}'
      '${Platform.pathSeparator}$cacheFolder',
    );
    // Refuse a preexisting symlink root. A private, real directory only.
    final kind = await FileSystemEntity.type(dir.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      await dir.create(recursive: true);
    } else if (kind != FileSystemEntityType.directory) {
      throw StateError('Thumbnail cache root is not a regular directory');
    }
    if (await FileSystemEntity.type(dir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Unsafe thumbnail cache root');
    }
    return dir;
  }

  static Future<String?> createForFile({
    required File source,
    required String fileName,
    Directory? cacheDirectory,
  }) async {
    if (!supportsInlineThumbnail(fileName)) return null;
    try {
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) return null;
      final size = await source.length();
      if (size == 0 || size > maxInputBytes) return null;
      final sourceBytes = await source.readAsBytes();
      if (sourceBytes.length != size) return null;
      // Decode at thumbnail resolution. The original file is never modified.
      // Decode to a maximum 256 px long edge without forcing a square.
      // A first width-bounded decode identifies portrait images; those are
      // decoded again with a height bound so their aspect ratio is preserved.
      ui.Codec? codec;
      ui.Image? image;
      try {
        codec = await ui.instantiateImageCodec(sourceBytes, targetWidth: 256);
        image = (await codec!.getNextFrame()).image;
        if (image!.height > 256) {
          image!.dispose();
          image = null;
          codec!.dispose();
          codec = await ui.instantiateImageCodec(sourceBytes, targetHeight: 256);
          image = (await codec!.getNextFrame()).image;
        }
        final data = await image!.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        final previewBytes = data.buffer.asUint8List(
          data.offsetInBytes, data.lengthInBytes);
        // A malformed image cannot create an unbounded preview file.
        if (previewBytes.isEmpty || previewBytes.length > 1024 * 1024) {
          return null;
        }
        final dir = await _cacheRoot(cacheDirectory);
        final unique = '${DateTime.now().microsecondsSinceEpoch}_'
            '${math.Random.secure().nextInt(0x7fffffff)}';
        final output = File('${dir.path}${Platform.pathSeparator}sent_thumb_$unique.png');
        final partial = File('${output.path}.writing');
        try {
          await partial.writeAsBytes(previewBytes, flush: true);
          await partial.rename(output.path);
          return output.path;
        } catch (_) {
          try { if (await partial.exists()) await partial.delete(); } catch (_) {}
          return null;
        }
      } finally {
        image?.dispose();
        codec?.dispose();
      }
    } catch (_) {
      // Not previewable must never be promoted into a transfer failure.
      return null;
    }
  }

  /// Remove only our own generated, no-longer-referenced preview files.
  /// Unknown files, symlinks, directories, and original user photos stay put.
  static Future<void> prune(Set<String> retainedPaths, {
    Directory? cacheDirectory,
    Duration minAge = const Duration(hours: 24),
  }) async {
    try {
      final dir = cacheDirectory ?? Directory(
        '${(await getApplicationSupportDirectory()).path}'
        '${Platform.pathSeparator}$cacheFolder',
      );
      if (await FileSystemEntity.type(dir.path, followLinks: false) !=
          FileSystemEntityType.directory) return;
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! File || retainedPaths.contains(entry.path)) continue;
        final name = entry.uri.pathSegments.last;
        if (!RegExp(r'^sent_thumb_[0-9]+_[0-9]+\.png$').hasMatch(name)) {
          continue;
        }
        if (await FileSystemEntity.type(entry.path, followLinks: false) ==
            FileSystemEntityType.file) {
          try {
            // A preview may have just been generated before its history
            // entry is persisted. Never prune such a fresh file in a race.
            final stat = await entry.stat();
            if (DateTime.now().difference(stat.modified) < minAge) continue;
            await entry.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      // Best-effort cache cleanup, not a file transfer operation.
    }
  }
}
