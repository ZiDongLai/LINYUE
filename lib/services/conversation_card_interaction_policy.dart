/// DEV13D2E20-C1: presentation-only decisions for the conversation cards.
/// This class does not grant filesystem access. WindowsReceivedDragOutPolicy
/// and the Windows native runner validate every drag again before offering
/// COPY-only CF_HDROP to the operating system.
final class ConversationCardInteractionPolicy {
  const ConversationCardInteractionPolicy._();

  static const Set<String> _imageAndVideoExtensions = {
    '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.heic', '.heif',
    '.avif', '.tif', '.tiff', '.mp4', '.m4v', '.mov', '.mkv', '.avi',
    '.webm', '.3gp', '.3g2', '.mpeg', '.mpg',
  };

  static bool isImageOrVideo(String fileName) {
    final value = fileName.trim().toLowerCase();
    if (value.isEmpty) return false;
    return _imageAndVideoExtensions.any(value.endsWith);
  }

  /// Controls only whether the UI recognizes a pan gesture on the full card.
  /// Full read-only path, size and directory checks remain in E20-A and OLE.
  static bool canDragEntireReceivedCard({
    required bool isWindows,
    required String direction,
    required String status,
    required String? localPath,
  }) => isWindows && direction == 'receive' && status == 'success' &&
      localPath != null && localPath.trim().isNotEmpty;
}
