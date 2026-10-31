// E36 compatibility fixture: E34 frozen implementation, import paths only adapted.
import 'dart:io';
import 'e34_bluetooth_file_lane.dart';
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';
// E25-B1 isolated RFCOMM protocol. No LAN, history, files or enrollment writes.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'package:nearlink/security/device_identity.dart';
import 'package:nearlink/security/secure_core.dart' show secureRandomBytes;
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'e34_bluetooth_text_lane.dart';

const bluetoothServiceUuid = 'c7941b72-4eb5-4a42-a164-25b100004672';
const bluetoothProtocolDomain = 'LINYUE_BT_POC_V1';
const bluetoothMaxFrame = 16384;
const bluetoothMaxTestBytes = 2048;

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
List<int> _bytes(Object? value, {int? length, int max = bluetoothMaxFrame}) {
  if (value is! String ||
      value.length > max * 2 ||
      !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(value)) {
    throw const FormatException('Invalid base64 field');
  }
  final data = base64Url.decode(base64Url.normalize(value));
  if (_b64(data) != value ||
      data.length > max ||
      (length != null && data.length != length)) {
    throw const FormatException('Invalid field length');
  }
  return data;
}

Map<String, dynamic> _object(List<int> bytes) {
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected protocol object');
  }
  return value;
}

Uint8List encodeBluetoothFrame(Map<String, dynamic> message) {
  final body = utf8.encode(jsonEncode(message));
  if (body.isEmpty || body.length > bluetoothMaxFrame) {
    throw const FormatException('Frame length exceeds limit');
  }
  final frame = Uint8List(4 + body.length);
  ByteData.sublistView(frame).setUint32(0, body.length);
  frame.setRange(4, frame.length, body);
  return frame;
}

/// A four-byte big-endian length, followed by bounded strict UTF-8 JSON.
/// Allocates at most one validated frame; read boundaries have no meaning.
class BluetoothFrameDecoder {
  BluetoothFrameDecoder({this.maxBody = bluetoothMaxFrame})
    : assert(maxBody > 0 && maxBody <= bluetoothMaxFrame);
  final int maxBody;
  final _header = Uint8List(4);
  int _headerUsed = 0;
  Uint8List? _body;
  int _bodyUsed = 0;

  List<Map<String, dynamic>> add(List<int> bytes) {
    final messages = <Map<String, dynamic>>[];
    var offset = 0;
    while (offset < bytes.length) {
      if (_body == null) {
        _header[_headerUsed++] = bytes[offset++];
        if (_headerUsed != 4) continue;
        final size = ByteData.sublistView(_header).getUint32(0);
        if (size == 0 || size > maxBody) {
          reset();
          throw const FormatException('Invalid frame length');
        }
        _body = Uint8List(size);
      }
      final body = _body!;
      final count = (bytes.length - offset).clamp(0, body.length - _bodyUsed);
      body.setRange(_bodyUsed, _bodyUsed + count, bytes, offset);
      offset += count;
      _bodyUsed += count;
      if (_bodyUsed == body.length) {
        reset();
        messages.add(_object(body));
      }
    }
    return messages;
  }

  void finish() {
    final incomplete = _headerUsed != 0 || _body != null;
    reset();
    if (incomplete) {
      throw const FormatException('Truncated frame at disconnect');
    }
  }

  void reset() {
    _headerUsed = 0;
    _bodyUsed = 0;
    _body = null;
  }
}

/// Mutual trusted-identity proof using the same primitives as SecureFileChannel.
/// New domain/UUID and both nonces, identities and ephemeral keys are signed.
/// This PoC never enrolls an OS-paired but unregistered identity.
class BluetoothSecureSession {
  BluetoothSecureSession({
    required this.server,
    required this.identity,
    required this.expectedFingerprint,
    required this.write,
    required this.onState,
    required this.onTest,
    this.handshakeTimeout = const Duration(seconds: 20),
    this.ackTimeout = const Duration(seconds: 10),
    this.onText,
    this.filesEnabled = false,
    this.reverseFilesEnabled = false,
    this.fileStore,
    this.approveFile,
    this.onFileReceived,
    this.onFileProgress,
  });

  final bool server;
  final DeviceIdentityManager identity;
  final String expectedFingerprint;
  final Future<void> Function(Uint8List) write;
  final void Function(String) onState;
  final void Function(Uint8List) onTest;
  final Duration handshakeTimeout, ackTimeout;
  final Future<void> Function(TextChatMessage)? onText;
  final bool filesEnabled, reverseFilesEnabled;
  final BluetoothFileStore? fileStore;
  final Future<bool> Function(BluetoothFileOffer)? approveFile;
  final Future<void> Function(BluetoothFileOffer, File)? onFileReceived;
  final void Function(BluetoothFileProgress)? onFileProgress;
  BluetoothFileLane? _fileLane;
  bool get fileReady => authenticated && (_fileLane?.ready ?? false);
  bool get fileSendReady => authenticated && (_fileLane?.sendReady ?? false);
  bool get fileReceiveReady =>
      authenticated && (_fileLane?.receiveReady ?? false);
  Future<BluetoothFileOffer> sendFile(File file, {String? name}) async {
    if (!fileSendReady) throw StateError('蓝牙文件通道未就绪或方向不支持；不会改用LAN');
    _stillTrusted();
    return _fileLane!.send(file, name: name);
  }

  BluetoothTextLane? _textLane;
  bool get textReady => authenticated && (_textLane?.ready ?? false);
  Future<void> sendText(TextChatMessage message) async {
    if (!textReady) throw StateError('Bluetooth text channel not ready');
    try {
      _stillTrusted();
      await _textLane!.send(message);
    } catch (e) {
      close('Bluetooth text failed: $e');
      rethrow;
    }
  }

  String _phase = 'new';
  bool get authenticated => _phase == 'authenticated';
  bool get closed => _phase == 'closed';
  String? error;
  Timer? _deadline;
  late SimpleKeyPair _ephemeral;
  late String _nonce, _ephemeralText;
  late List<dynamic> _transcript;
  late List<int> _hash;
  SecretKey? _sendKey, _receiveKey;
  int _sendSequence = 0, _receiveSequence = 0;
  final _pending =
      <String, ({Completer<void> done, String digest, int length})>{};
  final _received = <String>{};
  Future<void> _outgoing = Future<void>.value();

  void _alive() {
    if (closed) throw StateError('Bluetooth session closed');
  }

  PublicIdentityCard _trusted(String card) {
    final remote = PublicIdentityCard.parse(card);
    if (remote.fingerprint == identity.local.fingerprint ||
        remote.fingerprint != expectedFingerprint ||
        !identity.entries.any(
          (e) =>
              e.fingerprint == remote.fingerprint &&
              e.card.encoded == remote.encoded,
        )) {
      throw StateError('Peer is not the selected registered LINYUE identity');
    }
    return remote;
  }

  void _stillTrusted() {
    if (!identity.entries.any((e) => e.fingerprint == expectedFingerprint)) {
      throw StateError('Selected identity revoked or missing');
    }
  }

  Future<void> start() async {
    if (_phase != 'new') throw StateError('Session already started');
    _phase = 'starting';
    _deadline = Timer(handshakeTimeout, () => close('Authentication timeout'));
    try {
      _stillTrusted();
      _ephemeral = await X25519().newKeyPair();
      _alive();
      _ephemeralText = _b64((await _ephemeral.extractPublicKey()).bytes);
      _nonce = _b64(secureRandomBytes(32));
      _alive();
      _phase = server ? 'wait-hello' : 'wait-server';
      onState('authenticating');
      if (!server) {
        await _emit({
          't': 'hello',
          'v': bluetoothProtocolDomain,
          'uuid': bluetoothServiceUuid,
          'card': identity.local.card,
          'n': _nonce,
          'e': _ephemeralText,
        });
      }
    } catch (e) {
      close('Authentication start failed: $e');
      rethrow;
    }
  }

  void _buildTranscript(
    String clientCard,
    String serverCard,
    String clientNonce,
    String serverNonce,
    String clientKey,
    String serverKey,
  ) {
    _transcript = [
      bluetoothProtocolDomain,
      bluetoothServiceUuid,
      clientCard,
      serverCard,
      clientNonce,
      serverNonce,
      clientKey,
      serverKey,
    ];
    _hash = hashes.sha256.convert(utf8.encode(jsonEncode(_transcript))).bytes;
  }

  List<int> _proof(String role) => utf8.encode(
    jsonEncode([bluetoothProtocolDomain, 'identity-proof', role, _transcript]),
  );
  Future<String> _sign(String role) async =>
      _b64((await identity.local.sign(_proof(role))).bytes);
  Future<void> _verify(
    String role,
    PublicIdentityCard peer,
    Object? signature,
  ) async {
    final valid = await Ed25519().verify(
      _proof(role),
      signature: Signature(_bytes(signature, length: 64), publicKey: peer.key),
    );
    _alive();
    if (!valid) throw StateError('Identity signature rejected');
  }

  Future<void> _derive(String peerKey) async {
    final shared = await X25519().sharedSecretKey(
      keyPair: _ephemeral,
      remotePublicKey: SimplePublicKey(
        _bytes(peerKey, length: 32),
        type: KeyPairType.x25519,
      ),
    );
    if ((await shared.extractBytes()).every((b) => b == 0)) {
      throw StateError('Invalid X25519 shared secret');
    }
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    Future<SecretKey> derive(String direction) => hkdf.deriveKey(
      secretKey: shared,
      nonce: _hash,
      info: utf8.encode(
        '$bluetoothProtocolDomain|$bluetoothServiceUuid|$direction',
      ),
    );
    _sendKey = await derive(server ? 'server-to-client' : 'client-to-server');
    _receiveKey = await derive(
      server ? 'client-to-server' : 'server-to-client',
    );
    _alive();
  }

  Future<void> _emit(Map<String, dynamic> message) async {
    _alive();
    _stillTrusted();
    await write(encodeBluetoothFrame(message));
    _alive();
  }

  List<int> _aad(String direction, int sequence) => utf8.encode(
    jsonEncode([
      bluetoothProtocolDomain,
      bluetoothServiceUuid,
      _b64(_hash),
      direction,
      sequence,
    ]),
  );
  Future<void> _sealed(Map<String, dynamic> message) {
    final operation = _outgoing.then((_) async {
      _alive();
      final seq = _sendSequence++;
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(jsonEncode(message)),
        secretKey: _sendKey!,
        nonce: secureRandomBytes(12),
        aad: _aad(server ? 'server-to-client' : 'client-to-server', seq),
      );
      await _emit({
        't': 'sealed',
        's': seq,
        'n': _b64(box.nonce),
        'm': _b64(box.mac.bytes),
        'd': _b64(box.cipherText),
      });
    });
    _outgoing = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<Map<String, dynamic>> _open(Map<String, dynamic> m) async {
    if (_receiveKey == null || m['s'] is! int || m['s'] != _receiveSequence) {
      throw StateError('Unexpected/replayed encrypted frame');
    }
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(
        _bytes(m['d']),
        nonce: _bytes(m['n'], length: 12),
        mac: Mac(_bytes(m['m'], length: 16)),
      ),
      secretKey: _receiveKey!,
      aad: _aad(
        server ? 'client-to-server' : 'server-to-client',
        _receiveSequence,
      ),
    );
    _alive();
    _receiveSequence++;
    return _object(plain);
  }

  void _authenticated() {
    _alive();
    _stillTrusted();
    _deadline?.cancel();
    _phase = 'authenticated';
    _deadline = Timer(
      const Duration(minutes: 10),
      () => close('Prototype session expired'),
    );
    onState('authenticated; session=${_b64(_hash).substring(0, 16)}');
    if (onText != null) {
      if (filesEnabled &&
          (!server || (fileStore != null && approveFile != null))) {
        _fileLane = BluetoothFileLane(
          server: server,
          reverseEnabled: reverseFilesEnabled,
          seal: _sealed,
          alive: () {
            _alive();
            _stillTrusted();
            if (!authenticated) {
              throw StateError('Authenticate before file messages');
            }
          },
          onProgress: (p) => onFileProgress?.call(p),
          store: fileStore,
          approve: approveFile,
          onReceived: onFileReceived,
        );
      }
      _textLane = BluetoothTextLane(
        fileCapability: _fileLane?.capability,
        reverseFileCapability: _fileLane?.reverseCapability,
        onReverseFileOffer: _fileLane?.observeReverse,
        onReverseFileAck: _fileLane?.confirmReverse,
        onFileOffer: _fileLane?.observeCapability,
        onFileAck: _fileLane?.confirmCapability,
        seal: _sealed,
        onText: onText!,
        onReady: () => onState('text-ready'),
        onFailure: (reason) => close(reason),
        ackTimeout: ackTimeout,
      );
      unawaited(
        _textLane!.start().catchError((Object e) {
          close('Text readiness failed: $e');
        }),
      );
    }
  }

  /// Caller must serialize this method for each native connection generation.
  Future<void> receive(Map<String, dynamic> m) async {
    try {
      _alive();
      _stillTrusted();
      if (server && _phase == 'wait-hello' && m['t'] == 'hello') {
        if (m['v'] != bluetoothProtocolDomain ||
            m['uuid'] != bluetoothServiceUuid) {
          throw StateError('Incompatible protocol/UUID');
        }
        final peer = _trusted(m['card'] as String);
        _bytes(m['n'], length: 32);
        _bytes(m['e'], length: 32);
        _buildTranscript(
          peer.encoded,
          identity.local.card,
          m['n'] as String,
          _nonce,
          m['e'] as String,
          _ephemeralText,
        );
        _phase = 'wait-client-proof';
        await _emit({
          't': 'server',
          'card': identity.local.card,
          'n': _nonce,
          'e': _ephemeralText,
          'sig': await _sign('server'),
        });
      } else if (!server && _phase == 'wait-server' && m['t'] == 'server') {
        final peer = _trusted(m['card'] as String);
        _bytes(m['n'], length: 32);
        _bytes(m['e'], length: 32);
        _buildTranscript(
          identity.local.card,
          peer.encoded,
          _nonce,
          m['n'] as String,
          _ephemeralText,
          m['e'] as String,
        );
        await _verify('server', peer, m['sig']);
        await _derive(m['e'] as String);
        _phase = 'wait-server-finished';
        await _emit({'t': 'client-proof', 'sig': await _sign('client')});
      } else if (server &&
          _phase == 'wait-client-proof' &&
          m['t'] == 'client-proof') {
        await _verify('client', _trusted(_transcript[2] as String), m['sig']);
        await _derive(_transcript[6] as String);
        _phase = 'wait-client-finished';
        await _sealed({'k': 'server-finished'});
      } else if (m['t'] == 'sealed') {
        final value = await _open(m);
        if (!server &&
            _phase == 'wait-server-finished' &&
            value['k'] == 'server-finished') {
          _phase = 'wait-ready';
          await _sealed({'k': 'client-finished'});
        } else if (server &&
            _phase == 'wait-client-finished' &&
            value['k'] == 'client-finished') {
          await _sealed({'k': 'ready'});
          _authenticated();
        } else if (!server && _phase == 'wait-ready' && value['k'] == 'ready') {
          _authenticated();
        } else if (authenticated) {
          await _business(value);
        } else {
          throw StateError(
            'Business or unexpected message before authentication',
          );
        }
      } else {
        throw StateError('Unexpected frame/authentication state');
      }
    } catch (e) {
      close('Protocol rejected: $e');
      rethrow;
    }
  }

  Future<void> _business(Map<String, dynamic> m) async {
    if (m['k'] is String && (m['k'] as String).startsWith('file-')) {
      if (!fileReady) throw StateError('Bluetooth file capability unavailable');
      await _fileLane!.receive(m);
      return;
    }
    if (m['k'] is String && (m['k'] as String).startsWith('text-')) {
      final lane = _textLane;
      if (lane == null) {
        throw StateError('Bluetooth text capability unavailable');
      }
      await lane.receive(m);
      return;
    }
    if (m['k'] == 'test') {
      final id = m['id'];
      if (id is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id) ||
          _received.length >= 128 ||
          !_received.add(id)) {
        throw StateError('Invalid, repeated or excessive test ID');
      }
      final data = Uint8List.fromList(
        _bytes(m['d'], max: bluetoothMaxTestBytes),
      );
      onTest(
        data,
      ); // ACK only after the authenticated receiver callback succeeds.
      await _sealed({
        'k': 'ack',
        'id': id,
        'sha': hashes.sha256.convert(data).toString(),
        'size': data.length,
      });
    } else if (m['k'] == 'ack') {
      final entry = _pending[m['id']];
      if (entry == null ||
          m['sha'] != entry.digest ||
          m['size'] != entry.length) {
        throw StateError('ACK mismatch');
      }
      _pending.remove(m['id']);
      entry.done.complete();
    } else {
      throw StateError('Unsupported prototype message');
    }
  }

  Future<void> sendTest(List<int> data) async {
    if (!authenticated ||
        data.length > bluetoothMaxTestBytes ||
        _pending.isNotEmpty) {
      throw StateError(
        'Authenticate first; max2048 bytes and one outstanding test',
      );
    }
    try {
      _stillTrusted();
    } catch (e) {
      close('Selected identity no longer trusted');
      rethrow;
    }
    final id = _b64(secureRandomBytes(16));
    final done = Completer<void>();
    // Attach an error handler before any asynchronous write/disconnect.
    final confirmed = done.future.timeout(ackTimeout);
    unawaited(confirmed.catchError((Object _) {}));
    _pending[id] = (
      done: done,
      digest: hashes.sha256.convert(data).toString(),
      length: data.length,
    );
    try {
      await _sealed({'k': 'test', 'id': id, 'd': _b64(data)});
      await confirmed;
      _alive();
    } catch (e) {
      close('Test not acknowledged: $e');
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  void close([String? reason]) {
    if (closed) return;
    _phase = 'closed';
    error = reason;
    _deadline?.cancel();
    _sendKey = null;
    _receiveKey = null;
    _fileLane?.close();
    _textLane?.close();
    for (final p in _pending.values) {
      if (!p.done.isCompleted) {
        p.done.completeError(StateError(reason ?? 'Disconnected'));
      }
    }
    _pending.clear();
    _received.clear();
    onState(reason == null ? 'closed' : 'error: $reason');
  }
}
