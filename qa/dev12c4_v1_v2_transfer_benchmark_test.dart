// DEV12-C4: real authenticated loopback V1/V2 throughput comparison.
// QA ONLY: this test does not replace or modify production code/checkpoints.
// The same generated source is used for both checkpoint formats per run.
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/resume_checkpoint.dart';
import 'package:nearlink/security/resume_format_router.dart';
import 'package:nearlink/security/secure_file_channel.dart';

const _mib = 1024 * 1024;
const _blockBytes = 256 * 1024;

class _LocalVault implements IdentityVault {
  final _data = <String, String>{};
  @override
  Future<String?> read(String key) async => _data[key];
  @override
  Future<void> write(String key, String value) async { _data[key] = value; }
  @override
  Future<void> delete(String key) async { _data.remove(key); }
}

Future<void> _trust(DeviceIdentityManager own, DeviceIdentityManager other) async {
  await own.register(
    displayName: 'bench authenticated peer',
    identityCard: other.local.card,
    independentlyCheckedFingerprint: other.local.fingerprint,
  );
}

Future<File> _makeFile(Directory folder, String name, int bytes) async {
  final file = File('${folder.path}${Platform.pathSeparator}$name');
  final block = List<int>.generate(_blockBytes, (i) => (i * 31 + 17) % 251);
  final writer = await file.open(mode: FileMode.writeOnly);
  try {
    var remaining = bytes;
    while (remaining > 0) {
      final amount = remaining < block.length ? remaining : block.length;
      await writer.writeFrom(block, 0, amount);
      remaining -= amount;
    }
    await writer.flush();
  } finally {
    await writer.close();
  }
  return file;
}

Future<String> _sha(File file) async =>
    (await hashes.sha256.bind(file.openRead()).first).toString();

class _Result {
  const _Result(this.elapsedMs, this.bytes, this.peakRssBytes, this.consentCount);
  final int elapsedMs;
  final int bytes;
  final int peakRssBytes;
  final int consentCount;
  double get mibPerSecond => (bytes / _mib) /
      (elapsedMs <= 0 ? 0.001 : elapsedMs / 1000.0);
}

Future<_Result> _transfer({
  required Directory runDirectory,
  required File source,
  required String digest,
  required bool legacy,
}) async {
  final senderId = DeviceIdentityManager(_LocalVault());
  final receiverId = DeviceIdentityManager(_LocalVault());
  await senderId.initialize();
  await receiverId.initialize();
  await _trust(senderId, receiverId);
  await _trust(receiverId, senderId);

  final receiverDirectory = Directory(
    '${runDirectory.path}${Platform.pathSeparator}received');
  final sender = SecureFileChannel(senderId, targetDirectory: Directory(
    '${runDirectory.path}${Platform.pathSeparator}sender'));
  final receiver = SecureFileChannel(receiverId, targetDirectory: receiverDirectory);
  final id = ResumeCheckpointStore.newId();
  final size = await source.length();
  var consentCount = 0;
  receiver.askReceiver = (_) async { consentCount++; return true; };

  if (legacy) {
    // Pre-existing V1 task with ZERO committed bytes, so both runs upload
    // the exact same amount of encrypted data while exercising real V1/V2.
    final oldStore = ResumeCheckpointStore(receiverDirectory);
    await oldStore.create(id: id,
      peerFingerprint: senderId.local.fingerprint,
      fileSha256: digest, totalBytes: size);
    await File('${receiverDirectory.path}${Platform.pathSeparator}'
      '.linyue_resume_$id.name').writeAsString(
      source.uri.pathSegments.last, flush: true);
    expect(await ResumeFormatRouter(receiverDirectory).choose(id),
      ResumeCheckpointFormat.legacyV1);
  } else {
    expect(await ResumeFormatRouter(receiverDirectory).choose(id),
      ResumeCheckpointFormat.linearV2);
  }

  var peakRss = ProcessInfo.currentRss;
  Timer? sampler;
  final stopwatch = Stopwatch();
  try {
    await receiver.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
    sampler = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final rss = ProcessInfo.currentRss;
      if (rss > peakRss) peakRss = rss;
    });
    stopwatch.start();
    await sender.sendStreamFile(
      ip: '127.0.0.1', port: receiver.boundPort!,
      remoteFingerprint: receiverId.local.fingerprint,
      file: source, resumeTaskId: id, expectedSha256: digest);
    stopwatch.stop();
    final received = File('${receiverDirectory.path}${Platform.pathSeparator}'
      '${source.uri.pathSegments.last}');
    expect(await received.exists(), true);
    expect(await received.length(), size);
    expect(await _sha(received), digest,
      reason: 'never count a file with wrong SHA-256 as a benchmark success');
    expect(consentCount, legacy ? 0 : 1,
      reason: 'V1 already granted consent; V2 is a new approved task');
    return _Result(stopwatch.elapsedMilliseconds, size, peakRss, consentCount);
  } finally {
    sampler?.cancel();
    await sender.stop();
    await receiver.stop();
  }
}

Future<void> _compare(int mib, List<bool> legacyOrder) async {
  final root = await Directory.systemTemp.createTemp('linyue_dev12c4_');
  try {
    final source = await _makeFile(root, 'bench_${mib}m.bin', mib * _mib + 17);
    final digest = await _sha(source);
    final results = <bool, _Result>{};
    for (var index = 0; index < legacyOrder.length; index++) {
      final legacy = legacyOrder[index];
      final label = legacy ? 'V1' : 'V2';
      final location = Directory('${root.path}${Platform.pathSeparator}'
        '${label}_$index');
      print('[DEV12-C4] START format=$label size_mib=$mib');
      final result = await _transfer(runDirectory: location, source: source,
        digest: digest, legacy: legacy);
      results[legacy] = result;
      print('[DEV12-C4] TRANSFER_OK format=$label size_mib=$mib '
        'elapsed_ms=${result.elapsedMs} '
        'throughput_mib_s=${result.mibPerSecond.toStringAsFixed(3)} '
        'sampled_peak_rss_mib=${(result.peakRssBytes / _mib).toStringAsFixed(1)} '
        'receiver_consents=${result.consentCount} sha256_verified=true');
    }
    final oldResult = results[true]!;
    final newResult = results[false]!;
    final ratio = oldResult.elapsedMs / (newResult.elapsedMs <= 0 ? 1 : newResult.elapsedMs);
    print('[DEV12-C4] COMPARE_OK size_mib=$mib '
      'v1_ms=${oldResult.elapsedMs} v2_ms=${newResult.elapsedMs} '
      'v2_time_ratio=${ratio.toStringAsFixed(2)} '
      'note=loopback_only_not_wifi_no_minimum_speed_requirement');
    // Intentionally DO NOT require V2 to be faster on every run. Caches,
    // antivirus and scheduling can vary. Integrity is the pass criterion.
  } finally {
    await root.delete(recursive: true);
  }
}

void main() {
  test('48 MiB plus 17 bytes: V1 then V2 authenticated apples-to-apples transfer',
    () async => _compare(48, [true, false]),
    timeout: const Timeout(Duration(minutes: 40)));
  test('96 MiB plus 17 bytes: V2 then V1 to counter run-order effects',
    () async => _compare(96, [false, true]),
    timeout: const Timeout(Duration(minutes: 60)));
}
