import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:nearlink/services/conversation_text_protocol.dart';

/// Runs ONLY inside B1's authenticated AES-GCM channel. Text model/history are
/// shared with LAN, transport and capability negotiation are explicitly BT.
class BluetoothTextLane {
  BluetoothTextLane({
    required this.seal,
    required this.onText,
    required this.onReady,
    required this.onFailure,
    this.fileCapability,
    this.onFileOffer,
    this.onFileAck,
    this.ackTimeout = const Duration(seconds: 15),
  });
  final Future<void> Function(Map<String, dynamic>) seal;
  final Future<void> Function(TextChatMessage) onText;
  final void Function() onReady;
  final void Function(String) onFailure;
  final Duration ackTimeout;
  final Map<String, dynamic>? fileCapability;
  final void Function(Object?)? onFileOffer;
  final void Function(Object?, Object?)? onFileAck;
  bool _remoteReady = false, _ackedReady = false, _closed = false;
  bool get ready => !_closed && _remoteReady && _ackedReady;
  final _received = <String, String>{};
  String? _partId;
  int _partCount = 0, _partNext = 0;
  final _parts = BytesBuilder(copy: false);
  Timer? _partDeadline;
  ({String id, String sha, int size, Completer<void> done})? _pending;
  void _alive() {
    if (_closed) throw StateError('Bluetooth text channel disconnected');
  }

  Future<void> start() => seal({
    'k': 'text-ready',
    'cap': ConversationTextProtocol.capability,
    'max': 8192,
    if (fileCapability != null) 'file': fileCapability,
  });
  Future<void> receive(Map<String, dynamic> m) async {
    _alive();
    if (m['k'] == 'text-ready') {
      if (_remoteReady ||
          m['cap'] != ConversationTextProtocol.capability ||
          m['max'] != 8192) {
        throw StateError('Invalid Bluetooth text capability');
      }
      _remoteReady = true;
      onFileOffer?.call(m['file']);
      await seal({
        'k': 'text-ready-ack',
        'cap': ConversationTextProtocol.capability,
        if (fileCapability != null) 'file': fileCapability,
        if (fileCapability != null && m['file'] != null) 'fileEcho': m['file'],
      });
      if (ready) onReady();
      return;
    }
    if (m['k'] == 'text-ready-ack') {
      if (_ackedReady || m['cap'] != ConversationTextProtocol.capability) {
        throw StateError('Invalid text readiness acknowledgement');
      }
      _ackedReady = true;
      onFileAck?.call(m['file'], m['fileEcho']);
      if (ready) onReady();
      return;
    }
    if (!ready) throw StateError('Bluetooth text channel not ready');
    if (m['k'] == 'text-part') {
      final id = m['id'], index = m['i'], count = m['count'], data = m['d'];
      if (id is! String ||
          !ConversationTextProtocol.validId(id) ||
          index is! int ||
          count is! int ||
          count < 1 ||
          count > 32 ||
          data is! String ||
          data.length > 2800) {
        throw const FormatException('Invalid text fragment');
      }
      final bytes = base64Url.decode(base64Url.normalize(data));
      if (base64Url.encode(bytes).replaceAll('=', '') != data ||
          bytes.isEmpty ||
          bytes.length > 2048) {
        throw const FormatException('Invalid text fragment bytes');
      }
      if (_partId == null) {
        if (index != 0) throw StateError('Missing first text fragment');
        _partId = id;
        _partCount = count;
        _partNext = 0;
        _partDeadline = Timer(
          ackTimeout,
          () => onFailure('Incomplete Bluetooth text message timeout'),
        );
      }
      if (id != _partId ||
          count != _partCount ||
          index != _partNext ||
          _parts.length + bytes.length > 65536) {
        throw StateError('Out-of-order or excessive text fragments');
      }
      _parts.add(bytes);
      _partNext++;
      if (_partNext != _partCount) return;
      _partDeadline?.cancel();
      final payload = _parts.takeBytes();
      _partId = null;
      // E30 wire envelope can exceed LAN's 12KiB JSON frame for escaped text,
      // but the SAME validated TextChatMessage body remains limited to 8KiB.
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map ||
          decoded.length != 3 ||
          decoded['id'] != id ||
          decoded['text'] is! String ||
          decoded['at'] is! String) {
        throw const FormatException('Invalid Bluetooth text envelope');
      }
      final time = DateTime.tryParse(decoded['at'] as String);
      if (time == null || !(decoded['at'] as String).endsWith('Z')) {
        throw const FormatException('Invalid text timestamp');
      }
      final message = TextChatMessage(
        id: id,
        createdAt: time,
        body: decoded['text'] as String,
      )..validate();
      final digest = hashes.sha256.convert(payload).toString();
      final old = _received[id];
      if (old != null && old != digest) {
        throw StateError('Text ID reused for different content');
      }
      if (old == null) {
        await onText(message); // Durable history write MUST finish before ACK.
        _alive();
        _received[id] = digest;
        if (_received.length > 256) _received.remove(_received.keys.first);
      }
      await seal({
        'k': 'text-ack',
        'id': id,
        'sha': digest,
        'size': payload.length,
      });
    } else if (m['k'] == 'text-ack') {
      final pending = _pending;
      if (pending == null ||
          m['id'] != pending.id ||
          m['sha'] != pending.sha ||
          m['size'] != pending.size) {
        throw StateError('Bluetooth text ACK mismatch');
      }
      if (pending.done.isCompleted) {
        throw StateError('Repeated Bluetooth text ACK');
      }
      pending.done.complete();
    } else {
      throw StateError('Unsupported Bluetooth text frame');
    }
  }

  Future<void> send(TextChatMessage message) async {
    _alive();
    message.validate();
    if (!ready || _pending != null) {
      throw StateError('Bluetooth text not ready or another message pending');
    }
    final payload = utf8.encode(
      jsonEncode({
        'id': message.id,
        'at': message.createdAt.toUtc().toIso8601String(),
        'text': message.body,
      }),
    );
    final done = Completer<void>();
    final confirmed = done.future.timeout(ackTimeout);
    unawaited(confirmed.catchError((Object _) {}));
    _pending = (
      id: message.id,
      sha: hashes.sha256.convert(payload).toString(),
      size: payload.length,
      done: done,
    );
    try {
      final count = (payload.length + 2047) ~/ 2048;
      for (var i = 0; i < count; i++) {
        _alive();
        final end = ((i + 1) * 2048).clamp(0, payload.length);
        await seal({
          'k': 'text-part',
          'id': message.id,
          'i': i,
          'count': count,
          'd': base64Url
              .encode(payload.sublist(i * 2048, end))
              .replaceAll('=', ''),
        });
      }
      await confirmed;
      _alive();
    } catch (e) {
      onFailure('Bluetooth text delivery unconfirmed: $e');
      rethrow;
    } finally {
      _pending = null;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _partDeadline?.cancel();
    _parts.clear();
    _partId = null;
    final done = _pending?.done;
    if (done != null && !done.isCompleted) {
      done.completeError(
        StateError('Bluetooth text disconnected; delivery unknown'),
      );
    }
    _received.clear();
  }
}
