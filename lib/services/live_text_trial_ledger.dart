import 'conversation_text_protocol.dart';

/// E17-B2 diagnostic chat store. Volatile, identity-scoped, bounded.
/// Message acknowledgement means handled in memory, not persisted to disk.
final class TrialTextItem {
  const TrialTextItem({
    required this.authenticatedFingerprint,
    required this.message,
    required this.outbound,
  });
  final String authenticatedFingerprint;
  final TextChatMessage message;
  final bool outbound;
}

final class LiveTextTrialLedger {
  LiveTextTrialLedger({this.maxEntries = 100}) {
    if (maxEntries < 1 || maxEntries > 1000) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
  }
  final int maxEntries;
  final List<TrialTextItem> _entries = [];

  /// Returns false for a duplicate per authenticated fingerprint.
  bool recordIncoming({
    required String authenticatedFingerprint,
    required TextChatMessage message,
  }) => _record(authenticatedFingerprint, message, false);

  bool recordOutgoingConfirmed({
    required String authenticatedFingerprint,
    required TextChatMessage message,
  }) => _record(authenticatedFingerprint, message, true);

  bool _record(String fingerprint, TextChatMessage message, bool outbound) {
    if (fingerprint.trim().isEmpty) throw const FormatException('Missing peer identity');
    message.validate();
    if (_entries.any((item) =>
        item.authenticatedFingerprint == fingerprint &&
        item.message.id == message.id)) return false;
    _entries.add(TrialTextItem(
      authenticatedFingerprint: fingerprint, message: message, outbound: outbound));
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    return true;
  }

  /// E18-C: evict only one authenticated peer's local presentation cache.
  /// Caller MUST reload a committed encrypted snapshot from persistent storage.
  int removePeer({required String authenticatedFingerprint}) {
    if (authenticatedFingerprint.trim().isEmpty) {
      throw const FormatException('Missing authenticated peer');
    }
    final before = _entries.length;
    _entries.removeWhere((e) => e.authenticatedFingerprint == authenticatedFingerprint);
    return before - _entries.length;
  }

  List<TrialTextItem> snapshot() => List<TrialTextItem>.unmodifiable(_entries);
}
