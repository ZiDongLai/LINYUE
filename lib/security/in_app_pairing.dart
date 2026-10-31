/// DEV8: explicit, in-app, first-time identity enrollment with a short visual
/// authentication string (SAS). The two users MUST compare their device screens.
///
/// This service creates durable device identity registrations ONLY. It does NOT
/// encrypt, authorize, or modify the legacy file HTTP transport on TCP 46729.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

import 'device_identity.dart';
import 'secure_core.dart' show secureRandomBytes;

const int inAppPairingPort = 46731;
const String inAppPairingVersion = 'linyue-inapp-pair-v1';

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> _fromB64(Object? encoded, int expected) {
  if (encoded is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
    throw const FormatException('配对字段编码无效');
  }
  final bytes = base64Url.decode(base64Url.normalize(encoded));
  if (bytes.length != expected || _b64(bytes) != encoded) {
    throw const FormatException('配对字段长度无效');
  }
  return bytes;
}

String _nonce() => _b64(secureRandomBytes(32));
String _requestId() => secureRandomBytes(16)
    .map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _safeName(Object? raw) {
  if (raw is! String) throw const FormatException('缺少设备名称');
  final name = raw.trim();
  if (name.isEmpty || name.length > 40 || RegExp(r'[\x00-\x1f]').hasMatch(name)) {
    throw const FormatException('设备名称不合法');
  }
  return name;
}

bool isPrivatePairingIp(String ip) {
  final values = ip.split('.');
  if (values.length != 4) return false;
  final nums = <int>[];
  for (final v in values) {
    if (v.isEmpty || (v.length > 1 && v.startsWith('0'))) return false;
    final n = int.tryParse(v);
    if (n == null || n < 0 || n > 255) return false;
    nums.add(n);
  }
  return nums[0] == 10 ||
      (nums[0] == 172 && nums[1] >= 16 && nums[1] <= 31) ||
      (nums[0] == 192 && nums[1] == 168) ||
      (nums[0] == 127 && nums[1] == 0 && nums[2] == 0 && nums[3] == 1);
}

/// The same transcript is independently reconstructed on both endpoints.
class PairingTranscript {
  const PairingTranscript({
    required this.id,
    required this.initiatorCard,
    required this.responderCard,
    required this.initiatorNonce,
    required this.responderNonce,
  });
  final String id;
  final String initiatorCard;
  final String responderCard;
  final String initiatorNonce;
  final String responderNonce;

  List<int> signatureBytes(String role) => utf8.encode([
        inAppPairingVersion, role, id,
        initiatorCard, responderCard, initiatorNonce, responderNonce,
      ].join('|'));

  /// A 6-digit comparison code, not a secret or a cryptographic session key.
  String get comparisonCode {
    final digest = sha256.convert(signatureBytes('visual-compare')).bytes;
    final n = (digest[0] << 24) | (digest[1] << 16) |
        (digest[2] << 8) | digest[3];
    return (n % 1000000).toString().padLeft(6, '0');
  }
}

class PairingPrompt {
  const PairingPrompt({
    required this.remoteName,
    required this.comparisonCode,
    required this.incoming,
  });
  final String remoteName;
  final String comparisonCode;
  final bool incoming;
}

class PairingResult {
  const PairingResult({required this.remoteName, required this.fingerprint,
    required this.remoteIp});
  final String remoteName;
  final String fingerprint;
  final String remoteIp;
}

class _PendingPair {
  _PendingPair(this.transcript, this.sourceIp, this.remoteName)
      : expires = DateTime.now().add(const Duration(seconds: 75));
  final PairingTranscript transcript;
  final String sourceIp;
  final String remoteName;
  final DateTime expires;
  final Completer<bool> approved = Completer<bool>();
}

/// Callable only after [DeviceIdentityManager.initialize].
class InAppPairingService {
  InAppPairingService(this.identity, {required this.deviceName});

  final DeviceIdentityManager identity;
  final String deviceName;
  HttpServer? _server;
  final Map<String, _PendingPair> _pending = {};
  final Map<String, List<DateTime>> _rate = {};

  Future<bool> Function(PairingPrompt request)? onIncomingRequest;
  void Function(PairingResult result)? onPaired;
  bool get running => _server != null;
  int? get boundPort => _server?.port;

  Future<void> start({InternetAddress? address, int port = inAppPairingPort}) async {
    if (_server != null) return;
    identity.local;
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _server!.listen((req) => unawaited(_handle(req)));
  }

  Future<void> stop() async {
    final previous = _server;
    _server = null;
    for (final value in _pending.values) {
      if (!value.approved.isCompleted) value.approved.complete(false);
    }
    _pending.clear();
    _rate.clear();
    await previous?.close(force: true);
  }

  bool _registered(PublicIdentityCard card) =>
      identity.entries.any((entry) => entry.fingerprint == card.fingerprint);

  Future<void> _saveRegistration(PublicIdentityCard card, String name) async {
    if (_registered(card)) return;
    // The completed signed protocol + independently compared visual code is
    // the human verification. This field is NOT trust inferred from LAN/IP.
    await identity.register(
      displayName: name,
      identityCard: card.encoded,
      independentlyCheckedFingerprint: card.fingerprint,
    );
  }

  Future<Map<String, dynamic>> _read(HttpRequest request) async {
    final bytes = <int>[];
    await for (final part in request.timeout(const Duration(seconds: 7))) {
      if (bytes.length + part.length > 2500) {
        throw const FormatException('配对请求过大');
      }
      bytes.addAll(part);
    }
    final object = jsonDecode(utf8.decode(bytes));
    if (object is! Map<String, dynamic> || object['version'] != inAppPairingVersion) {
      throw const FormatException('配对协议版本不符');
    }
    return object;
  }

  Future<void> _respond(HttpRequest req, int status, Map<String, dynamic> data) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    await req.response.close();
  }

  bool _rateAllowed(String ip) {
    final now = DateTime.now();
    final attempts = _rate.putIfAbsent(ip, () => <DateTime>[]);
    attempts.removeWhere((at) => now.difference(at) > const Duration(minutes: 1));
    if (attempts.length >= 5) return false;
    attempts.add(now);
    return true;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method != 'POST') {
        await _respond(req, HttpStatus.methodNotAllowed, {'error': 'method'});
        return;
      }
      final sourceIp = req.connectionInfo?.remoteAddress.address;
      if (sourceIp == null || !isPrivatePairingIp(sourceIp)) {
        throw StateError('不允许该网络来源');
      }
      final body = await _read(req);
      if (req.uri.path == '/resume') {
        // No user-facing dialog for identities previously compared and saved
        // on BOTH endpoints. This is an identity proof, not file encryption.
        if (!_rateAllowed(sourceIp)) throw StateError('重新认证过于频繁');
        final remote = PublicIdentityCard.parse(body['card'] as String);
        if (!_registered(remote)) throw StateError('尚未登记此设备');
        final nonce = _b64(_fromB64(body['nonce'], 32));
        final signed = Signature(
          _fromB64(body['proof'], 64), publicKey: remote.key);
        if (!await Ed25519().verify(
          utf8.encode('$inAppPairingVersion|resume-client|${remote.encoded}|$nonce'),
          signature: signed,
        )) {
          throw StateError('已登记设备无法证明私钥');
        }
        final serverNonce = _nonce();
        final proof = await identity.local.sign(utf8.encode([
          inAppPairingVersion, 'resume-responder',
          remote.encoded, identity.local.card, nonce, serverNonce,
        ].join('|')));
        await _respond(req, HttpStatus.ok, {
          'version': inAppPairingVersion,
          'status': 'identity-proof-only',
          'card': identity.local.card,
          'nonce': serverNonce,
          'proof': _b64(proof.bytes),
        });
        return;
      }
      if (req.uri.path == '/offer') {
        _pending.removeWhere((_, p) => DateTime.now().isAfter(p.expires));
        if (_pending.isNotEmpty || !_rateAllowed(sourceIp)) {
          throw StateError('当前有配对正在进行或请求过于频繁');
        }
        final remote = PublicIdentityCard.parse(body['card'] as String);
        if (remote.fingerprint == identity.local.fingerprint) {
          throw StateError('不能与本机配对');
        }
        final remoteName = _safeName(body['name']);
        final nonceA = _b64(_fromB64(body['nonce'], 32));
        final offerSig = Signature(
          _fromB64(body['proof'], 64), publicKey: remote.key);
        if (!await Ed25519().verify(
          utf8.encode('$inAppPairingVersion|offer|${remote.encoded}|$nonceA'),
          signature: offerSig,
        )) {
          throw StateError('对方身份签名不正确');
        }
        final transcript = PairingTranscript(
          id: _requestId(),
          initiatorCard: remote.encoded,
          responderCard: identity.local.card,
          initiatorNonce: nonceA,
          responderNonce: _nonce(),
        );
        final pending = _PendingPair(transcript, sourceIp, remoteName);
        _pending[transcript.id] = pending;
        final sig = await identity.local.sign(transcript.signatureBytes('responder-offer'));
        await _respond(req, HttpStatus.ok, {
          'version': inAppPairingVersion,
          'id': transcript.id,
          'card': identity.local.card,
          'nonce': transcript.responderNonce,
          'proof': _b64(sig.bytes),
        });
        // The incoming request gets an on-screen dialog, never auto-approved.
        unawaited(_askIncoming(pending));
        return;
      }
      if (req.uri.path == '/finish') {
        final id = body['id'];
        if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
          throw const FormatException('无效会话 ID');
        }
        final pending = _pending.remove(id);
        if (pending == null || pending.sourceIp != sourceIp ||
            DateTime.now().isAfter(pending.expires)) {
          throw StateError('配对超时或重复确认');
        }
        final initiator = PublicIdentityCard.parse(pending.transcript.initiatorCard);
        final signed = Signature(_fromB64(body['proof'], 64), publicKey: initiator.key);
        if (!await Ed25519().verify(
          pending.transcript.signatureBytes('initiator-confirm'), signature: signed,
        )) {
          throw StateError('请求方无法证明设备身份');
        }
        final accepted = await pending.approved.future.timeout(
          const Duration(seconds: 65), onTimeout: () => false);
        if (!accepted) throw StateError('接收方未同意配对');
        await _saveRegistration(initiator, pending.remoteName);
        final finalSig = await identity.local.sign(
          pending.transcript.signatureBytes('responder-confirm'));
        await _respond(req, HttpStatus.ok, {
          'version': inAppPairingVersion,
          'status': 'registered-only',
          'proof': _b64(finalSig.bytes),
        });
        onPaired?.call(PairingResult(
          remoteName: pending.remoteName,
          fingerprint: initiator.fingerprint, remoteIp: sourceIp));
        return;
      }
      await _respond(req, HttpStatus.notFound, {'error': 'route'});
    } catch (_) {
      try {
        await _respond(req, HttpStatus.forbidden, {'error': 'pairing rejected'});
      } catch (_) {
        try { await req.response.close(); } catch (_) {}
      }
    }
  }

  Future<void> _askIncoming(_PendingPair pending) async {
    bool ok = false;
    try {
      final handler = onIncomingRequest;
      if (handler != null) {
        ok = await handler(PairingPrompt(
          remoteName: pending.remoteName,
          comparisonCode: pending.transcript.comparisonCode,
          incoming: true,
        )).timeout(const Duration(seconds: 65), onTimeout: () => false);
      }
    } catch (_) {
      ok = false;
    }
    if (!pending.approved.isCompleted) pending.approved.complete(ok);
  }

  Future<Map<String, dynamic>> _post(
      HttpClient client, Uri uri, Map<String, dynamic> data) async {
    final req = await client.postUrl(uri).timeout(const Duration(seconds: 7));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(data));
    final response = await req.close().timeout(const Duration(seconds: 70));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 70))) {
      if (bytes.length + chunk.length > 2500) throw const FormatException('配对响应过大');
      bytes.addAll(chunk);
    }
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('对方未确认或网络配对服务不可达');
    }
    final obj = jsonDecode(utf8.decode(bytes));
    if (obj is! Map<String, dynamic> || obj['version'] != inAppPairingVersion) {
      throw const FormatException('配对响应格式错误');
    }
    return obj;
  }

  /// Returns null for an unknown/unavailable device. Never claim a trusted
  /// identity merely because an IP/name was seen in UDP discovery.
  Future<PairingResult?> tryResume({
    required String remoteIp,
    int port = inAppPairingPort,
  }) async {
    if (!isPrivatePairingIp(remoteIp) || !running || identity.entries.isEmpty) {
      return null;
    }
    final nonce = _nonce();
    final sig = await identity.local.sign(
      utf8.encode('$inAppPairingVersion|resume-client|${identity.local.card}|$nonce'));
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri(scheme: 'http', host: remoteIp, port: port, path: '/resume');
      final res = await _post(client, uri, {
        'version': inAppPairingVersion,
        'card': identity.local.card,
        'nonce': nonce,
        'proof': _b64(sig.bytes),
      }).timeout(const Duration(seconds: 8));
      if (res['status'] != 'identity-proof-only') return null;
      final card = PublicIdentityCard.parse(res['card'] as String);
      final match = identity.entries.where((e) => e.fingerprint == card.fingerprint).toList();
      if (match.length != 1) return null;
      final serverNonce = _b64(_fromB64(res['nonce'], 32));
      final signature = Signature(_fromB64(res['proof'], 64), publicKey: card.key);
      final correct = await Ed25519().verify(utf8.encode([
        inAppPairingVersion, 'resume-responder',
        identity.local.card, card.encoded, nonce, serverNonce,
      ].join('|')), signature: signature);
      if (!correct) return null;
      final result = PairingResult(
        remoteName: match.single.name, fingerprint: card.fingerprint,
        remoteIp: remoteIp);
      onPaired?.call(result);
      return result;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<PairingResult> initiate({
    required String remoteIp,
    required String remoteName,
    required Future<bool> Function(PairingPrompt) confirm,
    int port = inAppPairingPort,
  }) async {
    if (!isPrivatePairingIp(remoteIp)) throw const FormatException('仅支持可信局域网 IPv4');
    if (!running) throw StateError('本机配对服务尚未准备好');
    final name = _safeName(remoteName);
    final nonceA = _nonce();
    final sig = await identity.local.sign(
      utf8.encode('$inAppPairingVersion|offer|${identity.local.card}|$nonceA'));
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    try {
      final uri = Uri(scheme: 'http', host: remoteIp, port: port);
      final offer = await _post(client, uri.replace(path: '/offer'), {
        'version': inAppPairingVersion,
        'name': deviceName,
        'card': identity.local.card,
        'nonce': nonceA,
        'proof': _b64(sig.bytes),
      });
      final id = offer['id'];
      if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
        throw StateError('配对会话 ID 错误');
      }
      final responder = PublicIdentityCard.parse(offer['card'] as String);
      if (responder.fingerprint == identity.local.fingerprint) {
        throw StateError('远端错误地使用本机身份');
      }
      final transcript = PairingTranscript(
        id: id,
        initiatorCard: identity.local.card,
        responderCard: responder.encoded,
        initiatorNonce: nonceA,
        responderNonce: _b64(_fromB64(offer['nonce'], 32)),
      );
      final proof = Signature(
        _fromB64(offer['proof'], 64), publicKey: responder.key);
      if (!await Ed25519().verify(
        transcript.signatureBytes('responder-offer'), signature: proof,
      )) {
        throw StateError('对方无法证明持有身份密钥');
      }
      final accepted = await confirm(PairingPrompt(
        remoteName: name,
        comparisonCode: transcript.comparisonCode,
        incoming: false,
      )).timeout(const Duration(seconds: 65), onTimeout: () => false);
      if (!accepted) throw StateError('你已取消配对');
      final myProof = await identity.local.sign(
        transcript.signatureBytes('initiator-confirm'));
      final finish = await _post(client, uri.replace(path: '/finish'), {
        'version': inAppPairingVersion,
        'id': id,
        'proof': _b64(myProof.bytes),
      });
      if (finish['status'] != 'registered-only') {
        throw StateError('对方未完成配对确认');
      }
      final verified = Signature(
        _fromB64(finish['proof'], 64), publicKey: responder.key);
      if (!await Ed25519().verify(
        transcript.signatureBytes('responder-confirm'), signature: verified,
      )) {
        throw StateError('配对完成签名无效');
      }
      await _saveRegistration(responder, name);
      final result = PairingResult(
        remoteName: name, fingerprint: responder.fingerprint,
        remoteIp: remoteIp);
      onPaired?.call(result);
      return result;
    } finally {
      client.close(force: true);
    }
  }
}
