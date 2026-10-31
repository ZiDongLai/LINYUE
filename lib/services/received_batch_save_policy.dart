import 'dart:io';

/// E15 Android received-file selection. No sent thumbnails, paths typed by a
/// peer, or arbitrary filesystem locations are eligible batch save sources.
///
/// Sources must originate in the in-memory successfully received-file list.
/// The save service still revalidates existence and type before export.
final class ReceivedBatchSavePolicy {
  ReceivedBatchSavePolicy._();

  static const int maxBatch = 30;

  static List<File> candidates(Iterable<File> received, {int limit = maxBatch}) {
    if (limit < 1) return <File>[];
    final selected = <File>[];
    final seen = <String>{};
    for (final file in received) {
      if (file.absolute.path != file.path) continue;
      if (!seen.add(file.path)) continue;
      selected.add(file);
      if (selected.length >= limit || selected.length >= maxBatch) break;
    }
    return selected;
  }

  static List<File> resolve(Iterable<File> received, Iterable<String> paths) {
    final chosen = paths.toSet();
    if (chosen.isEmpty) return <File>[];
    final available = candidates(received);
    return available.where((file) => chosen.contains(file.path)).toList();
  }
}
