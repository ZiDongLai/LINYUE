import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// E20-C3B: display-only, read-only native video-frame preview.
/// No video bytes are copied, rewritten, compressed or passed to the peer.
/// Native bridges return a small JPEG (Android) or PNG (Windows), or null.
final class NativeVideoFrameThumbnail {
  NativeVideoFrameThumbnail._();

  static const channelName = 'linyue/video_thumbnail';
  static const methodName = 'extractPreview';
  static const _channel = MethodChannel(channelName);
  static const maxPreviewBytes = 2 * 1024 * 1024;
  static const maxVideoBytes = 1024 * 1024 * 1024;
  static const cacheLimit = 72;
  static final LinkedHashMap<String, Future<Uint8List?>> _cache = LinkedHashMap();

  static const videoExtensions = <String>{
    '.mp4', '.m4v', '.mov', '.3gp', '.3g2', '.webm',
    '.mkv', '.avi', '.wmv', '.mpg', '.mpeg',
  };

  static bool isVideoPath(String? path) {
    if (path == null || path.isEmpty || path.contains('\u0000')) return false;
    final lower = path.toLowerCase();
    return videoExtensions.any(lower.endsWith);
  }

  static bool eligibleFile({
    required String path,
    required FileStat stat,
  }) => isVideoPath(path) && stat.type == FileSystemEntityType.file &&
      stat.size > 0 && stat.size <= maxVideoBytes;

  static bool isValidPreview(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty || bytes.length > maxPreviewBytes) {
      return false;
    }
    // JPEG SOI or PNG signature; do not mistake a placeholder for a frame.
    final jpeg = bytes.length > 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;
    final png = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 &&
        bytes[2] == 0x4e && bytes[3] == 0x47;
    return jpeg || png;
  }

  static Future<Uint8List?> get(String? path) async {
    if (!(Platform.isAndroid || Platform.isWindows) || !isVideoPath(path)) return null;
    final file = File(path!);
    late final FileStat stat;
    try {
      stat = await file.stat();
      if (!eligibleFile(path: file.path, stat: stat)) return null;
    } on FileSystemException {
      return null;
    }

    // Retained by stat identity rather than filename alone, so a replaced file
    // never reuses the preceding original's thumbnail.
    final key = '${file.absolute.path}|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    final existing = _cache.remove(key);
    if (existing != null) {
      _cache[key] = existing; // bounded LRU
      return existing;
    }
    final future = _requestNative(file.absolute.path);
    _cache[key] = future;
    while (_cache.length > cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    return future;
  }

  static Future<Uint8List?> _requestNative(String path) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        methodName, <String, Object>{'path': path},
      ).timeout(const Duration(seconds: 9));
      return isValidPreview(bytes) ? bytes : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on Exception {
      return null;
    }
  }

  /// Testing-only reset; does not access or remove originals or disk cache.
  static void resetMemoryCacheForTest() => _cache.clear();
}
