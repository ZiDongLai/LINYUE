// DEV12-B1: real encrypted loopback stress tests, opt-in only.
// Keep outside test/ so everyday flutter test never allocates huge files.
// NO production channel code is changed by this QA package.
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'package:nearlink/services/transfer_progress.dart';

const int mib = 1024 * 1024;
const int chunkBytes = 256 * 1024;

class MemoryIdentityVault implements IdentityVault {
  final Map<String, String> values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

class SoakMemorySampler {
  final int baseline = ProcessInfo.currentRss;
  int maxRss = ProcessInfo.currentRss;
  Timer? _timer;
  void start() {
    if (_timer != null) throw StateError('sampler already running');
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final now = ProcessInfo.currentRss;
      if (now > maxRss) maxRss = now;
    });
  }
  void stop() {
    final now = ProcessInfo.currentRss;
    if (now > maxRss) maxRss = now;
    _timer?.cancel();
    _timer = null;
  }
  String get report =>
      'RSS start=${(baseline / mib).toStringAsFixed(1)} MiB; '
      'peak=${(maxRss / mib).toStringAsFixed(1)} MiB; '
      'increase=${((maxRss - baseline) / mib).toStringAsFixed(1)} MiB';
}

Future<File> createDeterministicFile(Directory at, String name, int size) async {
  final file = File('${at.path}${Platform.pathSeparator}$name');
  final fd = await file.open(mode: FileMode.writeOnly);
  final fixed = List<int>.generate(chunkBytes, (i) => (i * 17 + 43) % 251,
    growable: false);
  try {
    var remaining = size;
    while (remaining > 0) {
      final n = remaining < fixed.length ? remaining : fixed.length;
      await fd.writeFrom(fixed, 0, n);
      remaining -= n;
    }
    await fd.flush();
  } finally {
    await fd.close();
  }
  return file;
}

Future<String> streamSha256(File file) async =>
    (await hashes.sha256.bind(file.openRead()).first).toString();

class SoakFixture {
  SoakFixture._(this.temp, this.sender, this.receiver, this.recipientIdentity);
  final Directory temp;
  final SecureFileChannel sender;
  final SecureFileChannel receiver;
  final DeviceIdentityManager recipientIdentity;
  int consentCount = 0;

  static Future<SoakFixture> create() async {
    final dir = await Directory.systemTemp.createTemp('linyue_dev12b1_');
    SecureFileChannel? sender;
    SecureFileChannel? receiver;
    try {
      final sourceIdentity = DeviceIdentityManager(MemoryIdentityVault());
      final recipientIdentity = DeviceIdentityManager(MemoryIdentityVault());
      await sourceIdentity.initialize();
      await recipientIdentity.initialize();
      await sourceIdentity.register(displayName: 'soak receiver',
        identityCard: recipientIdentity.local.card,
        independentlyCheckedFingerprint: recipientIdentity.local.fingerprint);
      await recipientIdentity.register(displayName: 'soak sender',
        identityCard: sourceIdentity.local.card,
        independentlyCheckedFingerprint: sourceIdentity.local.fingerprint);
      sender = SecureFileChannel(sourceIdentity,
        targetDirectory: Directory('${dir.path}${Platform.pathSeparator}unused'));
      receiver = SecureFileChannel(recipientIdentity,
        targetDirectory: Directory('${dir.path}${Platform.pathSeparator}received'));
      final fixture = SoakFixture._(dir, sender, receiver, recipientIdentity);
      receiver.askReceiver = (offer) async {
        expect(offer.fingerprint, sourceIdentity.local.fingerprint);
        fixture.consentCount++;
        return true;
      };
      await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      return fixture;
    } catch (_) {
      try { await sender?.stop(); } catch (_) {}
      try { await receiver?.stop(); } catch (_) {}
      await dir.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> sendAndVerify(int size, String filename,
      {required SoakMemorySampler memory, required List<Duration> timings}) async {
    final source = await createDeterministicFile(temp, filename, size);
    final expected = await streamSha256(source);
    final received = File('${temp.path}${Platform.pathSeparator}received'
      '${Platform.pathSeparator}$filename');
    final progress = <TransferProgressInfo>[];
    final watch = Stopwatch()..start();
    memory.start();
    try {
      await sender.sendStreamFile(ip: '127.0.0.1',
        port: receiver.boundPort!,
        remoteFingerprint: recipientIdentity.local.fingerprint,
        file: source,
        onProgress: (p) { progress.add(p); },
      );
    } finally {
      memory.stop();
      watch.stop();
    }
    timings.add(watch.elapsed);
    expect(await received.exists(), isTrue, reason: 'receiver must persist file');
    expect(await received.length(), size, reason: 'no truncated final file');
    expect(await streamSha256(received), expected,
      reason: 'source and saved file must be identical');
    expect(progress, isNotEmpty);
    expect(progress.last.phase, TransferProgressPhase.completed);
    expect(progress.last.transferredBytes, size);
    for (final p in progress) {
      expect(p.totalBytes, size);
      expect(p.transferredBytes, inInclusiveRange(0, size));
    }
    final throughput = size / mib / watch.elapsedMilliseconds * 1000;
    print('[DEV12-B1] $filename size=$size bytes '
      'time=${watch.elapsed.inMilliseconds}ms '
      'throughput=${throughput.toStringAsFixed(2)} MiB/s; ${memory.report}');
    // Remove both finalized QA files between runs so the test never requires
    // the total of all test files to remain simultaneously on disk.
    await received.delete();
    await source.delete();
    final finalDir = Directory('${temp.path}${Platform.pathSeparator}received');
    if (await finalDir.exists()) {
      final leftovers = await finalDir.list(followLinks: false).toList();
      final unsafe = leftovers.where((e) =>
        e.uri.pathSegments.last.startsWith('.linyue_part_')).toList();
      expect(unsafe, isEmpty, reason: 'no unfinished data files after successful transfer');
    }
  }

  Future<void> close() async {
    await sender.stop();
    await receiver.stop();
    await temp.delete(recursive: true);
  }
}
