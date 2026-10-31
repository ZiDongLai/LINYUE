/// Display-only abbreviation for the compact recent-received list.
/// Never use the abbreviated string for file I/O, hashes, or actions.
String compactRecentFileName(String filename, {int head = 10, int tail = 8}) {
  if (head < 1 || tail < 1) throw ArgumentError('head/tail must be positive');
  final symbols = filename.runes.toList(growable: false);
  if (symbols.length <= head + tail + 1) return filename;
  final start = String.fromCharCodes(symbols.take(head));
  final end = String.fromCharCodes(symbols.skip(symbols.length - tail));
  return '$start…$end';
}
