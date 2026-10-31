/// Presentation-only rules for E20-C3A. No file I/O or network effects.
class ChatCardDisplayPolicy {
  const ChatCardDisplayPolicy._();

  /// Bottom metadata displays the local time only, never encrypted ACK status.
  static String clock(DateTime timestamp) {
    final local = timestamp.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  /// A directional device icon, not cryptographic proof of remote OS type.
  static bool showPhoneAvatar({
    required bool isAndroidClient,
    required bool outbound,
  }) => outbound ? isAndroidClient : !isAndroidClient;

  /// Never offer playback for failed transfers or absent originals.
  static bool offerVideoPlay({
    required bool successful,
    required bool videoExtension,
    required String? originalPath,
  }) => successful && videoExtension &&
      originalPath != null && originalPath.isNotEmpty;
}
