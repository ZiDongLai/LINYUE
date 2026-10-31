/// DEV9A: independently tested authenticated, encrypted file channel.
/// NOT wired into the production chat UI yet. Existing HTTP transfer is still
/// plaintext until DEV9B explicitly switches the UI and disables legacy POSTs.
/// Max 20 MiB, one buffered file at a time; streaming is a future milestone.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'device_identity.dart';
import '../services/transfer_progress.dart';
import '../services/disk_capacity_guard.dart';
import '../services/conversation_text_protocol.dart';
import 'secure_core.dart' show secureRandomBytes;
import 'secure_chunk_stream.dart';
import 'resume_checkpoint.dart';
import 'linear_resume_checkpoint.dart';
import 'resume_format_router.dart';
import 'resume_completion_receipt.dart';
import 'resumable_chunk_codec.dart';

const String secureFileVersion = 'linyue-encrypted-file-dev9a-v1';
const int secureFilePort = 46732;
const int secureFileMaxBytes = 20 * 1024 * 1024;
// DEV12-D2: Only authenticated V2 resumed transfers may reach 1 GiB.
// The legacy encrypted non-resumable stream stays at 512 MiB.
const int secureLegacyStreamMaxBytes = 512 * 1024 * 1024;
const int secureStreamPilotMaxBytes = 1024 * 1024 * 1024;
const String secureStreamMode = 'authenticated-chunks-10b2-v1';
const String secureResumeMode = 'authenticated-chunks-resume-10d2-v1';
const int _maxSessions = 12;

/// E17-B1: optional encrypted text messages. No legacy plaintext route.
const String secureTextCapability = ConversationTextProtocol.capability;

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
List<int> _decode(Object? raw, int length) {
  if (raw is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(raw)) {
    throw const FormatException('invalid base64');
  }
  final decoded = base64Url.decode(base64Url.normalize(raw));
  if (decoded.length != length || _encode(decoded) != raw) {
    throw const FormatException('wrong base64 length');
  }
  return decoded;
}
String _hex(int bytes) => secureRandomBytes(bytes).map((n) => n.toRadixString(16).padLeft(2, '0')).join();
List<int> _bytes(Object? o, int length) => _decode(o, length);

String _filename(String name) {
  final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  if (clean.isEmpty || clean == '.' || clean == '..') throw const FormatException('bad name');
  return clean.length <= 120 ? clean : clean.substring(clean.length - 120);
}

/// An authenticated ACK from the peer's in-memory message handler.
final class TextSendReceipt {
  const TextSendReceipt({required this.messageId, required this.alreadyReceived});
  final String messageId;
  final bool alreadyReceived;
}

class SecureIncomingOffer {
  const SecureIncomingOffer({required this.fileName, required this.size,
    required this.peerName, required this.fingerprint,
    required this.remoteIp});
  final String fileName;
  final int size;
  final String peerName;
  final String fingerprint;
  final String remoteIp;
}

class _Handshake {
  _Handshake({required this.id, required this.aCard, required this.bCard,
    required this.aEphemeral, required this.bEphemeral,
    required this.aNonce, required this.bNonce});
  final String id, aCard, bCard, aEphemeral, bEphemeral, aNonce, bNonce;
  List<int> get bytes => utf8.encode(jsonEncode([
    secureFileVersion, id, aCard, bCard, aEphemeral, bEphemeral, aNonce, bNonce,
  ]));
  List<int> message(String role) => utf8.encode(jsonEncode([
    secureFileVersion, role, id, aCard, bCard, aEphemeral, bEphemeral, aNonce, bNonce,
  ]));
  List<int> get hash => hashes.sha256.convert(bytes).bytes;
}

class _Session {
  _Session({required this.id, required this.peerFingerprint,
    required this.remoteIp, required this.sendKey, required this.receiveKey,
    required this.transcriptHash, required this.confirmed});
  final String id, peerFingerprint, remoteIp;
  final SecretKey sendKey, receiveKey;
  final List<int> transcriptHash;
  bool confirmed;
  bool textCapabilityConfirmed = false;
  int incomingSequence = 0;
  int outgoingSequence = 0;
  bool busy = false;
  DateTime lastUsed = DateTime.now();
  bool get expired => DateTime.now().difference(lastUsed) > const Duration(minutes: 10);
  void touch() => lastUsed = DateTime.now();
}

class _AcceptedFile {
  _AcceptedFile({required this.sessionId, required this.senderIp,
    required this.name, required this.size, required this.hash,
    required this.streamMode, this.resumeId, this.checkpointFormat = ResumeCheckpointFormat.legacyV1})
      : expiry = DateTime.now().add(const Duration(minutes: 2));
  final String sessionId, senderIp, name, hash;
  final bool streamMode;
  final String? resumeId;
  final ResumeCheckpointFormat checkpointFormat;
  final int size;
  final DateTime expiry;
}

/// One instance on each device. The UI will integrate this class in DEV9B.
class SecureFileChannel {
  SecureFileChannel(this.identity, {required this.targetDirectory, this.receiveDiskGuard});
  /// Optional for low-level protocol tests; production UI always supplies it.
  final DiskCapacityGuard? receiveDiskGuard;
  void Function(String message)? onStorageWarning;
  final DeviceIdentityManager identity;
  Directory targetDirectory;

  /// The chosen folder applies only to *new* transfer offers. Refuse changes
  /// while a file is being written or an offer awaits an upload.
  Future<void> updateReceiveDirectory(Directory destination) async {
    if (_writingFile || _offers.isNotEmpty) {
      throw StateError('正在接收文件或等待上传，请稍后修改接收位置');
    }
    if (!await destination.exists()) {
      throw FileSystemException('接收目录不存在', destination.path);
    }
    // Validate filesystem access before mutating the live receiver.
    final probe = File('${destination.path}${Platform.pathSeparator}.linyue_probe_${DateTime.now().microsecondsSinceEpoch}');
    try {
      await probe.writeAsBytes([76, 89], flush: true);
    } finally {
      try { if (await probe.exists()) await probe.delete(); } catch (_) {}
    }
    targetDirectory = destination;
  }
  Future<bool> Function(SecureIncomingOffer)? askReceiver;
  void Function(File)? onReceived;
  void Function(File, String fingerprint)? onVerifiedReceived;

  /// E17-B1: enable text capabilities ONLY when a consumer has installed
  /// a handler. Returning false refuses ACK and allows later retry.
  Future<bool> Function(TextChatMessage message, String authenticatedPeerFingerprint)?
      onVerifiedTextMessage;
  void Function(TransferProgressInfo)? onIncomingProgress;
  HttpServer? _server;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final Map<String, _Session> _incomingSessions = {};
  final Map<String, _Session> _outgoingSessions = {};
  final Map<String, _AcceptedFile> _offers = {};
  final Set<String> _seenHello = {};
  // ACKed text IDs are bounded; scoped to an authenticated fingerprint.
  final LinkedHashSet<String> _ackedTextIds = LinkedHashSet<String>();
  final Set<String> _processingTextIds = <String>{};
  static const int _maxAckedTextIds = 2048;
  int _handshakes = 0;
  bool _writingFile = false;

  /// Test-only: count newly authenticated encrypted sessions, not SAS prompts.
  int get handshakeCount => _handshakes;
  int? get boundPort => _server?.port;

  bool _trusted(PublicIdentityCard card) =>
      identity.entries.any((entry) => entry.fingerprint == card.fingerprint);

  File _resumeNameFile(ResumeCheckpointStore store, String id) => File(
    '${store.directory.path}${Platform.pathSeparator}.linyue_resume_$id.name');

  void _sweep() {
    _incomingSessions.removeWhere((_, s) => s.expired);
    _outgoingSessions.removeWhere((_, s) => s.expired);
    _offers.removeWhere((_, value) => DateTime.now().isAfter(value.expiry));
    if (_seenHello.length > 2000) _seenHello.clear();
  }

  Future<void> start({InternetAddress? bindAddress, int port = secureFilePort}) async {
    if (_server != null) return;
    identity.local; // Refuse if platform identity is not initialized.
    _server = await HttpServer.bind(bindAddress ?? InternetAddress.anyIPv4, port);
    _server!.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    final old = _server;
    _server = null;
    await old?.close(force: true);
    _incomingSessions.clear();
    _outgoingSessions.clear();
    _offers.clear();
    _seenHello.clear();
    _ackedTextIds.clear();
    _processingTextIds.clear();
    _client.close(force: true);
  }

  Future<List<int>> _read(HttpRequest req, int max, {void Function(int)? onBytes}) async {
    if (req.contentLength > max) throw const FormatException('payload too large');
    final output = BytesBuilder(copy: false);
    await for (final part in req.timeout(const Duration(seconds: 100))) {
      if (output.length + part.length > max) throw const FormatException('payload too large');
      output.add(part);
      if (onBytes != null) {
        try { onBytes(output.length); } catch (_) {} // UI cannot break networking.
      }
    }
    return output.takeBytes();
  }

  Future<Map<String, dynamic>> _json(HttpRequest req, {int limit = 8192}) async {
    final object = jsonDecode(utf8.decode(await _read(req, limit)));
    if (object is! Map<String, dynamic> || object['v'] != secureFileVersion) {
      throw const FormatException('protocol mismatch');
    }
    return object;
  }

  Future<void> _reply(HttpRequest req, int status, Object data) async {
    req.response.statusCode = status;
    if (data is List<int>) {
      req.response.headers.contentType = ContentType.binary;
      req.response.add(data);
    } else {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(data));
    }
    await req.response.close();
  }

  List<int> _aad(_Session session, String direction, String kind, int sequence) =>
      utf8.encode(jsonEncode([
        secureFileVersion, session.id, _encode(session.transcriptHash),
        direction, kind, sequence,
      ]));

  Future<List<int>> _seal(_Session session, String direction, String kind,
      int sequence, List<int> plain) async {
    final nonce = secureRandomBytes(12);
    final box = await AesGcm.with256bits().encrypt(plain,
      secretKey: session.sendKey, nonce: nonce,
      aad: _aad(session, direction, kind, sequence));
    return [...nonce, ...box.mac.bytes, ...box.cipherText];
  }

  Future<List<int>> _open(_Session session, String direction, String kind,
      int sequence, List<int> payload) async {
    if (payload.length < 28) throw const FormatException('truncated sealed payload');
    return AesGcm.with256bits().decrypt(
      SecretBox(payload.sublist(28), nonce: payload.sublist(0, 12),
        mac: Mac(payload.sublist(12, 28))),
      secretKey: session.receiveKey,
      aad: _aad(session, direction, kind, sequence));
  }

  Future<_Session> _sessionFor(_Handshake hand, SimpleKeyPair myEphemeral,
      SimplePublicKey remoteEphemeral, String remoteIp, bool server) async {
    final shared = await X25519().sharedSecretKey(
      keyPair: myEphemeral, remotePublicKey: remoteEphemeral);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final sendLabel = server ? 'b-to-a' : 'a-to-b';
    final recvLabel = server ? 'a-to-b' : 'b-to-a';
    Future<SecretKey> derive(String label) => hkdf.deriveKey(
      secretKey: shared, nonce: hand.hash,
      info: utf8.encode('$secureFileVersion|$label'));
    return _Session(id: hand.id,
      peerFingerprint: PublicIdentityCard.parse(server ? hand.aCard : hand.bCard).fingerprint,
      remoteIp: remoteIp,
      sendKey: await derive(sendLabel), receiveKey: await derive(recvLabel),
      transcriptHash: hand.hash, confirmed: false);
  }

  // Bind every encrypted chunk to the *signed* session transcript, one-time
  // accepted offer token and strictly increasing transfer sequence. Distinct
  // from control-record AAD and never accepted by the buffered upload route.
  List<int> _resumeContext(_Session session, String token,
      int sequence, String resumeId, int offset) =>
    hashes.sha256.convert(utf8.encode(jsonEncode([
      secureFileVersion, secureResumeMode, session.id,
      _encode(session.transcriptHash), token, sequence, resumeId, offset,
    ]))).bytes;

  List<int> _streamContext(_Session session, String token, int sequence) =>
    hashes.sha256.convert(utf8.encode(jsonEncode([
      secureFileVersion, secureStreamMode, session.id,
      _encode(session.transcriptHash), token, sequence,
    ]))).bytes;

  Future<void> _handle(HttpRequest req) async {
    TransferProgressInfo? trackedIncoming;
    void notifyIncoming(TransferProgressInfo update) {
      trackedIncoming = update;
      try { onIncomingProgress?.call(update); } catch (_) {}
    }
    try {
      if (req.method != 'POST') { await _reply(req, 405, {'error': 'method'}); return; }
      final ip = req.connectionInfo?.remoteAddress.address;
      if (ip == null) throw StateError('missing source address');
      _sweep();
      if (req.uri.path == '/v1/hello') {
        final payload = await _json(req);
        if (_incomingSessions.length >= _maxSessions) throw StateError('busy');
        final card = PublicIdentityCard.parse(payload['card'] as String);
        if (!_trusted(card)) throw StateError('unknown identity');
        final ea = SimplePublicKey(_bytes(payload['e'], 32), type: KeyPairType.x25519);
        final na = _encode(_bytes(payload['n'], 16));
        final challenge = utf8.encode(jsonEncode([
          secureFileVersion, 'hello', card.encoded, payload['e'], na,
        ]));
        if (!await Ed25519().verify(challenge,
          signature: Signature(_bytes(payload['sig'], 64), publicKey: card.key))) {
          throw StateError('bad signature');
        }
        final seen = '${card.fingerprint}:$na';
        if (!_seenHello.add(seen)) throw StateError('hello replay');
        final ebKey = await X25519().newKeyPair();
        final eb = await ebKey.extractPublicKey();
        final hand = _Handshake(id: _hex(16), aCard: card.encoded,
          bCard: identity.local.card, aEphemeral: payload['e'] as String,
          bEphemeral: _encode(eb.bytes), aNonce: na,
          bNonce: _encode(secureRandomBytes(16)));
        final session = await _sessionFor(hand, ebKey, ea, ip, true);
        _incomingSessions[session.id] = session;
        final signed = await identity.local.sign(hand.message('responder'));
        await _reply(req, 200, {'v': secureFileVersion, 'id': hand.id,
          'card': identity.local.card, 'e': hand.bEphemeral,
          'n': hand.bNonce, 'sig': _encode(signed.bytes)});
        return;
      }
      if (req.uri.path == '/v1/confirm') {
        final body = await _json(req);
        final id = body['id'];
        final s = _incomingSessions[id];
        if (s == null || s.remoteIp != ip || s.confirmed) throw StateError('missing session');
        final transcript = body['transcript'];
        if (transcript is! String || transcript != _encode(s.transcriptHash)) {
          throw StateError('transcript mismatch');
        }
        final registered = identity.entries.where((e) => e.fingerprint == s.peerFingerprint).toList();
        if (registered.length != 1) throw StateError('identity revoked');
        // Full handshake bytes were not persisted; client signs a digest and
        // both parties bind the digest to the server-generated session ID.
        final msg = utf8.encode(jsonEncode([secureFileVersion, 'initiator', id, transcript]));
        final proof = Signature(_bytes(body['sig'], 64), publicKey: registered.single.card.key);
        if (!await Ed25519().verify(msg, signature: proof)) throw StateError('bad confirmation');
        s.confirmed = true;
        s.touch();
        final reply = await _seal(s, 'b-to-a', 'confirm', 0, utf8.encode('confirmed'));
        await _reply(req, 200, reply);
        return;
      }
      // DEV13D2E17-B1: encrypt *both* the capability request and its ACK.
      // A 404/403 from an older client is a feature refusal, never a reason
      // to fall back to the legacy HTTP file transport.
      if (req.uri.path == '/v1/text-capabilities' ||
          req.uri.path == '/v1/text') {
        final id = req.headers.value('x-linyue-session');
        final seq = int.tryParse(req.headers.value('x-linyue-seq') ?? '');
        final session = _incomingSessions[id];
        if (session == null || !session.confirmed || session.expired ||
            session.remoteIp != ip ||
            !identity.entries.any((e) => e.fingerprint == session.peerFingerprint) ||
            seq == null || seq != session.incomingSequence + 1) {
          throw StateError('untrusted text session or replayed sequence');
        }
        if (onVerifiedTextMessage == null) {
          throw StateError('text message handler not installed');
        }
        final capabilityRoute = req.uri.path == '/v1/text-capabilities';
        if (!capabilityRoute && !session.textCapabilityConfirmed) {
          throw StateError('text capability not negotiated');
        }
        final kind = capabilityRoute ? 'text-capabilities' : 'text';
        final sealed = await _read(req, capabilityRoute ? 512 :
          ConversationTextProtocol.maxFrameBytes + 28);
        final plaintext = await _open(session, 'a-to-b', kind, seq, sealed);
        session.incomingSequence = seq;
        session.touch();
        if (capabilityRoute) {
          if (utf8.decode(plaintext, allowMalformed: false) != secureTextCapability) {
            throw StateError('unsupported text capability');
          }
          session.textCapabilityConfirmed = true;
          final response = await _seal(session, 'b-to-a', 'text-capabilities-ack',
              seq, utf8.encode(secureTextCapability));
          await _reply(req, 200, response);
          return;
        }
        final message = ConversationTextProtocol.decode(
            Uint8List.fromList(plaintext));
        final key = '${session.peerFingerprint}:${message.id}';
        if (_processingTextIds.contains(key)) {
          // Do not issue a false ACK for an in-flight message.
          throw StateError('text message is still processing');
        }
        var duplicate = _ackedTextIds.contains(key);
        if (!duplicate) {
          _processingTextIds.add(key);
          try {
            final consumed = await onVerifiedTextMessage!(
                message, session.peerFingerprint);
            if (!consumed) throw StateError('text not accepted by local handler');
            _ackedTextIds.add(key);
            while (_ackedTextIds.length > _maxAckedTextIds) {
              _ackedTextIds.remove(_ackedTextIds.first);
            }
          } finally {
            _processingTextIds.remove(key);
          }
        }
        final response = await _seal(session, 'b-to-a', 'text-ack', seq,
            utf8.encode(jsonEncode({'id': message.id, 'duplicate': duplicate})));
        await _reply(req, 200, response);
        return;
      }
      if (req.uri.path == '/v1/resume-upload') {
        final id = req.headers.value('x-linyue-session');
        final seq = int.tryParse(req.headers.value('x-linyue-seq') ?? '');
        final token = req.headers.value('x-linyue-offer');
        final s = _incomingSessions[id];
        if (s == null || !s.confirmed || s.remoteIp != ip || s.expired ||
            !identity.entries.any((e) => e.fingerprint == s.peerFingerprint)) {
          throw StateError('untrusted resumable session');
        }
        if (seq == null || seq != s.incomingSequence + 1) {
          throw StateError('invalid resume sequence');
        }
        final entry = token == null ? null : _offers[token];
        if (token == null || entry == null || entry.resumeId == null ||
            entry.sessionId != s.id || entry.senderIp != ip ||
            DateTime.now().isAfter(entry.expiry)) {
          throw StateError('resume upload not authorized');
        }
        if (_writingFile) throw StateError('receiver busy');
        final store = ResumeCheckpointStore(targetDirectory);
        final linearStore = LinearResumeCheckpointStore(targetDirectory);
        // Format was selected during this session's authenticated offer;
        // never switch format based on untrusted HTTP upload headers.
        final usesV2 = entry.checkpointFormat == ResumeCheckpointFormat.linearV2;
        if (await ResumeFormatRouter(targetDirectory).choose(entry.resumeId!) !=
            entry.checkpointFormat) {
          throw StateError('resume checkpoint format changed after authorization');
        }
        final pointV1 = usesV2 ? null : await store.inspect(id: entry.resumeId!,
          expectedPeer: s.peerFingerprint, expectedSha256: entry.hash,
          expectedSize: entry.size);
        final pointV2 = !usesV2 ? null : await linearStore.inspect(id: entry.resumeId!,
          expectedPeer: s.peerFingerprint, expectedSha256: entry.hash,
          expectedSize: entry.size);
        final committed = usesV2 ? pointV2!.record.committed : pointV1!.checkpoint.committedBytes;
        if (committed >= entry.size) {
          throw StateError('resume checkpoint already complete');
        }
        _offers.remove(token); // one-time authorization
        s.incomingSequence = seq;
        s.touch();
        _writingFile = true;
        final start = committed;
        final clock = Stopwatch()..start();
        try {
          if (receiveDiskGuard != null) {
            await receiveDiskGuard!.requireRoom(destinationPath: targetDirectory.path,
              fileBytes: entry.size, verifiedBytes: start);
          }
          if (usesV2) {
            await linearStore.truncateUncommitted(pointV2!);
          } else {
            await store.truncateUncommitted(pointV1!);
          }
          notifyIncoming(TransferProgressInfo(name: entry.name, direction: 'receive',
            phase: TransferProgressPhase.receiving, totalBytes: entry.size,
            transferredBytes: start, elapsed: Duration.zero));
          await ResumableChunkCodec().decodeRemaining(
            encrypted: req.timeout(const Duration(minutes: 12)),
            store: usesV2 ? null : store,
            linearStore: usesV2 ? linearStore : null,
            id: entry.resumeId!, key: s.receiveKey,
            context: _resumeContext(s, token, seq, entry.resumeId!, start),
            total: entry.size, offset: start, sha256: entry.hash,
            onBytesVerified: (amount) => notifyIncoming(TransferProgressInfo(
              name: entry.name, direction: 'receive',
              phase: TransferProgressPhase.receiving, totalBytes: entry.size,
              transferredBytes: amount, elapsed: clock.elapsed)),
          );
          notifyIncoming(TransferProgressInfo(name: entry.name, direction: 'receive',
            phase: TransferProgressPhase.saving, totalBytes: entry.size,
            transferredBytes: entry.size, elapsed: clock.elapsed));
          final dest = await _uniqueTarget(entry.name);
          // Persist the authenticated completion intent BEFORE the final
          // rename. If the response is lost, a new authenticated offer can
          // prove this is already stored without duplicating the file.
          await ResumeCompletionLedger(store,
            linearStore: usesV2 ? linearStore : null).prepare(
            id: entry.resumeId!, fingerprint: s.peerFingerprint,
            digest: entry.hash, total: entry.size,
            originalName: entry.name, savedName: dest.uri.pathSegments.last);
          await (usesV2
            ? linearStore.partFile(entry.resumeId!)
            : store.partFile(entry.resumeId!)).rename(dest.path);
          // Once finalized, receipt cleanup is best-effort only. Never let
          // stale .json cleanup turn a correctly saved file into a failure.
          try {
            if (usesV2) {
              await linearStore.discard(entry.resumeId!);
            } else {
              await store.discard(entry.resumeId!);
            }
          } catch (_) {}
          final savedName = _resumeNameFile(store, entry.resumeId!);
          try { if (await savedName.exists()) await savedName.delete(); } catch (_) {}
          try { onReceived?.call(dest); } catch (_) {}
          try { onVerifiedReceived?.call(dest, s.peerFingerprint); } catch (_) {}
          final ack = await _seal(s, 'b-to-a', 'resume-upload-ack', seq,
            utf8.encode(jsonEncode({'size': entry.size, 'hash': entry.hash,
              'mode': secureResumeMode, 'resumeId': entry.resumeId})));
          await _reply(req, 200, ack);
          notifyIncoming(TransferProgressInfo(name: entry.name, direction: 'receive',
            phase: TransferProgressPhase.completed, totalBytes: entry.size,
            transferredBytes: entry.size, elapsed: clock.elapsed));
        } finally {
          _writingFile = false;
          // Never delete the incomplete .part or checkpoint on a network error.
        }
        return;
      }
      if (req.uri.path == '/v1/stream-upload') {
        // DEV10-B2 independent large-file route. Never buffers the HTTP body.
        final id = req.headers.value('x-linyue-session');
        final sequence = int.tryParse(req.headers.value('x-linyue-seq') ?? '');
        final token = req.headers.value('x-linyue-offer');
        final s = _incomingSessions[id];
        if (s == null || !s.confirmed || s.remoteIp != ip || s.expired ||
            !identity.entries.any((e) => e.fingerprint == s.peerFingerprint)) {
          throw StateError('untrusted secure-stream session');
        }
        if (sequence == null || sequence != s.incomingSequence + 1) {
          throw StateError('stream sequence mismatch / replay');
        }
        final accepted = token == null ? null : _offers[token];
        if (token == null || accepted == null || !accepted.streamMode || accepted.resumeId != null || accepted.sessionId != s.id ||
            accepted.senderIp != ip || DateTime.now().isAfter(accepted.expiry) ||
            accepted.size <= secureFileMaxBytes || accepted.size > secureLegacyStreamMaxBytes) {
          throw StateError('stream offer not authorized');
        }
        if (_writingFile) throw StateError('another secure upload is writing');
        // The token is consumed exactly once. A partial upload requires a new
        // signed session and a new explicit receiver approval.
        _offers.remove(token);
        s.incomingSequence = sequence;
        s.touch();
        _writingFile = true;
        final clock = Stopwatch()..start();
        final part = File('${targetDirectory.path}${Platform.pathSeparator}'
            '.linyue_part_${_hex(12)}');
        try {
          await targetDirectory.create(recursive: true);
          if (receiveDiskGuard != null) {
            await receiveDiskGuard!.requireRoom(destinationPath: targetDirectory.path,
              fileBytes: accepted.size);
          }
          notifyIncoming(TransferProgressInfo(name: accepted.name,
            direction: 'receive', phase: TransferProgressPhase.receiving,
            totalBytes: accepted.size, transferredBytes: 0, elapsed: Duration.zero));
          final result = await SecureChunkStream().decodeToTemporaryFile(
            encrypted: req.timeout(const Duration(minutes: 12)),
            temporary: part, key: s.receiveKey,
            context: _streamContext(s, token, sequence),
            expectedSize: accepted.size, expectedSha256: accepted.hash,
            onBytesWritten: (bytes) => notifyIncoming(TransferProgressInfo(
              name: accepted.name, direction: 'receive',
              phase: TransferProgressPhase.receiving,
              totalBytes: accepted.size, transferredBytes: bytes,
              elapsed: clock.elapsed)),
          );
          notifyIncoming(TransferProgressInfo(name: accepted.name,
            direction: 'receive', phase: TransferProgressPhase.saving,
            totalBytes: accepted.size, transferredBytes: result.bytes,
            elapsed: clock.elapsed));
          final destination = await _uniqueTarget(accepted.name);
          await part.rename(destination.path);
          try { onReceived?.call(destination); } catch (_) {}
          try { onVerifiedReceived?.call(destination, s.peerFingerprint); } catch (_) {}
          final reply = await _seal(s, 'b-to-a', 'stream-upload-ack', sequence,
            utf8.encode(jsonEncode({'size': result.bytes, 'hash': result.sha256,
              'mode': secureStreamMode})));
          await _reply(req, 200, reply);
          notifyIncoming(TransferProgressInfo(name: accepted.name,
            direction: 'receive', phase: TransferProgressPhase.completed,
            totalBytes: accepted.size, transferredBytes: result.bytes,
            elapsed: clock.elapsed));
          return;
        } finally {
          _writingFile = false;
          try { if (await part.exists()) await part.delete(); } catch (_) {}
        }
      }
      if (req.uri.path == '/v1/offer' || req.uri.path == '/v1/upload') {
        final id = req.headers.value('x-linyue-session');
        final sequence = int.tryParse(req.headers.value('x-linyue-seq') ?? '');
        final s = _incomingSessions[id];
        if (s == null || !s.confirmed || s.remoteIp != ip || s.expired ||
            !identity.entries.any((e) => e.fingerprint == s.peerFingerprint)) {
          throw StateError('untrusted session');
        }
        if (sequence == null || sequence != s.incomingSequence + 1) {
          throw StateError('out of order / replay');
        }
        final offerRequest = req.uri.path == '/v1/offer';
        final kind = offerRequest ? 'offer' : 'upload';
        // Observe bytes actually received on the socket.  The first 28 bytes
        // are the AES-GCM nonce+tag, not plaintext file data.
        final offered = offerRequest ? null : _offers[req.headers.value('x-linyue-offer')];
        final validOffered = offered != null && offered.sessionId == s.id &&
            offered.senderIp == ip && !DateTime.now().isAfter(offered.expiry);
        final incomingClock = Stopwatch();
        if (!offerRequest && offered != null && validOffered) {
          incomingClock.start();
          notifyIncoming(TransferProgressInfo(name: offered.name,
            direction: 'receive', phase: TransferProgressPhase.receiving,
            totalBytes: offered.size, transferredBytes: 0,
            elapsed: Duration.zero));
        }
        final data = await _read(req, offerRequest ? 8192 : secureFileMaxBytes + 28,
          onBytes: !offerRequest && offered != null && validOffered ? (length) {
            notifyIncoming(TransferProgressInfo(name: offered.name,
              direction: 'receive', phase: TransferProgressPhase.receiving,
              totalBytes: offered.size,
              transferredBytes: (length - 28).clamp(0, offered.size).toInt(),
              elapsed: incomingClock.elapsed));
          } : null);
        if (!offerRequest && offered != null && validOffered) {
          notifyIncoming(TransferProgressInfo(name: offered.name,
            direction: 'receive', phase: TransferProgressPhase.verifying,
            totalBytes: offered.size, transferredBytes: offered.size,
            elapsed: incomingClock.elapsed));
        }
        final plain = await _open(s, 'a-to-b', kind, sequence, data);
        s.incomingSequence = sequence;
        s.touch();
        if (offerRequest) {
          final meta = jsonDecode(utf8.decode(plain));
          if (meta is! Map<String, dynamic> || meta['size'] is! int ||
              meta['name'] is! String || meta['hash'] is! String) throw const FormatException('bad metadata');
          final size = meta['size'] as int;
          final hash = meta['hash'] as String;
          final resumeMode = meta['mode'] == secureResumeMode;
          final streamMode = meta['mode'] == secureStreamMode || resumeMode;
          final resumeId = resumeMode ? meta['resumeId'] : null;
          if (resumeMode && (resumeId is! String ||
              !RegExp(r'^[0-9a-f]{32}$').hasMatch(resumeId))) {
            throw const FormatException('invalid resume task identifier');
          }
          if (meta.containsKey('mode') && !streamMode) {
            throw StateError('unsupported transfer mode');
          }
          if (size < 0 || size > (resumeMode ? secureStreamPilotMaxBytes :
                  streamMode ? secureLegacyStreamMaxBytes : secureFileMaxBytes) ||
              (streamMode && size <= secureFileMaxBytes) ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
              (meta['name'] as String).length > 180) throw StateError('bad size/hash/name');
          final name = _filename(meta['name'] as String);
          final peer = identity.entries.singleWhere((e) => e.fingerprint == s.peerFingerprint);
          final store = ResumeCheckpointStore(targetDirectory);
          var approvedBefore = false;
          var restartAt = 0;
          var checkpointFormat = ResumeCheckpointFormat.legacyV1;
          if (resumeMode) {
            // A prior upload may have fully completed while its encrypted
            // success ACK was lost. Reconcile only after this fresh session
            // has authenticated the registered peer and offer metadata.
            if (_writingFile) throw StateError('receiver is busy');
            final completed = await ResumeCompletionLedger(store,
              linearStore: LinearResumeCheckpointStore(targetDirectory)).reconcile(
              id: resumeId as String, fingerprint: s.peerFingerprint,
              digest: hash, total: size, originalName: name);
            if (completed != null) {
              final done = await _seal(s, 'b-to-a', 'offer-ack', sequence,
                utf8.encode(jsonEncode({'mode': secureResumeMode,
                  'resumeId': resumeId, 'completed': true,
                  'size': size, 'hash': hash})));
              await _reply(req, 200, done);
              return;
            }
            checkpointFormat = await ResumeFormatRouter(targetDirectory).choose(resumeId);
            // Old V1 resumable tasks are never silently extended to 1 GiB.
            if (checkpointFormat == ResumeCheckpointFormat.legacyV1 &&
                size > resumeCheckpointMaxBytes) {
              throw StateError('legacy V1 task cannot exceed 512 MiB');
            }
            final linearStore = LinearResumeCheckpointStore(targetDirectory);
            final v1Exists = await store.partFile(resumeId).exists();
            final v2Exists = await linearStore.partFile(resumeId).exists();
            final resumeExists = v1Exists || v2Exists;
            if (resumeExists) {
              // Journal must prove the EXACT authenticated peer, SHA-256 and size.
              if (checkpointFormat == ResumeCheckpointFormat.legacyV1) {
                final point = await store.inspect(id: resumeId,
                  expectedPeer: s.peerFingerprint, expectedSha256: hash,
                  expectedSize: size);
                restartAt = point.checkpoint.committedBytes;
              } else {
                final point = await linearStore.inspect(id: resumeId,
                  expectedPeer: s.peerFingerprint, expectedSha256: hash,
                  expectedSize: size);
                restartAt = point.record.committed;
              }
              final nameFile = _resumeNameFile(store, resumeId);
              if (!await nameFile.exists() ||
                  await nameFile.readAsString() != name) {
                throw StateError('previously approved filename differs or consent record missing');
              }
              approvedBefore = true;
            } else {
              // Journal slots without a part indicate damage; NEVER create anew.
              if (checkpointFormat == ResumeCheckpointFormat.legacyV1) {
                throw StateError('legacy checkpoint files are incomplete');
              }
              final v2a = File('${targetDirectory.path}${Platform.pathSeparator}.linyue_resume_v2_$resumeId.a.json');
              final v2b = File('${targetDirectory.path}${Platform.pathSeparator}.linyue_resume_v2_$resumeId.b.json');
              if (await v2a.exists() || await v2b.exists()) {
                throw StateError('V2 checkpoint files are incomplete');
              }
            }
          }
          if (receiveDiskGuard != null) {
            await targetDirectory.create(recursive: true);
            await receiveDiskGuard!.requireRoom(destinationPath: targetDirectory.path,
              fileBytes: size, verifiedBytes: restartAt);
          }
          if (!approvedBefore) {
            final accepted = await (askReceiver?.call(SecureIncomingOffer(
              fileName: name, size: size, peerName: peer.name,
              fingerprint: s.peerFingerprint, remoteIp: ip)) ?? Future.value(false))
              .timeout(const Duration(seconds: 65), onTimeout: () => false);
            if (!accepted) throw StateError('user refused');
            if (resumeMode) {
              if (checkpointFormat == ResumeCheckpointFormat.legacyV1) {
                await store.create(id: resumeId as String,
                  peerFingerprint: s.peerFingerprint, fileSha256: hash,
                  totalBytes: size);
              } else {
                await LinearResumeCheckpointStore(targetDirectory).create(id: resumeId as String,
                  peerFingerprint: s.peerFingerprint, fileSha256: hash,
                  totalBytes: size);
              }
              await _resumeNameFile(store, resumeId).writeAsString(name, flush: true);
            }
          }
          final token = _hex(24);
          _offers[token] = _AcceptedFile(sessionId: s.id, senderIp: ip,
            name: name, size: size, hash: hash, streamMode: streamMode,
            resumeId: resumeMode ? resumeId as String : null,
            checkpointFormat: checkpointFormat);
          final response = await _seal(s, 'b-to-a', 'offer-ack', sequence,
            utf8.encode(jsonEncode({'token': token,
              if (streamMode) 'mode': resumeMode ? secureResumeMode : secureStreamMode,
              if (resumeMode) 'offset': restartAt})));
          await _reply(req, 200, response);
          return;
        }
        final token = req.headers.value('x-linyue-offer');
        final accepted = token == null ? null : _offers.remove(token);
        if (accepted == null || accepted.streamMode || accepted.sessionId != s.id ||
            accepted.senderIp != ip || DateTime.now().isAfter(accepted.expiry) ||
            accepted.size != plain.length ||
            hashes.sha256.convert(plain).toString() != accepted.hash) {
          throw StateError('upload rejected');
        }
        if (_writingFile) throw StateError('another upload is being finalized');
        if (trackedIncoming != null) notifyIncoming(TransferProgressInfo(
          name: accepted.name, direction: 'receive',
          phase: TransferProgressPhase.saving,
          totalBytes: accepted.size, transferredBytes: accepted.size,
          elapsed: incomingClock.elapsed));
        await targetDirectory.create(recursive: true);
        if (receiveDiskGuard != null) {
          await receiveDiskGuard!.requireRoom(destinationPath: targetDirectory.path,
            fileBytes: accepted.size);
        }
        final destination = await _uniqueTarget(accepted.name);
        _writingFile = true;
        final part = File('${destination.path}.part.${_hex(4)}');
        try {
          await part.writeAsBytes(plain, flush: true);
          await part.rename(destination.path);
        } catch (_) {
          if (await part.exists()) await part.delete();
          _writingFile = false;
          rethrow;
        }
        // UI callback must never corrupt a successful on-disk transfer.
        try { onReceived?.call(destination); } catch (_) {}
        try { onVerifiedReceived?.call(destination, s.peerFingerprint); } catch (_) {}
        _writingFile = false;
        if (trackedIncoming != null) notifyIncoming(TransferProgressInfo(
          name: accepted.name, direction: 'receive',
          phase: TransferProgressPhase.completed,
          totalBytes: accepted.size, transferredBytes: accepted.size,
          elapsed: incomingClock.elapsed));
        final response = await _seal(s, 'b-to-a', 'upload-ack', sequence,
          utf8.encode(jsonEncode({'size': accepted.size, 'hash': accepted.hash})));
        await _reply(req, 200, response);
        return;
      }
      await _reply(req, 404, {'error': 'route'});
    } catch (e) {
      if (e is DiskCapacityException) {
        try { onStorageWarning?.call(e.message.toString()); } catch (_) {}
      }
      if (trackedIncoming != null &&
          trackedIncoming!.phase != TransferProgressPhase.completed) {
        notifyIncoming(TransferProgressInfo(name: trackedIncoming!.name,
          direction: 'receive', phase: TransferProgressPhase.failed,
          totalBytes: trackedIncoming!.totalBytes,
          transferredBytes: trackedIncoming!.transferredBytes,
          elapsed: trackedIncoming!.elapsed));
      }
      try { await _reply(req, 403, {'error': 'authentication or transfer rejected'}); }
      catch (_) { try { await req.response.close(); } catch (_) {} }
    }
  }

  Future<File> _uniqueTarget(String filename) async {
    final name = _filename(filename);
    var dest = File('${targetDirectory.path}${Platform.pathSeparator}$name');
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var counter = 1;
    while (await dest.exists()) {
      dest = File('${targetDirectory.path}${Platform.pathSeparator}${stem}_$counter$ext');
      counter++;
    }
    return dest;
  }

  Future<Map<String, dynamic>> _postJson(Uri uri, Map<String, dynamic> body) async {
    final request = await _client.postUrl(uri).timeout(const Duration(seconds: 7));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 12));
    final bytes = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) throw StateError('trusted endpoint did not respond');
    final json = jsonDecode(bytes);
    if (json is! Map<String, dynamic> || json['v'] != secureFileVersion) {
      throw StateError('secure handshake protocol mismatch');
    }
    return json;
  }

  Future<_Session> _connect(String ip, int port, String expectedFingerprint) async {
    final card = identity.local.card;
    final myEphemeral = await X25519().newKeyPair();
    final ea = await myEphemeral.extractPublicKey();
    final na = _encode(secureRandomBytes(16));
    final encodedEa = _encode(ea.bytes);
    final hello = utf8.encode(jsonEncode([secureFileVersion, 'hello', card, encodedEa, na]));
    final proof = await identity.local.sign(hello);
    final base = Uri(scheme: 'http', host: ip, port: port);
    final reply = await _postJson(base.replace(path: '/v1/hello'), {
      'v': secureFileVersion, 'card': card, 'e': encodedEa, 'n': na, 'sig': _encode(proof.bytes),
    });
    final remoteCard = PublicIdentityCard.parse(reply['card'] as String);
    if (remoteCard.fingerprint != expectedFingerprint || !_trusted(remoteCard)) {
      throw StateError('remote identity mismatch or not paired');
    }
    final eb = SimplePublicKey(_bytes(reply['e'], 32), type: KeyPairType.x25519);
    final hand = _Handshake(id: reply['id'] as String,
      aCard: card, bCard: remoteCard.encoded, aEphemeral: encodedEa,
      bEphemeral: _encode(eb.bytes), aNonce: na,
      bNonce: _encode(_bytes(reply['n'], 16)));
    final signed = Signature(_bytes(reply['sig'], 64), publicKey: remoteCard.key);
    if (!await Ed25519().verify(hand.message('responder'), signature: signed)) {
      throw StateError('responder signature mismatch');
    }
    final s = await _sessionFor(hand, myEphemeral, eb, ip, false);
    final msg = utf8.encode(jsonEncode([
      secureFileVersion, 'initiator', hand.id, _encode(hand.hash),
    ]));
    final sig = await identity.local.sign(msg);
    final request = await _client.postUrl(base.replace(path: '/v1/confirm'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'v': secureFileVersion, 'id': hand.id,
      'transcript': _encode(hand.hash), 'sig': _encode(sig.bytes)}));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > 1000) throw const FormatException('oversize ack');
      bytes.addAll(chunk);
    }
    if (response.statusCode != 200 ||
        utf8.decode(await _open(s, 'b-to-a', 'confirm', 0, bytes)) != 'confirmed') {
      throw StateError('secure session not confirmed');
    }
    s.confirmed = true;
    _handshakes++;
    return s;
  }

  /// E17-B1 encrypted chat API. No UI, persistent history or retransmission
  /// guarantee yet. The receiver ACKs only after its installed callback
  /// successfully consumes the authenticated text message.
  Future<TextSendReceipt> sendText({
    required String ip,
    required int port,
    required String remoteFingerprint,
    required TextChatMessage message,
  }) async {
    message.validate();
    if (!identity.entries.any((entry) =>
        entry.fingerprint == remoteFingerprint)) {
      throw StateError('text receiver not registered');
    }
    final sessionKey = '$ip:$port:$remoteFingerprint';
    _sweep();
    var session = _outgoingSessions[sessionKey];
    if (session == null || session.expired) {
      session = await _connect(ip, port, remoteFingerprint);
      _outgoingSessions[sessionKey] = session;
    }
    if (session.busy) throw StateError('encrypted session is busy');
    session.busy = true;
    try {
      final base = Uri(scheme: 'http', host: ip, port: port);
      if (!session.textCapabilityConfirmed) {
        final capabilityAck = await _postEncrypted(
          base.replace(path: '/v1/text-capabilities'), session,
          'text-capabilities', ++session.outgoingSequence,
          utf8.encode(secureTextCapability),
        );
        if (utf8.decode(capabilityAck, allowMalformed: false) !=
            secureTextCapability) {
          throw UnsupportedError('receiver does not support encrypted text');
        }
        session.textCapabilityConfirmed = true;
      }
      final textAck = await _postEncrypted(base.replace(path: '/v1/text'),
        session, 'text', ++session.outgoingSequence,
        ConversationTextProtocol.encode(message));
      final json = jsonDecode(utf8.decode(textAck, allowMalformed: false));
      if (json is! Map<String, dynamic> || json['id'] != message.id ||
          json['duplicate'] is! bool || json.length != 2) {
        throw StateError('invalid authenticated text acknowledgement');
      }
      return TextSendReceipt(messageId: message.id,
        alreadyReceived: json['duplicate'] as bool);
    } catch (_) {
      // After an uncertain response a fresh signed session is required.
      _outgoingSessions.remove(sessionKey);
      rethrow;
    } finally {
      session.busy = false;
    }
  }

  Future<List<int>> _postEncrypted(Uri uri, _Session session, String kind,
      int seq, List<int> data, {String? offer,
        void Function(int)? onUploadBytes}) async {
    final request = await _client.postUrl(uri).timeout(const Duration(seconds: 7));
    request.headers.contentType = ContentType.binary;
    request.headers.set('x-linyue-session', session.id);
    request.headers.set('x-linyue-seq', '$seq');
    if (offer != null) request.headers.set('x-linyue-offer', offer);
    final payload = await _seal(session, 'a-to-b', kind, seq, data);
    request.contentLength = payload.length;
    if (kind == 'upload' && onUploadBytes != null) {
      // Count bytes flushed to the local socket; NOT remote acceptance.
      // Avoid claiming completion until the authenticated ACK is verified.
      const chunkSize = 64 * 1024;
      for (var offset = 0; offset < payload.length; offset += chunkSize) {
        final end = offset + chunkSize < payload.length ? offset + chunkSize : payload.length;
        request.add(payload.sublist(offset, end));
        await request.flush();
        try { onUploadBytes((end - 28).clamp(0, data.length).toInt()); } catch (_) {}
      }
    } else {
      request.add(payload);
    }
    final response = await request.close().timeout(const Duration(seconds: 120));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 120))) {
      if (bytes.length + chunk.length > 8192) throw const FormatException('oversized server ack');
      bytes.add(chunk);
    }
    if (response.statusCode != 200) throw StateError('receiver declined or encrypted transfer failed');
    session.touch();
    return _open(session, 'b-to-a', '$kind-ack', seq, bytes.takeBytes());
  }

  /// Internal DEV9A API. No plaintext fallback.
  /// The recipient must have ALREADY been registered by the DEV8 SAS pairing.
  Future<void> sendFile({required String ip, required int port,
      required String remoteFingerprint, required File file,
      void Function(TransferProgressInfo)? onProgress}) async {
    if (identity.entries.every((r) => r.fingerprint != remoteFingerprint)) {
      throw StateError('device not registered');
    }
    final size = await file.length();
    final filename = file.uri.pathSegments.last;
    final uploadClock = Stopwatch();
    void notify(TransferProgressPhase phase, [int count = 0]) {
      try { onProgress?.call(TransferProgressInfo(
        name: filename, direction: 'send', phase: phase,
        totalBytes: size, transferredBytes: count,
        elapsed: uploadClock.elapsed)); } catch (_) {}
    }
    if (size > secureFileMaxBytes) throw StateError('file too large');
    notify(TransferProgressPhase.authenticating);
    final sessionKey = '$ip:$port:$remoteFingerprint';
    _sweep();
    var session = _outgoingSessions[sessionKey];
    if (session == null || session.expired) {
      session = await _connect(ip, port, remoteFingerprint);
      _outgoingSessions[sessionKey] = session;
    }
    if (session.busy) throw StateError('session already sending');
    session.busy = true;
    try {
      notify(TransferProgressPhase.preparing);
      final content = await file.readAsBytes();
      if (content.length != size) throw StateError('file changed during transfer');
      final hash = hashes.sha256.convert(content).toString();
      final base = Uri(scheme: 'http', host: ip, port: port);
      notify(TransferProgressPhase.awaitingApproval);
      final offerSeq = ++session.outgoingSequence;
      final response = await _postEncrypted(base.replace(path: '/v1/offer'), session,
        'offer', offerSeq, utf8.encode(jsonEncode({
          'name': _filename(file.uri.pathSegments.last), 'size': size, 'hash': hash,
        })));
      final decoded = jsonDecode(utf8.decode(response));
      if (decoded is! Map<String, dynamic> || decoded['token'] is! String) {
        throw StateError('invalid offer acknowledgement');
      }
      final uploadSeq = ++session.outgoingSequence;
      uploadClock.start();
      notify(TransferProgressPhase.uploading);
      final acknowledgement = await _postEncrypted(base.replace(path: '/v1/upload'),
        session, 'upload', uploadSeq, content,
        offer: decoded['token'] as String,
        onUploadBytes: (count) => notify(TransferProgressPhase.uploading, count));
      notify(TransferProgressPhase.verifying, size);
      final result = jsonDecode(utf8.decode(acknowledgement));
      if (result is! Map<String, dynamic> || result['hash'] != hash || result['size'] != size) {
        throw StateError('encrypted receipt mismatch');
      }
      notify(TransferProgressPhase.completed, size);
    } catch (_) {
      notify(TransferProgressPhase.failed);
      // Uncertain sequence state: force a fresh signed session next time.
      _outgoingSessions.remove(sessionKey);
      rethrow;
    } finally {
      session.busy = false;
    }
  }

  /// Legacy encrypted stream: still strictly >20 MiB and <=512 MiB.
  /// The original DEV9B sendFile() stays unchanged for small transfers.
  Future<void> sendStreamFileLegacy({required String ip, required int port,
      required String remoteFingerprint, required File file,
      void Function(TransferProgressInfo)? onProgress}) async {
    if (identity.entries.every((e) => e.fingerprint != remoteFingerprint)) {
      throw StateError('device not registered');
    }
    final size = await file.length();
    if (size <= secureFileMaxBytes || size > secureLegacyStreamMaxBytes) {
      throw StateError('legacy stream file outside 20–512 MiB range');
    }
    final filename = file.uri.pathSegments.last;
    final clock = Stopwatch();
    void notify(TransferProgressPhase phase, [int sent = 0]) {
      try { onProgress?.call(TransferProgressInfo(name: filename,
        direction: 'send', phase: phase, totalBytes: size,
        transferredBytes: sent, elapsed: clock.elapsed)); } catch (_) {}
    }
    notify(TransferProgressPhase.authenticating);
    final sessionKey = '$ip:$port:$remoteFingerprint';
    _sweep();
    var session = _outgoingSessions[sessionKey];
    if (session == null || session.expired) {
      session = await _connect(ip, port, remoteFingerprint);
      _outgoingSessions[sessionKey] = session;
    }
    if (session.busy) throw StateError('session already sending');
    session.busy = true;
    try {
      notify(TransferProgressPhase.preparing);
      // Incremental digest: no file-wide readAsBytes() allocation.
      final digest = (await hashes.sha256.bind(file.openRead()).first).toString();
      if (await file.length() != size) throw StateError('file changed during preflight');
      final base = Uri(scheme: 'http', host: ip, port: port);
      notify(TransferProgressPhase.awaitingApproval);
      final offerSeq = ++session.outgoingSequence;
      final reply = await _postEncrypted(base.replace(path: '/v1/offer'), session,
        'offer', offerSeq, utf8.encode(jsonEncode({
          'name': _filename(filename), 'size': size, 'hash': digest,
          'mode': secureStreamMode,
        })));
      final data = jsonDecode(utf8.decode(reply));
      if (data is! Map<String, dynamic> || data['mode'] != secureStreamMode ||
          data['token'] is! String || (data['token'] as String).isEmpty) {
        throw StateError('receiver does not support authenticated stream mode');
      }
      final token = data['token'] as String;
      final sequence = ++session.outgoingSequence;
      final req = await _client.postUrl(base.replace(path: '/v1/stream-upload'))
        .timeout(const Duration(seconds: 7));
      req.headers.contentType = ContentType.binary;
      req.headers.set('x-linyue-session', session.id);
      req.headers.set('x-linyue-seq', '$sequence');
      req.headers.set('x-linyue-offer', token);
      clock.start();
      notify(TransferProgressPhase.uploading);
      final result = await SecureChunkStream().encodeFile(
        source: file, key: session.sendKey,
        context: _streamContext(session, token, sequence),
        expectedSize: size, expectedSha256: digest,
        writeFrame: (frame) async { req.add(frame); await req.flush(); },
        onBytesSubmitted: (count) => notify(TransferProgressPhase.uploading, count),
      );
      final response = await req.close().timeout(const Duration(minutes: 12));
      final body = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(minutes: 12))) {
        if (body.length + chunk.length > 8192) {
          throw const FormatException('oversized stream receipt');
        }
        body.add(chunk);
      }
      if (response.statusCode != 200) throw StateError('secure stream upload rejected');
      notify(TransferProgressPhase.verifying, size);
      final sealed = await _open(session, 'b-to-a', 'stream-upload-ack',
        sequence, body.takeBytes());
      final acknowledged = jsonDecode(utf8.decode(sealed));
      if (acknowledged is! Map<String, dynamic> ||
          acknowledged['mode'] != secureStreamMode ||
          acknowledged['size'] != result.bytes || acknowledged['hash'] != digest) {
        throw StateError('authenticated stream receipt mismatch');
      }
      session.touch();
      notify(TransferProgressPhase.completed, size);
    } catch (_) {
      notify(TransferProgressPhase.failed);
      _outgoingSessions.remove(sessionKey);
      rethrow;
    } finally {
      session.busy = false;
    }
  }
  /// DEV10-D2: interrupted Wi-Fi may recover in the SAME running send task.
  /// A new signed handshake + fresh X25519 keys are used on every reconnect.
  /// Never falls back to plaintext or the non-resumable encrypted protocol.
  Future<void> sendStreamFile({required String ip, required int port,
      required String remoteFingerprint, required File file,
      void Function(TransferProgressInfo)? onProgress,
      String? resumeTaskId, String? expectedSha256}) async {
    // A saved resume ID is meaningful only when bound to the original hash.
    if ((resumeTaskId == null) != (expectedSha256 == null) ||
        (resumeTaskId != null && !RegExp(r'^[a-f0-9]{32}$').hasMatch(resumeTaskId)) ||
        (expectedSha256 != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256))) {
      throw StateError('invalid stored resume identity / file digest');
    }
    if (identity.entries.every((e) => e.fingerprint != remoteFingerprint)) {
      throw StateError('device identity is not trusted');
    }
    final size = await file.length();
    if (size <= secureFileMaxBytes || size > secureStreamPilotMaxBytes) {
      throw StateError('V2 resumed transfer supports 20 MiB–1 GiB');
    }
    final digest = (await hashes.sha256.bind(file.openRead()).first).toString();
    if (expectedSha256 != null && digest != expectedSha256) {
      throw StateError('源文件与跨启动记录不一致，禁止续传');
    }
    final taskId = resumeTaskId ?? ResumeCheckpointStore.newId();
    final filename = _filename(file.uri.pathSegments.last);
    final clock = Stopwatch();
    int sent = 0;
    void notify(TransferProgressPhase phase, [int? bytes]) {
      if (bytes != null) sent = bytes;
      try { onProgress?.call(TransferProgressInfo(name: filename,
        direction: 'send', phase: phase, totalBytes: size,
        transferredBytes: sent, elapsed: clock.elapsed)); } catch (_) {}
    }
    notify(TransferProgressPhase.authenticating, 0);
    // Retry only communication failures; identity/consent/cryptographic
    // failures stop immediately, without any insecure fallback.
    const wait = <int>[0, 2, 4, 8, 15, 25, 30];
    Object? networkError;
    for (var attempt = 0; attempt < wait.length; attempt++) {
      if (attempt > 0) {
        notify(TransferProgressPhase.authenticating);
        await Future<void>.delayed(Duration(seconds: wait[attempt]));
      }
      _Session? session;
      final sessionKey = '$ip:$port:$remoteFingerprint';
      try {
        // Check file content on each attempt, not merely its length.
        if (await file.length() != size ||
            (await hashes.sha256.bind(file.openRead()).first).toString() != digest) {
          throw StateError('source file changed, cannot resume');
        }
        // NEVER reuse an encryption session after an interrupted upload.
        _outgoingSessions.remove(sessionKey);
        session = await _connect(ip, port, remoteFingerprint);
        _outgoingSessions[sessionKey] = session;
        if (session.busy) throw StateError('session busy');
        session.busy = true;
        final base = Uri(scheme: 'http', host: ip, port: port);
        notify(TransferProgressPhase.awaitingApproval);
        final offerSeq = ++session.outgoingSequence;
        final reply = await _postEncrypted(base.replace(path: '/v1/offer'),
          session, 'offer', offerSeq, utf8.encode(jsonEncode({
            'name': filename, 'size': size, 'hash': digest,
            'mode': secureResumeMode, 'resumeId': taskId,
          })));
        final ack = jsonDecode(utf8.decode(reply));
        if (ack is! Map<String, dynamic> || ack['mode'] != secureResumeMode) {
          throw StateError('receiver does not support authenticated resume');
        }
        // This response is AES-GCM authenticated in the NEW trusted session.
        // Never turn a timeout/unauthenticated HTTP response into success.
        if (ack['completed'] == true) {
          if (ack['resumeId'] != taskId || ack['size'] != size ||
              ack['hash'] != digest || ack.containsKey('token')) {
            throw StateError('invalid authenticated completed receipt');
          }
          // The receiving endpoint may expire this signed session during a
          // long transfer. Never let a following small-file send reuse it.
          _outgoingSessions.remove(sessionKey);
          notify(TransferProgressPhase.completed, size);
          return;
        }
        if (ack['completed'] != null ||
            ack['token'] is! String || ack['offset'] is! int) {
          throw StateError('invalid authenticated resume offset response');
        }
        final start = ack['offset'] as int;
        if (start < 0 || start >= size || start % resumeCheckpointChunkSize != 0) {
          throw StateError('invalid authenticated receiver offset');
        }
        final token = ack['token'] as String;
        final seq = ++session.outgoingSequence;
        final req = await _client.postUrl(base.replace(path: '/v1/resume-upload'))
          .timeout(const Duration(seconds: 7));
        req.headers.contentType = ContentType.binary;
        req.headers.set('x-linyue-session', session.id);
        req.headers.set('x-linyue-seq', '$seq');
        req.headers.set('x-linyue-offer', token);
        clock.start();
        notify(TransferProgressPhase.uploading, start);
        await ResumableChunkCodec().encodeRemaining(source: file,
          key: session.sendKey, context: _resumeContext(session, token, seq, taskId, start),
          total: size, offset: start, sha256: digest,
          writeFrame: (frame) async { req.add(frame); await req.flush(); },
          onBytesSubmitted: (bytes) => notify(TransferProgressPhase.uploading, bytes));
        final response = await req.close().timeout(const Duration(minutes: 12));
        final body = BytesBuilder(copy: false);
        await for (final piece in response.timeout(const Duration(minutes: 12))) {
          if (body.length + piece.length > 8192) throw const FormatException('oversized receipt');
          body.add(piece);
        }
        if (response.statusCode != 200) {
          throw StateError('receiver did not authorize resume / integrity failure');
        }
        notify(TransferProgressPhase.verifying, size);
        final sealed = await _open(session, 'b-to-a', 'resume-upload-ack', seq, body.takeBytes());
        final receipt = jsonDecode(utf8.decode(sealed));
        if (receipt is! Map<String, dynamic> || receipt['hash'] != digest ||
            receipt['size'] != size || receipt['resumeId'] != taskId ||
            receipt['mode'] != secureResumeMode) {
          throw StateError('invalid authenticated resume receipt');
        }
        // A prolonged transfer can outlast the receiver's 10-minute idle
        // clock even though the sender would consider this session fresh.
        // Force the next send to authenticate a NEW encrypted session.
        _outgoingSessions.remove(sessionKey);
        notify(TransferProgressPhase.completed, size);
        return;
      } catch (e) {
        networkError = e;
        _outgoingSessions.remove(sessionKey);
        // Expired or untrusted session, refused offer, and cryptographic
        // failures MUST NOT be automatically retried as network timeouts.
        if (e is! SocketException && e is! TimeoutException && e is! HttpException) {
          notify(TransferProgressPhase.failed);
          rethrow;
        }
      } finally {
        if (session != null) session.busy = false;
      }
    }
    notify(TransferProgressPhase.failed);
    throw StateError('重连超时；源文件未删除，可以重新添加发送：$networkError');
  }

}
