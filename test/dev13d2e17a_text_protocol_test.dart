import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';

void main() {
  final alice = {'linyue.chat.text.v1'};

  test('E17-A capability: legacy and unknown peers cannot receive new frames', () {
    expect(ConversationTextProtocol.mayExchangeText(
      localCapabilities: alice, remoteAuthenticatedCapabilities: null), isFalse);
    expect(ConversationTextProtocol.mayExchangeText(
      localCapabilities: alice, remoteAuthenticatedCapabilities: <String>{}), isFalse);
    expect(ConversationTextProtocol.mayExchangeText(
      localCapabilities: <String>{}, remoteAuthenticatedCapabilities: alice), isFalse);
    expect(ConversationTextProtocol.mayExchangeText(
      localCapabilities: alice, remoteAuthenticatedCapabilities: alice), isTrue);
  });

  test('E17-A Chinese emoji multiline messages round-trip losslessly', () {
    const body = '你好，邻跃 🌟\n文件收到了。\tOK';
    final msg = TextChatMessage.create(body, createdAt: DateTime.utc(2026, 10, 20, 12));
    final encoded = ConversationTextProtocol.encode(msg);
    final decoded = ConversationTextProtocol.decode(encoded);
    expect(decoded.body, body);
    expect(decoded.id, msg.id);
    expect(decoded.createdAt, DateTime.utc(2026, 10, 20, 12));
    expect(ConversationTextProtocol.validId(msg.id), isTrue);
  });

  test('E17-A rejects empty, oversized and control-code text', () {
    for (final text in ['', ' \n ', 'abc\u0000def', 'bad\u0008']) {
      expect(ConversationTextProtocol.isValidBody(text), isFalse);
    }
    expect(ConversationTextProtocol.isValidBody(List<String>.filled(2800, '中').join()), isFalse);
    expect(ConversationTextProtocol.isValidBody('ok\nnext'), isTrue);
  });

  test('E17-A rejects file bytes, malformed UTF8 and unsupported versions', () {
    expect(() => ConversationTextProtocol.decode(Uint8List.fromList([0, 1, 2])), throwsFormatException);
    expect(() => ConversationTextProtocol.decode(Uint8List.fromList([0xff, 0xfe])), throwsFormatException);
    final msg = TextChatMessage.create('Hello');
    final raw = utf8.decode(ConversationTextProtocol.encode(msg));
    expect(() => ConversationTextProtocol.decode(Uint8List.fromList(
        utf8.encode(raw.replaceFirst('"version":1', '"version":2')))), throwsFormatException);
    expect(() => ConversationTextProtocol.decode(Uint8List(ConversationTextProtocol.maxFrameBytes + 1)), throwsFormatException);
  });

  test('E17-A replay suppression scoped to authenticated device', () {
    const id = '0123456789abcdef0123456789abcdef';
    final replay = TextMessageReplayWindow(perPeerLimit: 2);
    expect(replay.checkAndRemember(authenticatedPeerId: 'peerA', messageId: id), isTrue);
    expect(replay.checkAndRemember(authenticatedPeerId: 'peerA', messageId: id), isFalse);
    expect(replay.checkAndRemember(authenticatedPeerId: 'peerB', messageId: id), isTrue);
  });

  test('E17-A dedupe memory bounded per peer', () {
    final replay = TextMessageReplayWindow(perPeerLimit: 2);
    const a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const c = 'cccccccccccccccccccccccccccccccc';
    expect(replay.checkAndRemember(authenticatedPeerId: 'peer', messageId: a), isTrue);
    expect(replay.checkAndRemember(authenticatedPeerId: 'peer', messageId: b), isTrue);
    expect(replay.checkAndRemember(authenticatedPeerId: 'peer', messageId: c), isTrue);
    expect(replay.checkAndRemember(authenticatedPeerId: 'peer', messageId: b), isFalse);
    expect(replay.checkAndRemember(authenticatedPeerId: 'peer', messageId: a), isTrue);
  });
}
