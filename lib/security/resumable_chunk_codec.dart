/// DEV10-D2: resumed transfer frames. Every attempt is encrypted under a
/// newly authenticated session and one-time accepted-offer token.
/// This primitive does NOT grant authentication or consent on its own.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'secure_chunk_stream.dart' show linyueStreamChunkSize;
import 'secure_core.dart' show secureRandomBytes;
import 'resume_checkpoint.dart';
import 'linear_resume_checkpoint.dart';

const String linyueResumeFramesVersion = 'linyue-resume-frames-d2-v1';
const int _data = 1, _end = 2;
const int _header = 5, _nonce = 12, _mac = 16;

class ResumableChunkCodec {
  final AesGcm _aes = AesGcm.with256bits();
  static void _validate(int size, int start, String sha, List<int> ctx) {
    if (size <= 0 || size > linearCheckpointMaxBytes ||
        start < 0 || start > size || start % linyueStreamChunkSize != 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) || ctx.length != 32) {
      throw const FormatException('invalid authenticated resume metadata');
    }
  }
  static List<int> _aad(List<int> ctx, int size, String sha, int start,
      int index, int kind) => utf8.encode(jsonEncode([
        linyueResumeFramesVersion, base64Url.encode(ctx), size, sha,
        start, index, kind,
      ]));

  Future<List<int>> _frame(SecretKey key, List<int> ctx, int size,
      String sha, int start, int index, int kind, List<int> plain) async {
    final nonce = secureRandomBytes(_nonce);
    final box = await _aes.encrypt(plain, secretKey: key, nonce: nonce,
      aad: _aad(ctx, size, sha, start, index, kind));
    final bytes = Uint8List(_header + _nonce + _mac + box.cipherText.length);
    bytes[0] = kind;
    ByteData.sublistView(bytes).setUint32(1, box.cipherText.length, Endian.big);
    bytes.setRange(_header, _header + _nonce, nonce);
    bytes.setRange(_header + _nonce, _header + _nonce + _mac, box.mac.bytes);
    bytes.setRange(_header + _nonce + _mac, bytes.length, box.cipherText);
    return bytes;
  }

  /// Stream only the suffix from the authenticated receiver-verified offset.
  /// Counts are total-file offsets, never fabricated progress or a receipt.
  Future<void> encodeRemaining({required File source, required SecretKey key,
      required List<int> context, required int total, required int offset,
      required String sha256, required Future<void> Function(List<int>) writeFrame,
      void Function(int)? onBytesSubmitted}) async {
    _validate(total, offset, sha256, context);
    if (await source.length() != total) throw StateError('source resized');
    final reader = await source.open(mode: FileMode.read);
    var at = offset;
    var index = offset ~/ linyueStreamChunkSize;
    try {
      await reader.setPosition(offset);
      while (at < total) {
        final data = await reader.read(math.min(linyueStreamChunkSize, total - at));
        if (data.isEmpty) throw StateError('source truncated');
        await writeFrame(await _frame(key, context, total, sha256,
          offset, index++, _data, data));
        at += data.length;
        onBytesSubmitted?.call(at);
      }
      if (await source.length() != total) throw StateError('source changed');
      // The authenticated end frame is mandatory even if offset==total.
      final footer = utf8.encode(jsonEncode([total, index, sha256]));
      await writeFrame(await _frame(key, context, total, sha256,
        offset, index, _end, footer));
    } finally { await reader.close(); }
  }

  /// Appends only fully authenticated chunks to a durable receiver-side .part.
  /// On network failure no valid checkpoint is deleted; uncommitted bytes
  /// are truncated before a fresh authenticated session may append more.
  Future<void> decodeRemaining({required Stream<List<int>> encrypted,
      ResumeCheckpointStore? store, LinearResumeCheckpointStore? linearStore, required String id,
      required SecretKey key, required List<int> context,
      required int total, required int offset, required String sha256,
      void Function(int)? onBytesVerified}) async {
    _validate(total, offset, sha256, context);
    if ((store == null) == (linearStore == null)) {
      throw StateError('exactly one checkpoint store must be selected');
    }
    // V1 never accepts an expanded 1 GiB transfer, even though the shared
    // framing codec can now authenticate a V2 1 GiB file.
    if (store != null && total > resumeCheckpointMaxBytes) {
      throw StateError('legacy V1 resume file exceeds 512 MiB');
    }
    final file = store != null ? store.partFile(id) : linearStore!.partFile(id);
    if (await file.length() != offset) throw StateError('resume prefix length mismatch');
    final reader = _ExactReader(encrypted);
    final writer = await file.open(mode: FileMode.append);
    var at = offset;
    var index = offset ~/ linyueStreamChunkSize;
    var lastCommitted = offset;
    try {
      while (true) {
        final hdr = await reader.exact(_header);
        final kind = hdr[0];
        final len = ByteData.sublistView(hdr).getUint32(1, Endian.big);
        if ((kind != _data && kind != _end) ||
            len > (kind == _data ? linyueStreamChunkSize : 160)) {
          throw const FormatException('bad encrypted resume record');
        }
        if (kind == _data && (len == 0 || at + len > total ||
            len != math.min(linyueStreamChunkSize, total - at))) {
          throw const FormatException('invalid resume chunk size');
        }
        final body = await reader.exact(_nonce + _mac + len);
        final plain = await _aes.decrypt(SecretBox(body.sublist(_nonce + _mac),
          nonce: body.sublist(0, _nonce), mac: Mac(body.sublist(_nonce, _nonce + _mac))),
          secretKey: key, aad: _aad(context, total, sha256, offset, index, kind));
        if (kind == _end) {
          final expected = jsonEncode([total, index, sha256]);
          if (utf8.decode(plain) != expected || at != total) {
            throw StateError('invalid authenticated resume end marker');
          }
          await reader.ensureFinished();
          await writer.flush();
          await writer.close();
          final digest = (await hashes.sha256.bind(file.openRead()).first).toString();
          if (digest != sha256) throw StateError('whole-file SHA-256 mismatch');
          if (store != null) {
            await store.commit(id, total);
          } else {
            await linearStore!.commit(id, total);
          }
          return;
        }
        await writer.writeFrom(plain);
        at += plain.length;
        index++;
        onBytesVerified?.call(at);
        // Journal only flushed, fully authenticated chunks every 4 MiB.
        if (at < total && at - lastCommitted >= 4 * 1024 * 1024) {
          await writer.flush();
          if (store != null) {
            await store.commit(id, at);
          } else {
            await linearStore!.commit(id, at);
          }
          lastCommitted = at;
        }
      }
    } finally {
      try { await writer.close(); } catch (_) {}
      await reader.cancel();
    }
  }
}

class _ExactReader {
  _ExactReader(Stream<List<int>> input) : _iter = StreamIterator<List<int>>(input);
  final StreamIterator<List<int>> _iter;
  List<int> _buffer = const [];
  int _pos = 0;
  Future<Uint8List> exact(int size) async {
    if (size < 0 || size > linyueStreamChunkSize + 128) {
      throw const FormatException('unbounded record allocation');
    }
    final output = Uint8List(size);
    var count = 0;
    while (count < size) {
      if (_pos == _buffer.length) {
        var found = false;
        while (await _iter.moveNext()) {
          _buffer = _iter.current;
          _pos = 0;
          if (_buffer.isNotEmpty) { found = true; break; }
        }
        if (!found) throw const FormatException('truncated encrypted frame');
      }
      final n = math.min(size-count, _buffer.length-_pos);
      output.setRange(count, count+n, _buffer, _pos);
      count += n;
      _pos += n;
    }
    return output;
  }
  Future<void> ensureFinished() async {
    if (_pos < _buffer.length) throw const FormatException('extra ciphertext');
    while (await _iter.moveNext()) {
      if (_iter.current.isNotEmpty) throw const FormatException('extra ciphertext');
    }
  }
  Future<void> cancel() => _iter.cancel();
}
