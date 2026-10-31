// DEV12-C2 opt-in comparative benchmarks. Measurements are independent stage
// baselines, NOT exclusive production pipeline timings. Source safety unchanged.
// Run: flutter test qa/dev12c2_pipeline_profile_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_file_channel.dart';

import 'dev12b1_soak_helper.dart';

const int _mib = 1024 * 1024;

void main() {
  test('compare isolated SHA-256, disk I/O, AES-GCM and actual loopback', () async {
    expect(secureStreamPilotMaxBytes, 512 * _mib);
    final root = await Directory.systemTemp.createTemp('linyue_dev12c2_pipeline_');
    try {
      final source = await createDeterministicFile(root, 'source64m.bin', 64 * _mib);
      final copy = File('${root.path}${Platform.pathSeparator}copy64m.bin');
      final timer = Stopwatch();
      timer.start();
      final expected = (await hashes.sha256.bind(source.openRead()).first).toString();
      timer.stop();
      final hashMs = timer.elapsedMilliseconds;
      timer.reset();
      timer.start();
      await source.openRead().pipe(copy.openWrite());
      timer.stop();
      final diskMs = timer.elapsedMilliseconds;
      expect(await copy.length(), 64 * _mib);
      expect((await hashes.sha256.bind(copy.openRead()).first).toString(), expected);
      await copy.delete();

      final cipher = AesGcm.with256bits();
      // A fixed test-only key is acceptable in a synthetic benchmark; NEVER
      // use this key or deterministic source in production transfers.
      final key = SecretKey(List<int>.generate(32, (i) => i));
      final plain = Uint8List.fromList(List<int>.generate(256 * 1024,
        (i) => (i * 17 + 23) % 251));
      final aad = Uint8List.fromList(<int>[68, 69, 86, 49, 50, 67, 50]);
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 64; i++) {
        final nonce = Uint8List(12);
        // Unique per encryption using the test key; never repeat key+nonce.
        ByteData.sublistView(nonce).setUint32(8, i, Endian.big);
        final sealed = await cipher.encrypt(plain, secretKey: key,
          nonce: nonce, aad: aad);
        final opened = await cipher.decrypt(sealed,
          secretKey: key, aad: aad);
        expect(opened.length, plain.length);
        expect(opened[0], plain[0]);
      }
      stopwatch.stop();
      final aesMs = stopwatch.elapsedMilliseconds;
      print('[DEV12-C2] STAGE_SHA256 data=64MiB ms=$hashMs');
      print('[DEV12-C2] STAGE_DISK_COPY data=64MiB ms=$diskMs');
      print('[DEV12-C2] STAGE_AESGCM_ROUNDTRIP data=16MiB '
        'chunk_bytes=${plain.length} ms=$aesMs');
      print('[DEV12-C2] RSS_AT_STAGE_END MiB='
        '${(ProcessInfo.currentRss / _mib).toStringAsFixed(1)}');
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }

    final fixture = await SoakFixture.create();
    final memory = SoakMemorySampler();
    try {
      final durations = <Duration>[];
      await fixture.sendAndVerify(32 * _mib, 'dev12c2_loopback32.bin',
        memory: memory, timings: durations);
      expect(durations, hasLength(1));
      final ms = durations.single.inMilliseconds;
      print('[DEV12-C2] END_TO_END_LOOPBACK '
        'data=32MiB elapsed_ms=$ms '
        'MiB_per_s=${(32 * 1000 / (ms == 0 ? 1 : ms)).toStringAsFixed(2)} '
        'encrypted_handshakes=${fixture.sender.handshakeCount} '
        'receiver_consents=${fixture.consentCount}');
      print('[DEV12-C2] CAVEAT independent stage timings cannot be simply '
        'subtracted from end-to-end; QA RSS is not Android peak RAM');
    } finally {
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
