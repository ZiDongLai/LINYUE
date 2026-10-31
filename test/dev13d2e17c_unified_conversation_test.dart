import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/conversation_timeline_merge.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'package:nearlink/services/live_text_trial_ledger.dart';
import 'package:nearlink/services/transfer_history.dart';

TransferRecord fileAt(int seconds) => TransferRecord(
  name: 'picture.png', peerName: 'Windows', direction: 'receive',
  status: 'success', bytes: 10,
  timestamp: DateTime.utc(2026, 10, 20, 12, 0, seconds),
);

TrialTextItem textAt(int seconds, String fingerprint, {bool outbound = false}) =>
  TrialTextItem(
    authenticatedFingerprint: fingerprint,
    outbound: outbound,
    message: TextChatMessage.create('你好 $seconds 😀',
      createdAt: DateTime.utc(2026, 10, 20, 12, 0, seconds)),
  );

void main() {
  test('E17-C authenticated messages and files interleave newest first', () {
    final results = ConversationTimelineMerge.merge(
      files: [fileAt(5), fileAt(25)],
      texts: [textAt(15, 'verified-A'), textAt(30, 'verified-A')],
      authenticatedFingerprint: 'verified-A',
    );
    expect(results, hasLength(4));
    expect(results.map((i) => i.timestamp.second), [30, 25, 15, 5]);
    expect(results.first.text?.outbound, isFalse);
    expect(results[1].file, isNotNull);
  });

  test('E17-C unverified or different peer must never see unrelated text', () {
    final texts = [textAt(1, 'verified-A'), textAt(2, 'verified-B')];
    final none = ConversationTimelineMerge.merge(
      files: [fileAt(3)], texts: texts, authenticatedFingerprint: null);
    expect(none, hasLength(1));
    expect(none.first.text, isNull);
    final b = ConversationTimelineMerge.merge(
      files: const [], texts: texts, authenticatedFingerprint: 'verified-B');
    expect(b.single.text?.authenticatedFingerprint, 'verified-B');
  });

  test('E17-C caps timeline entries and rejects invalid caps', () {
    final entries = ConversationTimelineMerge.merge(
      files: [fileAt(1), fileAt(2), fileAt(3)], texts: const [],
      authenticatedFingerprint: null, maxEntries: 2);
    expect(entries.map((i) => i.timestamp.second), [3, 2]);
    expect(() => ConversationTimelineMerge.merge(
      files: const [], texts: const [],
      authenticatedFingerprint: null, maxEntries: 0), throwsArgumentError);
  });

  test('E17-C keeps B1 8 KiB UTF-8 validation and multiline text', () {
    expect(ConversationTextProtocol.isValidBody('中文 😀\nsecond line'), isTrue);
    expect(ConversationTextProtocol.isValidBody('   '), isFalse);
    expect(ConversationTextProtocol.isValidBody(List<String>.filled(3000, '中').join()), isFalse);
  });
}
