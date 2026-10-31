import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'conversation_text_protocol.dart';

/// DEV13D2E18-A: standalone, opt-in-at-integration encrypted text history.
/// Not wired to the UI or network in this stage. A future integration must
/// obtain a random per-installation key from the platform secure key vault.
/// NEVER save [encryptionKey] in [directory], logs, or exported backups.
class EncryptedTextHistoryStore {
  EncryptedTextHistoryStore({
    required this.directory,
    required List<int> encryptionKey,
    this.maxMessagesPerPeer = 500,
  }) : _key = SecretKeyData(Uint8List.fromList(encryptionKey)) {
    if (encryptionKey.length != 32) {
      throw ArgumentError.value(encryptionKey.length, 'encryptionKey', 'AES-256 requires 32 bytes');
    }
    if (maxMessagesPerPeer < 1 || maxMessagesPerPeer > 2000) {
      throw ArgumentError.value(maxMessagesPerPeer, 'maxMessagesPerPeer');
    }
  }

  final Directory directory;
  final SecretKey _key;
  final int maxMessagesPerPeer;
  final AesGcm _cipher = AesGcm.with256bits();
  Future<void> _pendingOperation = Future<void>.value();

  // Do not expose fingerprints in filenames (the encrypted payload includes
  // the identity and is verified again during every read).
  String _fileStem(String fingerprint) {
    _checkFingerprint(fingerprint);
    final hash = hashes.sha256.convert(utf8.encode('linyue-text-history-v1:$fingerprint'));
    return '${directory.path}${Platform.pathSeparator}peer_$hash';
  }

  static void _checkFingerprint(String fingerprint) {
    if (fingerprint.trim().isEmpty || fingerprint.length > 512 ||
        fingerprint.contains('\u0000')) {
      throw const FormatException('Missing or invalid authenticated peer fingerprint');
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() task) {
    final Future<T> result = _pendingOperation.then((_) => task());
    _pendingOperation = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// Returns a bounded, immutable snapshot for an already authenticated peer.
  /// An invalid/corrupted document fails closed; it is NEVER auto-reset.
  Future<List<PersistedTextItem>> loadPeer(String authenticatedFingerprint) =>
      _exclusive(() => _load(authenticatedFingerprint));

  /// Only call for a VERIFIED incoming message or an outgoing message whose
  /// authenticated receiver ACK has been checked. Drafts and unconfirmed
  /// sends must not be recorded as delivered.
  Future<bool> saveConfirmed({
    required String authenticatedFingerprint,
    required TextChatMessage message,
    required bool outbound,
  }) => _exclusive(() async {
        _checkFingerprint(authenticatedFingerprint);
        message.validate();
        final previous = await _load(authenticatedFingerprint);
        if (previous.any((e) => e.message.id == message.id)) return false;
        final next = [
          ...previous,
          PersistedTextItem(message: message, outbound: outbound),
        ];
        if (next.length > maxMessagesPerPeer) {
          next.removeRange(0, next.length - maxMessagesPerPeer);
        }
        await _write(authenticatedFingerprint, next);
        return true;
      });

  /// Removing text removes only that peer's text history. It does NOT delete
  /// received files, gallery files, remote messages, or file transfer history.
  Future<int> deleteMessages({
    required String authenticatedFingerprint,
    required Set<String> messageIds,
  }) => _exclusive(() async {
        final old = await _load(authenticatedFingerprint);
        if (messageIds.isEmpty) return 0;
        if (messageIds.any((id) => !ConversationTextProtocol.validId(id))) {
          throw const FormatException('Invalid message id');
        }
        final keep = old.where((item) => !messageIds.contains(item.message.id)).toList();
        if (old.length != keep.length) await _write(authenticatedFingerprint, keep);
        return old.length - keep.length;
      });

  /// Persists an encrypted empty snapshot instead of deleting the journal.
  /// A crash BEFORE commit may retain the last committed snapshot; callers
  /// must report success only after this Future completes.
  Future<void> clearPeer(String authenticatedFingerprint) =>
      _exclusive(() async {
        await _load(authenticatedFingerprint); // validate before replacing
        await _write(authenticatedFingerprint, const []);
      });

  Future<List<PersistedTextItem>> _load(String fingerprint) async {
    final stem = _fileStem(fingerprint);
    final main = File('$stem.enc');
    final prior = File('$stem.previous');
    final file = await main.exists() ? main : (await prior.exists() ? prior : null);
    if (file == null) return const [];
    final bytes = await file.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) throw const FormatException('History exceeds limit');
    try {
      final envelope = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (envelope is! Map<String, dynamic> || envelope.length != 5 ||
          envelope['v'] != 1 || envelope['nonce'] is! String ||
          envelope['ciphertext'] is! String || envelope['mac'] is! String ||
          envelope['format'] != 'linyue.text-history.encrypted') {
        throw const FormatException('Invalid encrypted history envelope');
      }
      final nonce = base64Decode(envelope['nonce'] as String);
      final cipherText = base64Decode(envelope['ciphertext'] as String);
      final mac = base64Decode(envelope['mac'] as String);
      if (nonce.length != 12 || mac.length != 16) {
        throw const FormatException('Invalid encrypted history nonce or MAC');
      }
      final plain = await _cipher.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: _key, aad: _aad(fingerprint),
      );
      final doc = jsonDecode(utf8.decode(plain, allowMalformed: false));
      if (doc is! Map<String, dynamic> || doc.length != 3 ||
          doc['v'] != 1 || doc['peer'] != fingerprint || doc['items'] is! List) {
        throw const FormatException('Invalid authenticated history payload');
      }
      final items = doc['items'] as List<dynamic>;
      if (items.length > maxMessagesPerPeer) throw const FormatException('Too many history entries');
      final result = <PersistedTextItem>[];
      final seen = <String>{};
      for (final raw in items) {
        if (raw is! Map<String, dynamic> || raw.length != 4 ||
            raw['id'] is! String || raw['at'] is! String ||
            raw['body'] is! String || raw['outbound'] is! bool) {
          throw const FormatException('Invalid history entry');
        }
        final date = DateTime.tryParse(raw['at'] as String);
        if (date == null || !(raw['at'] as String).endsWith('Z')) {
          throw const FormatException('Invalid history timestamp');
        }
        final msg = TextChatMessage(
          id: raw['id'] as String,
          createdAt: date.toUtc(),
          body: raw['body'] as String,
        )..validate();
        if (!seen.add(msg.id)) throw const FormatException('Duplicate persisted message ID');
        result.add(PersistedTextItem(message: msg, outbound: raw['outbound'] as bool));
      }
      return List<PersistedTextItem>.unmodifiable(result);
    } catch (e) {
      // Preserve corrupted ciphertext as evidence: NEVER erase or replace it.
      if (e is FileSystemException) rethrow;
      throw const FormatException('Cannot authenticate/decode local text history');
    }
  }

  List<int> _aad(String fingerprint) =>
      utf8.encode('LINYUE_TEXT_HISTORY_V1:$fingerprint');

  Future<void> _write(String fingerprint, List<PersistedTextItem> items) async {
    final stem = _fileStem(fingerprint);
    final main = File('$stem.enc');
    final stage = File('$stem.pending');
    final prior = File('$stem.previous');
    await directory.create(recursive: true);
    final entries = [
      for (final item in items)
        <String, Object>{
          'id': item.message.id,
          'at': item.message.createdAt.toUtc().toIso8601String(),
          'body': item.message.body,
          'outbound': item.outbound,
        },
    ];
    final plain = utf8.encode(jsonEncode({'v': 1, 'peer': fingerprint, 'items': entries}));
    final box = await _cipher.encrypt(plain, secretKey: _key, aad: _aad(fingerprint));
    final envelope = jsonEncode({
      'v': 1, 'format': 'linyue.text-history.encrypted',
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
    if (await stage.exists()) await stage.delete();
    await stage.writeAsString(envelope, flush: true);
    // Windows cannot always rename a file over an existing target.
    // Keep a recovery copy through the brief replacement window.
    var movedPrevious = false;
    try {
      if (await main.exists()) {
        if (await prior.exists()) await prior.delete();
        await main.rename(prior.path);
        movedPrevious = true;
      }
      await stage.rename(main.path);
      if (await prior.exists()) {
        try { await prior.delete(); } on FileSystemException { /* safe stale backup */ }
      }
    } catch (_) {
      if (movedPrevious && !await main.exists() && await prior.exists()) {
        try { await prior.rename(main.path); } on FileSystemException { /* retain backup */ }
      }
      rethrow;
    }
  }
}

final class PersistedTextItem {
  const PersistedTextItem({required this.message, required this.outbound});
  final TextChatMessage message;
  final bool outbound;
}
