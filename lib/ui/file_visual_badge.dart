import 'dart:io';
import 'package:flutter/material.dart';

/// DEV13C1 - UI-only file classification. Filename extensions are presentation
/// hints, not proof of content type and never authorization to execute files.
enum FileVisualKind {
  image, video, audio, pdf, document, spreadsheet, slides,
  archive, installer, text, other,
}

FileVisualKind fileKindFromName(String name) {
  final base = name.replaceAll('\\', '/').split('/').last.toLowerCase();
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return FileVisualKind.other;
  final ext = base.substring(dot + 1);
  if (const {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif', 'avif'}
      .contains(ext)) return FileVisualKind.image;
  if (const {'mp4', 'mov', 'm4v', 'mkv', 'avi', 'webm', 'wmv', '3gp'}
      .contains(ext)) return FileVisualKind.video;
  if (const {'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'wma', 'opus'}
      .contains(ext)) return FileVisualKind.audio;
  if (ext == 'pdf') return FileVisualKind.pdf;
  if (const {'doc', 'docx', 'odt', 'rtf', 'wps'}
      .contains(ext)) return FileVisualKind.document;
  if (const {'xls', 'xlsx', 'csv', 'ods'}
      .contains(ext)) return FileVisualKind.spreadsheet;
  if (const {'ppt', 'pptx', 'odp'}
      .contains(ext)) return FileVisualKind.slides;
  if (const {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'}
      .contains(ext)) return FileVisualKind.archive;
  if (const {'apk', 'exe', 'msi', 'dmg', 'deb', 'ipa'}
      .contains(ext)) return FileVisualKind.installer;
  if (const {'txt', 'md', 'json', 'xml', 'yaml', 'yml', 'log', 'html',
    'css', 'js', 'ts', 'dart', 'py', 'java', 'kt', 'swift', 'ini'}
      .contains(ext)) return FileVisualKind.text;
  return FileVisualKind.other;
}

IconData iconForFileVisualKind(FileVisualKind kind) {
  switch (kind) {
    case FileVisualKind.image: return Icons.image_outlined;
    case FileVisualKind.video: return Icons.movie_outlined;
    case FileVisualKind.audio: return Icons.audiotrack_outlined;
    case FileVisualKind.pdf: return Icons.picture_as_pdf_outlined;
    case FileVisualKind.document: return Icons.article_outlined;
    case FileVisualKind.spreadsheet: return Icons.table_chart_outlined;
    case FileVisualKind.slides: return Icons.slideshow_outlined;
    case FileVisualKind.archive: return Icons.folder_zip_outlined;
    case FileVisualKind.installer: return Icons.install_desktop_outlined;
    case FileVisualKind.text: return Icons.description_outlined;
    case FileVisualKind.other: return Icons.insert_drive_file_outlined;
  }
}

String labelForFileVisualKind(FileVisualKind kind) {
  switch (kind) {
    case FileVisualKind.image: return '图片';
    case FileVisualKind.video: return '视频';
    case FileVisualKind.audio: return '音频';
    case FileVisualKind.pdf: return 'PDF';
    case FileVisualKind.document: return '文档';
    case FileVisualKind.spreadsheet: return '表格';
    case FileVisualKind.slides: return '演示文稿';
    case FileVisualKind.archive: return '压缩包';
    case FileVisualKind.installer: return '安装包';
    case FileVisualKind.text: return '文本';
    case FileVisualKind.other: return '文件';
  }
}

/// Preview only common static image codecs. GIFs, HEIC/AVIF and unfamiliar
/// image extensions retain an image icon until platform preview support is
/// verified, avoiding unexpected animation or platform codec failures.
bool supportsInlineThumbnail(String fileName) {
  final name = fileName.toLowerCase();
  return name.endsWith('.jpg') || name.endsWith('.jpeg') ||
      name.endsWith('.png') || name.endsWith('.webp');
}

/// Avoid decoding huge/untrusted input in scrolling message lists. A missing
/// file, a symbolic link or an unsupported file falls back to a type icon.
/// This is *not* a file integrity check or a trust decision.
Future<bool> mayLoadImageThumbnail(String? localPath, {
  int maxSourceBytes = 25 * 1024 * 1024,
}) async {
  if (localPath == null || localPath.trim().isEmpty) return false;
  try {
    final type = await FileSystemEntity.type(localPath, followLinks: false);
    if (type != FileSystemEntityType.file) return false;
    final stat = await File(localPath).stat();
    return stat.size > 0 && stat.size <= maxSourceBytes;
  } on FileSystemException {
    return false;
  } catch (_) {
    return false;
  }
}

class FileVisualBadge extends StatefulWidget {
  const FileVisualBadge({
    super.key,
    required this.fileName,
    this.localPath,
    this.size = 42,
  });

  final String fileName;
  final String? localPath;
  final double size;

  @override
  State<FileVisualBadge> createState() => _FileVisualBadgeState();
}

class _FileVisualBadgeState extends State<FileVisualBadge> {
  Future<bool>? _thumbnailAllowed;

  @override
  void initState() {
    super.initState();
    _resetThumbnail();
  }

  @override
  void didUpdateWidget(covariant FileVisualBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fileName != widget.fileName ||
        oldWidget.localPath != widget.localPath) {
      _resetThumbnail();
    }
  }

  void _resetThumbnail() {
    _thumbnailAllowed = supportsInlineThumbnail(widget.fileName)
        ? mayLoadImageThumbnail(widget.localPath)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final kind = fileKindFromName(widget.fileName);
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        color: const Color(0x444D9699),
        border: Border.all(color: const Color(0x996EC7C5)),
      ),
      child: Center(child: Icon(
        iconForFileVisualKind(kind),
        size: widget.size * 0.51,
        color: const Color(0xFFC2F7F0),
      )),
    );
    return Tooltip(
      message: labelForFileVisualKind(kind),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _thumbnailAllowed == null
            ? placeholder
            : FutureBuilder<bool>(
                future: _thumbnailAllowed,
                builder: (context, snapshot) {
                  if (snapshot.data != true) return placeholder;
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.file(
                      File(widget.localPath!),
                      fit: BoxFit.cover,
                      width: widget.size,
                      height: widget.size,
                      cacheWidth: 256,
                      cacheHeight: 256,
                      filterQuality: FilterQuality.low,
                      errorBuilder: (_, error, stack) => placeholder,
                    ),
                  );
                },
              ),
      ),
    );
  }
}
