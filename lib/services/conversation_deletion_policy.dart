/// E20-C2: local-only delete eligibility for a conversation file card.
/// Text deletion is separately authenticated by encrypted history storage.
final class ConversationDeletionPolicy {
  const ConversationDeletionPolicy._();

  /// A received local file may be physically removed ONLY after the caller
  /// uses LocalReceivedFileManager against the configured receive directory.
  /// This check is necessary but NOT sufficient to authorize deletion.
  static bool canDeleteReceivedCopy({
    required String direction,
    required String status,
    required String? localPath,
  }) => direction == 'receive' &&
      status == 'success' &&
      localPath != null &&
      localPath.trim().isNotEmpty;

  /// Local conversation history may be removed without touching file bytes,
  /// regardless of send/receive direction or success/failure state.
  static bool canRemoveLocalRecord({
    required String direction,
    required String status,
  }) => (direction == 'send' || direction == 'receive') &&
      (status == 'success' || status == 'failed');
}
