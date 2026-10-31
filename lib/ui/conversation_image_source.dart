import 'dart:io';

import '../services/transfer_history.dart';
import 'file_visual_badge.dart';
import 'received_image_preview.dart';

/// Resolves the best locally available image for a conversation-history tap.
///
/// Sent records prefer their original source file. A generated thumbnail is
/// only a fallback when the original has been moved, deleted, or is outside
/// the viewer's safe size limit. Received records continue to use their local
/// received file. This is presentation-only and never changes transfer bytes.
final class ConversationImageSource {
  ConversationImageSource._();

  static Future<ConversationImagePreview?> resolve(
    TransferRecord entry,
  ) async {
    if (entry.status != 'success' || !supportsInlineThumbnail(entry.name)) {
      return null;
    }

    if (entry.direction == 'send') {
      final originalPath = entry.sourcePath;
      if (originalPath != null &&
          await mayPreviewLocalImage(entry.name, originalPath)) {
        return ConversationImagePreview(
          file: File(originalPath),
          isSentThumbnail: false,
        );
      }

      final thumbnailPath = entry.thumbnailPath;
      if (thumbnailPath != null &&
          await mayPreviewLocalImage(entry.name, thumbnailPath)) {
        return ConversationImagePreview(
          file: File(thumbnailPath),
          isSentThumbnail: true,
        );
      }
      return null;
    }

    final receivedPath = entry.localPath;
    if (receivedPath != null &&
        await mayPreviewLocalImage(entry.name, receivedPath)) {
      return ConversationImagePreview(
        file: File(receivedPath),
        isSentThumbnail: false,
      );
    }
    return null;
  }
}

final class ConversationImagePreview {
  const ConversationImagePreview({
    required this.file,
    required this.isSentThumbnail,
  });

  final File file;
  final bool isSentThumbnail;
}
