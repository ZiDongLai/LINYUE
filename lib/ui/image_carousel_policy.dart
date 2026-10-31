import '../services/transfer_history.dart';
import 'file_visual_badge.dart';

/// E14 local history navigation policy. Build the album from successful image
/// records of exactly the selected peer. Preserve order (oldest -> newest),
/// and cap work around the tapped record instead of scanning unlimited history.
final class ImageCarouselPolicy {
  ImageCarouselPolicy._();

  static List<TransferRecord> forPeer(
    List<TransferRecord> newestFirst,
    TransferRecord selected, {
    int maxEntries = 80,
  }) {
    if (selected.status != 'success' ||
        !supportsInlineThumbnail(selected.name)) return <TransferRecord>[];
    final ordered = newestFirst.where((record) =>
      record.peerName == selected.peerName &&
      record.status == 'success' &&
      supportsInlineThumbnail(record.name)).toList().reversed.toList();
    var at = ordered.indexWhere((record) => identical(record, selected));
    if (at < 0) return <TransferRecord>[selected];
    if (maxEntries <= 1) return <TransferRecord>[selected];
    if (ordered.length <= maxEntries) return ordered;
    final before = maxEntries ~/ 2;
    var from = (at - before).clamp(0, ordered.length - maxEntries).toInt();
    return ordered.sublist(from, from + maxEntries);
  }
}
