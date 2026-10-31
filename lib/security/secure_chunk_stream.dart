/// DEV10-B1: bounded-memory, authenticated chunk framing.
///
/// This is a separately testable transport primitive. DEV10-B1 intentionally
/// does not change the DEV10-A chat send/receive endpoints. The caller MUST
/// bind context to an authenticated session and a one-time file authorization,
/// and MUST check the encrypted server receipt before reporting completion.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'secure_core.dart' show secureRandomBytes;

const int linyueStreamChunkSize = 256 * 1024;
const int linyueStreamMaxBytes = 1024 * 1024 * 1024; // 1 GiB DEV10-B cap.
const String linyueStreamProtocol = 'linyue-stream-10b1-v1';
const int _recordData = 1;
const int _recordEnd = 2;
const int _headerLength = 5;
const int _nonceLength = 12;
const int _tagLength = 16;
const int _footerLength = 48;

class StreamFileResult {
  const StreamFileResult({required this.bytes, required this.chunks, required this.sha256});
  final int bytes;
  final int chunks;
  final String sha256;
}

/// Each record is: type:u8, ciphertextLen:u32be, nonce:12, tag:16, ciphertext.
/// Record nonce is fresh and every record authenticates the direction,
/// transfer context, file size, SHA-256 and monotonically increasing index.
/// Record type 2 is an authenticated EOF; truncated transfers never succeed.
class SecureChunkStream {
  SecureChunkStream({int chunkSize = linyueStreamChunkSize}) : chunkSize = chunkSize {
    if (chunkSize < 4096 || chunkSize > linyueStreamChunkSize) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be 4 KiB..256 KiB');
    }
  }

  final int chunkSize;
  final AesGcm _aes = AesGcm.with256bits();

  static void _check(int totalBytes, String sha256, List<int> context) {
    if (totalBytes < 0 || totalBytes > linyueStreamMaxBytes) {
      throw StateError('stream file size exceeds DEV10-B1 limit');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('expected 64-character lowercase SHA-256');
    }
    if (context.length != 32) {
      throw const FormatException('transfer context must have 32 bytes');
    }
  }

  static List<int> _aad(List<int> context, int size, String digest,
      String direction, int index, int type) => utf8.encode(jsonEncode([
        linyueStreamProtocol, base64Url.encode(context), size, digest,
        direction, index, type,
      ]));

  Future<List<int>> _record({required SecretKey key, required List<int> context,
      required int size, required String sha256, required String direction,
      required int index, required int type, required List<int> plain}) async {
    final nonce = secureRandomBytes(_nonceLength);
    final sealed = await _aes.encrypt(plain, secretKey: key, nonce: nonce,
      aad: _aad(context, size, sha256, direction, index, type));
    final out = Uint8List(_headerLength + _nonceLength + _tagLength + sealed.cipherText.length);
    out[0] = type;
    final view = ByteData.sublistView(out);
    view.setUint32(1, sealed.cipherText.length, Endian.big);
    out.setRange(_headerLength, _headerLength + _nonceLength, nonce);
    out.setRange(_headerLength + _nonceLength,
      _headerLength + _nonceLength + _tagLength, sealed.mac.bytes);
    out.setRange(_headerLength + _nonceLength + _tagLength, out.length,
      sealed.cipherText);
    return out;
  }

  /// Reads at most one bounded chunk at a time. `writeFrame` must apply
  /// backpressure (for an HTTP request use request.add + await request.flush).
  /// `onBytesSubmitted` counts local output, NOT an acknowledged download.
  Future<StreamFileResult> encodeFile({
    required File source,
    required SecretKey key,
    required List<int> context,
    required int expectedSize,
    required String expectedSha256,
    required Future<void> Function(List<int> frame) writeFrame,
    void Function(int bytesSubmitted)? onBytesSubmitted,
    String direction = 'a-to-b',
  }) async {
    _check(expectedSize, expectedSha256, context);
    if (await source.length() != expectedSize) {
      throw StateError('source file changed before streaming');
    }
    final input = await source.open(mode: FileMode.read);
    var offset = 0;
    var index = 0;
    try {
      while (offset < expectedSize) {
        final chunk = await input.read(math.min(chunkSize, expectedSize - offset));
        if (chunk.isEmpty) throw StateError('source file was truncated');
        final frame = await _record(key: key, context: context,
          size: expectedSize, sha256: expectedSha256, direction: direction,
          index: index, type: _recordData, plain: chunk);
        await writeFrame(frame);
        offset += chunk.length;
        index++;
        try { onBytesSubmitted?.call(offset); } catch (_) {}
      }
      // Protect against a changed source size; same-length changes are caught
      // by the receiving endpoint's expected digest verification.
      if (await source.length() != expectedSize) {
        throw StateError('source file size changed during streaming');
      }
      final footer = Uint8List(_footerLength);
      final footerView = ByteData.sublistView(footer);
      footerView.setUint64(0, expectedSize, Endian.big);
      footerView.setUint64(8, index, Endian.big);
      footer.setRange(16, 48, _parseDigest(expectedSha256));
      await writeFrame(await _record(key: key, context: context,
        size: expectedSize, sha256: expectedSha256, direction: direction,
        index: index, type: _recordEnd, plain: footer));
      return StreamFileResult(bytes: offset, chunks: index, sha256: expectedSha256);
    } finally {
      await input.close();
    }
  }

  /// Decrypts a network byte stream straight into a disposable `.part` file.
  /// The file is deleted on every failure; the caller must move it atomically
  /// to its unique final destination only after a successful return.
  Future<StreamFileResult> decodeToTemporaryFile({
    required Stream<List<int>> encrypted,
    required File temporary,
    required SecretKey key,
    required List<int> context,
    required int expectedSize,
    required String expectedSha256,
    void Function(int bytesWritten)? onBytesWritten,
    String direction = 'a-to-b',
  }) async {
    _check(expectedSize, expectedSha256, context);
    if (await temporary.exists()) throw StateError('temporary file already exists');
    await temporary.parent.create(recursive: true);
    final reader = _BoundedReader(encrypted);
    RandomAccessFile? out;
    var written = 0;
    var chunks = 0;
    try {
      final writer = await temporary.open(mode: FileMode.writeOnly);
      out = writer;
      while (true) {
        final header = await reader.exact(_headerLength);
        final type = header[0];
        final length = ByteData.sublistView(header).getUint32(1, Endian.big);
        if (type != _recordData && type != _recordEnd) {
          throw const FormatException('unknown record type');
        }
        if (length > (type == _recordEnd ? _footerLength : chunkSize)) {
          throw const FormatException('oversized encrypted chunk');
        }
        if (type == _recordData && (length == 0 || written + length > expectedSize)) {
          throw const FormatException('bad chunk size or excess bytes');
        }
        if (type == _recordEnd && length != _footerLength) {
          throw const FormatException('invalid authenticated EOF');
        }
        final packet = await reader.exact(_nonceLength + _tagLength + length);
        final nonce = packet.sublist(0, _nonceLength);
        final tag = packet.sublist(_nonceLength, _nonceLength + _tagLength);
        final cipher = packet.sublist(_nonceLength + _tagLength);
        final plain = await _aes.decrypt(SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
          secretKey: key,
          aad: _aad(context, expectedSize, expectedSha256, direction, chunks, type));
        if (type == _recordEnd) {
          final footerView = ByteData.sublistView(Uint8List.fromList(plain));
          final footerSize = footerView.getUint64(0, Endian.big);
          final footerChunks = footerView.getUint64(8, Endian.big);
          if (footerSize != expectedSize || footerChunks != chunks ||
              written != expectedSize ||
              !_digestMatches(plain.sublist(16), _parseDigest(expectedSha256))) {
            throw StateError('authenticated EOF does not match file offer');
          }
          await reader.ensureFinished();
          await writer.flush();
          await writer.close();
          out = null;
          final actual = (await hashes.sha256.bind(temporary.openRead()).first).toString();
          if (actual != expectedSha256) throw StateError('file digest mismatch');
          return StreamFileResult(bytes: written, chunks: chunks, sha256: actual);
        }
        await writer.writeFrom(plain);
        written += plain.length;
        chunks++;
        try { onBytesWritten?.call(written); } catch (_) {}
      }
    } catch (_) {
      if (out != null) { try { await out.close(); } catch (_) {} }
      try { if (await temporary.exists()) await temporary.delete(); } catch (_) {}
      rethrow;
    } finally {
      await reader.cancel();
    }
  }

  static List<int> _parseDigest(String hex) => List<int>.generate(32, (i) =>
    int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));

  static bool _digestMatches(List<int> actual, List<int> expected) {
    if (actual.length != expected.length) return false;
    var different = 0;
    for (var i = 0; i < actual.length; i++) {
      different |= actual[i] ^ expected[i];
    }
    return different == 0;
  }
}

class _BoundedReader {
  _BoundedReader(Stream<List<int>> source) : _iterator = StreamIterator(source);
  final StreamIterator<List<int>> _iterator;
  List<int> _part = const [];
  int _pos = 0;
  bool _ended = false;

  Future<Uint8List> exact(int bytes) async {
    if (bytes < 0 || bytes > linyueStreamChunkSize + 128) {
      throw const FormatException('record allocation exceeds bounded limit');
    }
    final out = Uint8List(bytes);
    var written = 0;
    while (written < bytes) {
      if (_pos >= _part.length) {
        if (!await _nextNonEmpty()) throw const FormatException('truncated chunk stream');
      }
      final take = math.min(bytes - written, _part.length - _pos);
      out.setRange(written, written + take, _part, _pos);
      written += take;
      _pos += take;
    }
    return out;
  }

  Future<bool> _nextNonEmpty() async {
    if (_ended) return false;
    while (await _iterator.moveNext()) {
      _part = _iterator.current;
      _pos = 0;
      if (_part.isNotEmpty) return true;
    }
    _ended = true;
    return false;
  }

  Future<void> ensureFinished() async {
    if (_pos < _part.length) throw const FormatException('trailing encrypted data');
    if (await _nextNonEmpty()) throw const FormatException('trailing encrypted data');
  }

  Future<void> cancel() => _iterator.cancel();
}
