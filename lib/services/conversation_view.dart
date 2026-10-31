import 'transfer_history.dart';

/// Presentation-only timeline for an unencrypted legacy transport.
/// Incoming records have no verified sender identity, so they are included
/// as UNATTRIBUTED records rather than asserted to be from [peerName].
List<TransferRecord> recentConversationEntries(
  List<TransferRecord> all, {
  required String? peerName,
  int maxEntries = 60,
}) {
  if (maxEntries < 1) return <TransferRecord>[];
  final entries = all.where((record) =>
      record.direction == 'receive' ||
      (peerName != null && record.direction == 'send' && record.peerName == peerName)
  ).toList();
  entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return entries.take(maxEntries).toList(growable: false);
}

/// Some old-history records reported zero bytes for non-empty file types.
/// Preserve recorded data without guessing a true size; surface uncertainty.
String conversationSizeLabel(TransferRecord entry) {
  if (entry.bytes != 0) return _formatBytes(entry.bytes);
  if (entry.name.contains('.')) return '记录 0 B（请核对）';
  return '0 B';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
