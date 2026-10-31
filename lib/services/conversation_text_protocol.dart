import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// DEV13D2E17-A: local protocol model ONLY. No networking or UI is wired here.
/// A future stage may send these frames only inside the already authenticated,
/// encrypted connection and only after explicit peer capability negotiation.
final class ConversationTextProtocol {
  ConversationTextProtocol._();

  static const String capability = 'linyue.chat.text.v1';
  static const String marker = 'LINYUE_CHAT_TEXT_V1:';
  static const int maxMessageBytes = 8 * 1024;
  static const int maxFrameBytes = 12 * 1024;

  /// Legacy/unknown peers advertise nothing; never send text to them.
  static bool mayExchangeText({
    required Set<String> localCapabilities,
    required Set<String>? remoteAuthenticatedCapabilities,
  }) => localCapabilities.contains(capability) &&
      (remoteAuthenticatedCapabilities?.contains(capability) ?? false);

  static bool isValidBody(String body) {
    if (body.trim().isEmpty) return false;
    if (utf8.encode(body).length > maxMessageBytes) return false;
    // Preserve newlines and tabs, but do not admit invisible control codes.
    for (final rune in body.runes) {
      if ((rune >= 0 && rune < 0x20 && rune != 0x09 && rune != 0x0A) ||
          rune == 0x7F) {
        return false;
      }
    }
    return true;
  }

  static String newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool validId(String id) => RegExp(r'^[0-9a-f]{32}$').hasMatch(id);

  static Uint8List encode(TextChatMessage message) {
    message.validate();
    final payload = <String, Object>{
      'type': 'text',
      'version': 1,
      'id': message.id,
      'at': message.createdAt.toUtc().toIso8601String(),
      'text': message.body,
    };
    final bytes = utf8.encode('$marker${jsonEncode(payload)}');
    if (bytes.length > maxFrameBytes) {
      throw const FormatException('Text message frame too large');
    }
    return Uint8List.fromList(bytes);
  }

  static TextChatMessage decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxFrameBytes) {
      throw const FormatException('Invalid text frame length');
    }
    final frame = utf8.decode(bytes, allowMalformed: false);
    if (!frame.startsWith(marker)) {
      throw const FormatException('Not a LINYUE text frame');
    }
    final Object? decoded = jsonDecode(frame.substring(marker.length));
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 5 ||
        decoded['type'] != 'text' ||
        decoded['version'] != 1 ||
        decoded['id'] is! String ||
        decoded['at'] is! String ||
        decoded['text'] is! String) {
      throw const FormatException('Invalid or unsupported text message');
    }
    final rawTime = decoded['at'] as String;
    final time = DateTime.tryParse(rawTime);
    if (time == null || !rawTime.endsWith('Z')) {
      throw const FormatException('Invalid message timestamp');
    }
    final message = TextChatMessage(
      id: decoded['id'] as String,
      createdAt: time.toUtc(),
      body: decoded['text'] as String,
    );
    message.validate();
    return message;
  }
}

/// Immutable text message. IDs only deduplicate; they are NOT authorization.
final class TextChatMessage {
  const TextChatMessage({
    required this.id,
    required this.createdAt,
    required this.body,
  });

  factory TextChatMessage.create(String body, {DateTime? createdAt}) =>
      TextChatMessage(
        id: ConversationTextProtocol.newId(),
        createdAt: (createdAt ?? DateTime.now()).toUtc(),
        body: body,
      )..validate();

  final String id;
  final DateTime createdAt;
  final String body;

  void validate() {
    if (!ConversationTextProtocol.validId(id)) {
      throw const FormatException('Invalid text message id');
    }
    if (!ConversationTextProtocol.isValidBody(body)) {
      throw const FormatException('Invalid text message body');
    }
    if (createdAt.millisecondsSinceEpoch < 0 ||
        createdAt.toUtc().year > 9998) {
      throw const FormatException('Invalid text message time');
    }
  }
}

/// In-memory idempotency guard; must be scoped to an authenticated peer ID.
/// A durable replay journal can be introduced before production chat delivery.
final class TextMessageReplayWindow {
  TextMessageReplayWindow({this.perPeerLimit = 128}) {
    if (perPeerLimit < 1 || perPeerLimit > 4096) {
      throw ArgumentError.value(perPeerLimit, 'perPeerLimit');
    }
  }

  final int perPeerLimit;
  final Map<String, LinkedHashSet<String>> _seen = {};

  /// Returns false for duplicate IDs from the same authenticated peer.
  bool checkAndRemember({required String authenticatedPeerId, required String messageId}) {
    if (authenticatedPeerId.trim().isEmpty ||
        !ConversationTextProtocol.validId(messageId)) {
      throw const FormatException('Invalid deduplication key');
    }
    final set = _seen.putIfAbsent(authenticatedPeerId, LinkedHashSet<String>.new);
    if (set.contains(messageId)) return false;
    set.add(messageId);
    while (set.length > perPeerLimit) {
      set.remove(set.first);
    }
    return true;
  }

  void forgetPeer(String authenticatedPeerId) => _seen.remove(authenticatedPeerId);
}
