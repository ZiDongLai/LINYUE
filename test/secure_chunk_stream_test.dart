import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_chunk_stream.dart';

Future<File> _source(Directory root, String name, int length) async {
  final file = File('${root.path}${Platform.pathSeparator}$name');
  final writer = await file.open(mode: FileMode.writeOnly);
  try {
    final block = List<int>.generate(65536, (index) => (index * 17 + 3) % 256);
    var written = 0;
    while (written < length) {
      final part = math.min(block.length, length - written);
      await writer.writeFrom(block, 0, part);
      written += part;
    }
    await writer.flush();
  } finally {
    await writer.close();
  }
  return file;
}

Future<File> _encode(Directory dir, File source, SecretKey key, List<int> context,
    String hash, {void Function(int)? onProgress}) async {
  final codec = SecureChunkStream();
  final destination = File('${dir.path}${Platform.pathSeparator}encrypted.bin');
  final out = await destination.open(mode: FileMode.writeOnly);
  try {
    await codec.encodeFile(source: source, key: key, context: context,
      expectedSize: await source.length(), expectedSha256: hash,
      writeFrame: (frame) async { await out.writeFrom(frame); },
      onBytesSubmitted: onProgress);
  } finally {
    await out.close();
  }
  return destination;
}

void main() {
  late Directory dir;
  late SecretKey key;
  late List<int> context;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('linyue_stream_');
    key = await AesGcm.with256bits().newSecretKey();
    context = List<int>.generate(32, (i) => i + 1);
  });

  tearDown(() async {
    if (!await dir.exists()) return;

    for (var attempt = 0; attempt < 12; attempt++) {
      try {
        await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        if (!Platform.isWindows || attempt == 11) rethrow;

        await Future<void>.delayed(
          Duration(milliseconds: 200 * (attempt + 1)),
        );
      }
    }
  });


  test('35 MiB file round trip in 256 KiB records, bounded progress', () async {
    final source = await _source(dir, 'source.bin', 35 * 1024 * 1024 + 19);
    final digest = (await hashes.sha256.bind(source.openRead()).first).toString();
    final uploaded = <int>[];
    final encrypted = await _encode(dir, source, key, context, digest,
      onProgress: uploaded.add);
    final downloaded = <int>[];
    final output = File('${dir.path}/incoming.part');
    final result = await SecureChunkStream().decodeToTemporaryFile(
      encrypted: encrypted.openRead(), temporary: output, key: key, context: context,
      expectedSize: await source.length(), expectedSha256: digest,
      onBytesWritten: downloaded.add);
    expect(result.bytes, await source.length());
    expect(result.sha256, digest);
    expect(result.chunks, greaterThan(100));
    expect(uploaded, orderedEquals([...uploaded]..sort()));
    expect(downloaded, orderedEquals([...downloaded]..sort()));
    expect(uploaded.last, result.bytes);
    expect(downloaded.last, result.bytes);
    expect((await hashes.sha256.bind(output.openRead()).first).toString(), digest);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('zero byte file requires authenticated EOF', () async {
    final source = await _source(dir, 'empty.txt', 0);
    final digest = (await hashes.sha256.bind(source.openRead()).first).toString();
    final encrypted = await _encode(dir, source, key, context, digest);
    final result = await SecureChunkStream().decodeToTemporaryFile(
      encrypted: encrypted.openRead(), temporary: File('${dir.path}/zero.part'),
      key: key, context: context, expectedSize: 0, expectedSha256: digest);
    expect(result.chunks, 0);
    expect(result.bytes, 0);
  });

  test('corruption or wrong transfer context cannot produce a file', () async {
    final source = await _source(dir, 'a.bin', 600000);
    final digest = (await hashes.sha256.bind(source.openRead()).first).toString();
    final encrypted = await _encode(dir, source, key, context, digest);
    final part = File('${dir.path}/wrong-context.part');
    await expectLater(SecureChunkStream().decodeToTemporaryFile(
      encrypted: encrypted.openRead(), temporary: part, key: key,
      context: List<int>.filled(32, 7), expectedSize: await source.length(),
      expectedSha256: digest), throwsA(isA<Object>()));
    expect(await part.exists(), false);

    final bytes = await encrypted.readAsBytes();
    bytes[70] ^= 0x55;
    await encrypted.writeAsBytes(bytes);
    final corruptPart = File('${dir.path}/corrupted.part');
    await expectLater(SecureChunkStream().decodeToTemporaryFile(
      encrypted: encrypted.openRead(), temporary: corruptPart, key: key,
      context: context, expectedSize: await source.length(),
      expectedSha256: digest), throwsA(isA<Object>()));
    expect(await corruptPart.exists(), false);
  });

  test('missing EOF and trailing ciphertext are rejected', () async {
    final source = await _source(dir, 'small.bin', 8192);
    final digest = (await hashes.sha256.bind(source.openRead()).first).toString();
    final encrypted = await _encode(dir, source, key, context, digest);
    final bytes = await encrypted.readAsBytes();
    final truncated = File('${dir.path}/truncated.bin')..writeAsBytesSync(bytes.sublist(0, bytes.length - 10));
    final part = File('${dir.path}/truncated.part');
    await expectLater(SecureChunkStream().decodeToTemporaryFile(
      encrypted: truncated.openRead(), temporary: part, key: key,
      context: context, expectedSize: await source.length(),
      expectedSha256: digest), throwsA(isA<FormatException>()));
    expect(await part.exists(), false);

    final trailing = File('${dir.path}/trailing.bin')..writeAsBytesSync([...bytes, 99]);
    final second = File('${dir.path}/trailing.part');
    await expectLater(SecureChunkStream().decodeToTemporaryFile(
      encrypted: trailing.openRead(), temporary: second, key: key,
      context: context, expectedSize: await source.length(),
      expectedSha256: digest), throwsA(isA<FormatException>()));
    expect(await second.exists(), false);
  });


  test('reordered encrypted chunks are rejected before file becomes visible', () async {
    final source = await _source(dir, 'reorder.bin', 700000);
    final digest = (await hashes.sha256.bind(source.openRead()).first).toString();
    final encrypted = await _encode(dir, source, key, context, digest);
    final bytes = await encrypted.readAsBytes();
    // First two data records have the same full size and can be swapped.
    final frameSize = 5 + 12 + 16 + linyueStreamChunkSize;
    final first = bytes.sublist(0, frameSize);
    final second = bytes.sublist(frameSize, 2 * frameSize);
    bytes.setRange(0, frameSize, second);
    bytes.setRange(frameSize, 2 * frameSize, first);
    await encrypted.writeAsBytes(bytes);
    final part = File('${dir.path}/reorder.part');
    await expectLater(SecureChunkStream().decodeToTemporaryFile(
      encrypted: encrypted.openRead(), temporary: part, key: key,
      context: context, expectedSize: await source.length(),
      expectedSha256: digest), throwsA(isA<Object>()));
    expect(await part.exists(), false);
  });

  test('size cap and invalid digest stop before file creation', () async {
    final source = await _source(dir, 'small.bin', 2);
    await expectLater(SecureChunkStream().encodeFile(
      source: source, key: key, context: context,
      expectedSize: linyueStreamMaxBytes + 1,
      expectedSha256: List<String>.filled(64, '0').join(),
      writeFrame: (_) async {}), throwsA(isA<StateError>()));
    final invalid = File('${dir.path}/invalid.part');
    await expectLater(SecureChunkStream().decodeToTemporaryFile(
      encrypted: const Stream<List<int>>.empty(), temporary: invalid,
      key: key, context: context, expectedSize: 4,
      expectedSha256: 'bad'), throwsA(isA<FormatException>()));
    expect(await invalid.exists(), false);
  });
}
