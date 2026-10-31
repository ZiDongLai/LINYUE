import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import '../security/device_identity.dart';
import '../security/secure_core.dart' show secureRandomBytes;
import 'bluetooth_protocol.dart';

const bluetoothAssociationDomain = 'LINYUE_BT_ASSOC_E30_V1';
String _enc(List<int> b) => base64Url.encode(b).replaceAll('=', '');
List<int> _decode(Object? raw, int size) {
  if (raw is! String ||
      raw.length > 200 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(raw)) {
    throw const FormatException('Invalid association encoding');
  }
  final b = base64Url.decode(base64Url.normalize(raw));
  if (b.length != size || _enc(b) != raw) {
    throw const FormatException('Invalid association length');
  }
  return b;
}

List<int> _json(Object value) => utf8.encode(jsonEncode(value));

/// New first-association prelude, never a replacement for the B1 secure session.
/// Both commitments precede either reveal. Public identity possession alone is
/// not trust; unknown identities require TWO independently confirmed displays.
class BluetoothAssociation {
  BluetoothAssociation({
    required this.server,
    required this.identity,
    required this.localName,
    required this.write,
    required this.onState,
    required this.onComplete,
    this.expectedFingerprint,
    this.timeout = const Duration(seconds: 120),
  });
  final bool server;
  final DeviceIdentityManager identity;
  final String localName;
  final String? expectedFingerprint;
  final Future<void> Function(Uint8List bytes) write;
  final void Function(String state) onState;
  final Future<void> Function(String fingerprint, String name) onComplete;
  final Duration timeout;
  String phase = 'new', comparisonCode = '', peerName = '';
  PublicIdentityCard? peer;
  bool get needsConfirmation => phase == 'compare' && !_localApproved;
  bool get complete => phase == 'complete';
  bool get closed => phase == 'closed';
  bool _localApproved = false, _remoteApproved = false;
  bool _localKnown = false,
      _remoteKnown = false,
      _persisting = false,
      _persisted = false;
  bool _clientReady = false, _readySent = false;
  late SimpleKeyPair _ephemeral;
  late List<String> _localReveal;
  late String _localCommit, _remoteCommit;
  late List<String> _remoteReveal;
  late List<dynamic> _transcript;
  Timer? _deadline;
  Future<void> _outgoing = Future.value();
  String get _role => server ? 'server' : 'client';
  void _alive() {
    if (closed || complete) throw StateError('Association no longer active');
  }

  void _set(String state) {
    phase = state;
    onState(state);
  }

  String _commit(String role, List<String> reveal) => hashes.sha256
      .convert(
        _json([bluetoothAssociationDomain, bluetoothServiceUuid, role, reveal]),
      )
      .toString();
  List<int> _proof(String kind, String role, [Object? extra]) => _json([
    bluetoothAssociationDomain,
    bluetoothServiceUuid,
    kind,
    role,
    _transcript,
    extra,
  ]);
  Future<String> _sign(String kind, [Object? extra]) async =>
      _enc((await identity.local.sign(_proof(kind, _role, extra))).bytes);
  Future<void> _verify(String kind, Object? signature, [Object? extra]) async {
    final p = peer!;
    if (!await Ed25519().verify(
      _proof(kind, server ? 'client' : 'server', extra),
      signature: Signature(_decode(signature, 64), publicKey: p.key),
    )) {
      throw StateError('Association identity signature rejected');
    }
    _alive();
  }

  Future<void> _send(Map<String, dynamic> m) {
    final operation = _outgoing.then((_) async {
      _alive();
      await write(
        encodeBluetoothFrame({'v': bluetoothAssociationDomain, ...m}),
      );
    });
    _outgoing = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> start() async {
    if (phase != 'new') throw StateError('Association already started');
    _set('starting');
    _deadline = Timer(timeout, () => close('Identity association timeout'));
    try {
      _ephemeral = await X25519().newKeyPair();
      _alive();
      final name = localName.trim();
      _localReveal = [
        identity.local.card,
        name.isEmpty
            ? (server ? 'Android' : 'Windows')
            : name.substring(0, name.length.clamp(0, 40)),
        _enc(secureRandomBytes(32)),
        _enc((await _ephemeral.extractPublicKey()).bytes),
      ];
      _localCommit = _commit(_role, _localReveal);
      _set(server ? 'wait-client-commit' : 'wait-server-commit');
      if (!server) await _send({'t': 'commit', 'c': _localCommit});
    } catch (e) {
      close('Association start failed: $e');
      rethrow;
    }
  }

  void _readCommit(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const FormatException('Invalid commitment');
    }
    _remoteCommit = value;
  }

  void _readReveal(Object? raw) {
    if (raw is! List || raw.length != 4 || raw.any((v) => v is! String)) {
      throw const FormatException('Invalid reveal');
    }
    final reveal = raw.cast<String>();
    if (_commit(server ? 'client' : 'server', reveal) != _remoteCommit) {
      throw StateError('Association commitment mismatch');
    }
    final card = PublicIdentityCard.parse(reveal[0]);
    if (card.fingerprint == identity.local.fingerprint ||
        (expectedFingerprint != null &&
            card.fingerprint != expectedFingerprint)) {
      throw StateError('Association identity does not match trusted endpoint');
    }
    if (reveal[1].isEmpty ||
        reveal[1].length > 40 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(reveal[1])) {
      throw const FormatException('Invalid peer name');
    }
    _decode(reveal[2], 32);
    _decode(reveal[3], 32);
    peer = card;
    peerName = reveal[1];
    _remoteReveal = reveal;
    _localKnown = identity.entries.any((e) => e.card.encoded == card.encoded);
    // A pinned identity may not silently become an unknown first association.
    if (expectedFingerprint != null && !_localKnown) {
      throw StateError('Pinned identity revoked or missing');
    }
    _transcript = [
      bluetoothAssociationDomain,
      bluetoothServiceUuid,
      server ? _remoteCommit : _localCommit,
      server ? _localCommit : _remoteCommit,
      server ? _remoteReveal : _localReveal,
      server ? _localReveal : _remoteReveal,
    ];
  }

  Future<void> _compare() async {
    final shared = await X25519().sharedSecretKey(
      keyPair: _ephemeral,
      remotePublicKey: SimplePublicKey(
        _decode(_remoteReveal[3], 32),
        type: KeyPairType.x25519,
      ),
    );
    if ((await shared.extractBytes()).every((b) => b == 0)) {
      throw StateError('Invalid X25519 shared secret');
    }
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 6).deriveKey(
      secretKey: shared,
      nonce: hashes.sha256.convert(_json(_transcript)).bytes,
      info: _json([bluetoothAssociationDomain, 'visual-sas-48']),
    );
    _alive();
    final hex = (await key.extractBytes())
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    comparisonCode =
        '${hex.substring(0, 4)} ${hex.substring(4, 8)} ${hex.substring(8, 12)}';
    _set('compare');
    if (_localKnown && _remoteKnown) await confirm(true);
  }

  Future<void> confirm(bool accepted) async {
    if (phase != 'compare' || _localApproved) return;
    try {
      if (!accepted) {
        await _send({'t': 'reject', 'sig': await _sign('reject')});
        close('User rejected comparison code');
        return;
      }
      _localApproved = true;
      await _send({'t': 'approve', 'sig': await _sign('approve')});
      _alive();
      onState('waiting-for-peer-confirmation');
      await _saveIfConfirmed();
    } catch (e) {
      close('Association confirmation failed: $e');
      rethrow;
    }
  }

  Future<void> _saveIfConfirmed() async {
    if (!_localApproved || !_remoteApproved || _persisting) return;
    _persisting = true;
    final p = peer!;
    final exists = identity.entries.any((e) => e.card.encoded == p.encoded);
    if (_localKnown && !exists) {
      throw StateError('Identity revoked during association');
    }
    if (!exists) {
      // Same trust boundary as InAppPairingService._saveRegistration: both
      // signed proofs AND independent screen comparison completed, not TOFU.
      await identity.register(
        displayName: peerName,
        identityCard: p.encoded,
        independentlyCheckedFingerprint: p.fingerprint,
      );
    }
    _alive();
    _persisted = true;
    if (!server && !_readySent) {
      _readySent = true;
      await _send({'t': 'client-ready', 'sig': await _sign('client-ready')});
    }
    if (server && _clientReady) await _finishServer();
  }

  Future<void> _finishServer() async {
    if (!_persisted || !_clientReady || _readySent) return;
    _readySent = true;
    await _send({'t': 'server-ready', 'sig': await _sign('server-ready')});
    await _finish();
  }

  Future<void> _finish() async {
    _alive();
    if (!identity.entries.any((e) => e.card.encoded == peer!.encoded)) {
      throw StateError('Identity revoked before secure session');
    }
    _deadline?.cancel();
    _set('complete');
    await onComplete(peer!.fingerprint, peerName);
  }

  Future<void> receive(Map<String, dynamic> m) async {
    try {
      _alive();
      if (m['v'] != bluetoothAssociationDomain) {
        throw StateError(
          'E30 association protocol incompatible; update both devices',
        );
      }
      if (server && phase == 'wait-client-commit' && m['t'] == 'commit') {
        _readCommit(m['c']);
        _set('wait-client-reveal');
        await _send({'t': 'commit', 'c': _localCommit});
      } else if (!server &&
          phase == 'wait-server-commit' &&
          m['t'] == 'commit') {
        _readCommit(m['c']);
        _set('wait-server-reveal');
        await _send({'t': 'reveal', 'r': _localReveal});
      } else if (server &&
          phase == 'wait-client-reveal' &&
          m['t'] == 'reveal') {
        _readReveal(m['r']);
        _set('wait-client-proof');
        await _send({
          't': 'reveal-proof',
          'r': _localReveal,
          'known': _localKnown,
          'sig': await _sign('proof', _localKnown),
        });
      } else if (!server &&
          phase == 'wait-server-reveal' &&
          m['t'] == 'reveal-proof') {
        _readReveal(m['r']);
        if (m['known'] is! bool) {
          throw const FormatException('Missing trust mode');
        }
        _remoteKnown = m['known'] as bool;
        await _verify('proof', m['sig'], _remoteKnown);
        await _send({
          't': 'proof',
          'known': _localKnown,
          'sig': await _sign('proof', _localKnown),
        });
        await _compare();
      } else if (server && phase == 'wait-client-proof' && m['t'] == 'proof') {
        if (m['known'] is! bool) {
          throw const FormatException('Missing trust mode');
        }
        _remoteKnown = m['known'] as bool;
        await _verify('proof', m['sig'], _remoteKnown);
        await _compare();
      } else if (phase == 'compare' && m['t'] == 'approve') {
        if (_remoteApproved) {
          throw StateError('Repeated association confirmation');
        }
        await _verify('approve', m['sig']);
        _remoteApproved = true;
        await _saveIfConfirmed();
      } else if (phase == 'compare' && m['t'] == 'reject') {
        await _verify('reject', m['sig']);
        close('Peer rejected comparison code');
      } else if (server &&
          phase == 'compare' &&
          m['t'] == 'client-ready' &&
          _localApproved &&
          _remoteApproved) {
        await _verify('client-ready', m['sig']);
        _clientReady = true;
        await _finishServer();
      } else if (!server &&
          phase == 'compare' &&
          _persisted &&
          m['t'] == 'server-ready') {
        await _verify('server-ready', m['sig']);
        await _finish();
      } else {
        throw StateError('Unexpected association frame/state');
      }
    } catch (e) {
      close('Association rejected: $e');
      rethrow;
    }
  }

  void close([String? reason]) {
    if (closed || complete) return;
    _deadline?.cancel();
    phase = 'closed';
    comparisonCode = '';
    onState('error: ${reason ?? 'Association cancelled'}');
  }
}
