import 'transfer_history.dart';
import 'live_text_trial_ledger.dart';

/// E17-C: UI-only merge of local file history and authenticated in-memory text.
/// File history retains existing local/unverified receive labels; this helper
/// does not claim that legacy file records are cryptographically identified.
final class ConversationTimelineEntry {
  const ConversationTimelineEntry.file(this.file) : text = null;
  const ConversationTimelineEntry.text(this.text) : file = null;

  final TransferRecord? file;
  final TrialTextItem? text;

  DateTime get timestamp => file?.timestamp ?? text!.message.createdAt;
}

final class ConversationTimelineMerge {
  ConversationTimelineMerge._();

  static List<ConversationTimelineEntry> merge({
    required List<TransferRecord> files,
    required List<TrialTextItem> texts,
    required String? authenticatedFingerprint,
    int maxEntries = 120,
  }) {
    if (maxEntries < 1 || maxEntries > 500) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
    final combined = <ConversationTimelineEntry>[
      for (final file in files) ConversationTimelineEntry.file(file),
      if (authenticatedFingerprint != null && authenticatedFingerprint.trim().isNotEmpty)
        for (final text in texts)
          if (text.authenticatedFingerprint == authenticatedFingerprint)
            ConversationTimelineEntry.text(text),
    ];
    // Reverse-scrolling ListView expects newest at index zero.
    combined.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return List.unmodifiable(combined.take(maxEntries));
  }
}
