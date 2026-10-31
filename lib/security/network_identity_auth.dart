/// LINYUE DEV5A: experimental Ed25519 mutual network identity proof.
/// Only checks public keys already registered and independently verified in DEV4.
/// IMPORTANT: this does NOT authenticate or encrypt the legacy file transport.
/// Never use successful proof as authorization for an HTTP /offer or /upload.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'device_identity.dart';
import 'secure_core.dart' show secureRandomBytes;

const int identityProofPort = 46730;
const String identityProofVersion = 'linyue-auth-proof-v1';

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> _decodeSized(Object? raw, int length) {
  if (raw is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(raw)) {
    throw const FormatException('认证字段编码格式无效');
  }
  final bytes = base64Url.decode(base64Url.normalize(raw));
  if (bytes.length != length || _encode(bytes) != raw) {
    throw const FormatException('认证字段长度或编码不符合规范');
  }
  return bytes;
}

String _randomId() => secureRandomBytes(16).map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class _ProofTranscript {
  const _ProofTranscript({
    required this.id,
    required this.initiator,
    required this.responder,
    required this.clientNonce,
    required this.serverNonce,
  });

  final String id;
  final String initiator;
  final String responder;
  final String clientNonce;
  final String serverNonce;

  List<int> signedBytes(String role) => utf8.encode([
        identityProofVersion,
        role,
        id,
        initiator,
        responder,
        clientNonce,
        serverNonce,
      ].join('|'));
}

class _PendingProof {
  _PendingProof(this.transcript, this.sourceIp)
      : deadline = DateTime.now().add(const Duration(seconds: 30));
  final _ProofTranscript transcript;
  final String sourceIp;
  final DateTime deadline;
}

class IdentityProofServer {
  IdentityProofServer(this.identity);
  final DeviceIdentityManager identity;
  HttpServer? _server;
  final Map<String, _PendingProof> _pending = {};

  bool get running => _server != null;
  int? get port => _server?.port;

  /// Server is available only while the user keeps the identity panel open.
  Future<void> start({InternetAddress? address, int port = identityProofPort}) async {
    if (_server != null) return;
    // Throws if DEV4 protected local identity has not been initialized.
    identity.local;
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _server!.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    final old = _server;
    _server = null;
    _pending.clear();
    await old?.close(force: true);
  }

  bool _isRegistered(String card) =>
      identity.entries.any((entry) => entry.card.encoded == card);

  Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
    final bytes = <int>[];
    await for (final piece in request.timeout(const Duration(seconds: 5))) {
      if (bytes.length + piece.length > 2048) {
        throw const FormatException('认证请求过大');
      }
      bytes.addAll(piece);
    }
    final obj = jsonDecode(utf8.decode(bytes));
    if (obj is! Map<String, dynamic>) throw const FormatException('认证请求结构错误');
    return obj;
  }

  Future<void> _reply(HttpRequest req, int code, Map<String, dynamic> data) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    await req.response.close();
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method != 'POST') {
        await _reply(req, HttpStatus.methodNotAllowed, {'error': 'method not allowed'});
        return;
      }
      final body = await _readBody(req);
      if (body['version'] != identityProofVersion) {
        throw const FormatException('认证协议版本不兼容');
      }
      final sourceIp = req.connectionInfo?.remoteAddress.address;
      if (sourceIp == null) throw StateError('未知来源地址');
      if (req.uri.path == '/begin') {
        _pending.removeWhere((_, p) => DateTime.now().isAfter(p.deadline));
        if (_pending.length >= 12) throw StateError('认证请求过于频繁');
        final initiator = PublicIdentityCard.parse(body['initiator'] as String);
        if (!_isRegistered(initiator.encoded)) {
          throw StateError('请求者身份尚未登记');
        }
        if (body['expectedResponder'] != identity.local.card) {
          throw StateError('身份指纹不一致');
        }
        final clientNonce = _encode(_decodeSized(body['clientNonce'], 32));
        final transcript = _ProofTranscript(
          id: _randomId(),
          initiator: initiator.encoded,
          responder: identity.local.card,
          clientNonce: clientNonce,
          serverNonce: _encode(secureRandomBytes(32)),
        );
        _pending[transcript.id] = _PendingProof(transcript, sourceIp);
        final proof = await identity.local.sign(transcript.signedBytes('responder-begin'));
        await _reply(req, HttpStatus.ok, {
          'version': identityProofVersion,
          'id': transcript.id,
          'responder': identity.local.card,
          'serverNonce': transcript.serverNonce,
          'proof': _encode(proof.bytes),
        });
        return;
      }
      if (req.uri.path == '/finish') {
        final id = body['id'];
        if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
          throw const FormatException('认证请求 ID 错误');
        }
        final pending = _pending.remove(id); // One-use even on invalid signature.
        if (pending == null ||
            DateTime.now().isAfter(pending.deadline) ||
            pending.sourceIp != sourceIp ||
            !_isRegistered(pending.transcript.initiator)) {
          throw StateError('请求过期、重复或身份已被撤销');
        }
        final initiator = PublicIdentityCard.parse(pending.transcript.initiator);
        final proof = Signature(
          _decodeSized(body['proof'], 64),
          publicKey: initiator.key,
        );
        if (!await Ed25519().verify(
          pending.transcript.signedBytes('initiator-finish'),
          signature: proof,
        )) {
          throw StateError('请求者签名无效');
        }
        final serverFinal = await identity.local.sign(
          pending.transcript.signedBytes('responder-confirm'),
        );
        await _reply(req, HttpStatus.ok, {
          'version': identityProofVersion,
          'status': 'mutual-proof-only',
          'proof': _encode(serverFinal.bytes),
        });
        return;
      }
      await _reply(req, HttpStatus.notFound, {'error': 'endpoint not found'});
    } catch (_) {
      try {
        await _reply(req, HttpStatus.forbidden, {'error': 'authentication rejected'});
      } catch (_) {
        try { await req.response.close(); } catch (_) {}
      }
    }
  }
}

class IdentityProofResult {
  const IdentityProofResult({required this.fingerprint, required this.completedAt});
  final String fingerprint;
  final DateTime completedAt;
}

/// One-off mutual proof. No authenticated transfer session is created.
class IdentityProofClient {
  IdentityProofClient(this.identity);
  final DeviceIdentityManager identity;

  Future<Map<String, dynamic>> _post(HttpClient client, Uri url, Map<String, dynamic> body) async {
    final request = await client.postUrl(url).timeout(const Duration(seconds: 7));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > 2048) throw const FormatException('认证响应过大');
      bytes.addAll(chunk);
    }
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('对方拒绝身份认证或服务未准备好 (${response.statusCode})');
    }
    final obj = jsonDecode(utf8.decode(bytes));
    if (obj is! Map<String, dynamic> || obj['version'] != identityProofVersion) {
      throw const FormatException('认证响应内容不符合协议');
    }
    return obj;
  }

  static bool isAllowedTestIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final nums = <int>[];
    for (final s in parts) {
      if (s.isEmpty || (s.length > 1 && s[0] == '0')) return false;
      final n = int.tryParse(s);
      if (n == null || n < 0 || n > 255) return false;
      nums.add(n);
    }
    return nums[0] == 10 ||
        (nums[0] == 172 && nums[1] >= 16 && nums[1] <= 31) ||
        (nums[0] == 192 && nums[1] == 168) ||
        (nums[0] == 127 && nums[1] == 0 && nums[2] == 0 && nums[3] == 1);
  }

  Future<IdentityProofResult> verify({
    required String remoteIp,
    required RegisteredIdentity target,
    int port = identityProofPort,
  }) async {
    if (!isAllowedTestIpv4(remoteIp)) throw const FormatException('仅允许私有 IPv4 地址用于开发验证');
    if (!identity.entries.any((e) => e.fingerprint == target.fingerprint)) {
      throw StateError('目标设备不在本机登记列表中');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    try {
      final nonceA = _encode(secureRandomBytes(32));
      final base = Uri(scheme: 'http', host: remoteIp, port: port);
      final begin = await _post(client, base.replace(path: '/begin'), {
        'version': identityProofVersion,
        'initiator': identity.local.card,
        'expectedResponder': target.card.encoded,
        'clientNonce': nonceA,
      });
      final id = begin['id'];
      if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
          begin['responder'] != target.card.encoded) {
        throw StateError('远端身份与本地登记的公钥不匹配');
      }
      final nonceB = _encode(_decodeSized(begin['serverNonce'], 32));
      final transcript = _ProofTranscript(
        id: id,
        initiator: identity.local.card,
        responder: target.card.encoded,
        clientNonce: nonceA,
        serverNonce: nonceB,
      );
      final serverProof = Signature(
        _decodeSized(begin['proof'], 64), publicKey: target.card.key,
      );
      if (!await Ed25519().verify(transcript.signedBytes('responder-begin'), signature: serverProof)) {
        throw StateError('对方未能证明持有已登记的设备私钥');
      }
      final myProof = await identity.local.sign(transcript.signedBytes('initiator-finish'));
      final finish = await _post(client, base.replace(path: '/finish'), {
        'version': identityProofVersion,
        'id': id,
        'proof': _encode(myProof.bytes),
      });
      if (finish['status'] != 'mutual-proof-only') throw StateError('对方未确认身份握手');
      final finalProof = Signature(
        _decodeSized(finish['proof'], 64), publicKey: target.card.key,
      );
      if (!await Ed25519().verify(transcript.signedBytes('responder-confirm'), signature: finalProof)) {
        throw StateError('远端最终确认签名校验失败');
      }
      return IdentityProofResult(fingerprint: target.fingerprint, completedAt: DateTime.now());
    } finally {
      client.close(force: true);
    }
  }
}
