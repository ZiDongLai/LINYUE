import 'dart:async';
import 'dart:math';

/// E22-D4B: bounded concurrency for already-saved, private-LAN /health checks.
/// The caller must validate/limit addresses and independently enforce each
/// network deadline. This scheduler never adds a peer or grants trust.
final class DiscoveryProbeBatch {
  DiscoveryProbeBatch._();

  static const int maxConcurrency = 3;

  static Future<void> run(
    Iterable<String> targets,
    Future<void> Function(String ip) probe, {
    int concurrency = maxConcurrency,
  }) async {
    final queue = List<String>.unmodifiable(targets);
    if (queue.isEmpty) return;
    final workers = concurrency.clamp(1, 128);
    var next = 0;

    Future<void> worker() async {
      while (next < queue.length) {
        final ip = queue[next++];
        try {
          await probe(ip);
        } catch (_) {
          // One inaccessible or stale device must not block other addresses.
        }
      }
    }

    await Future.wait(
      List.generate(min(workers, queue.length), (_) => worker()),
    );
  }
}
