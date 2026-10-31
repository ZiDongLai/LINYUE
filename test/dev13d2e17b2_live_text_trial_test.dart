import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/conversation_text_protocol.dart';
import 'package:nearlink/services/live_text_trial_ledger.dart';

void main() {
  test('B2 incoming/outgoing messages remain isolated by verified identity', () {
    final ledger = LiveTextTrialLedger();
    final message = TextChatMessage.create('你好 😀\nEnglish');
    expect(ledger.recordIncoming(
      authenticatedFingerprint: 'peer-A', message: message), isTrue);
    expect(ledger.recordIncoming(
      authenticatedFingerprint: 'peer-A', message: message), isFalse);
    expect(ledger.recordOutgoingConfirmed(
      authenticatedFingerprint: 'peer-B', message: message), isTrue);
    final all = ledger.snapshot();
    expect(all, hasLength(2));
    expect(all.where((x) => x.authenticatedFingerprint == 'peer-A').single.outbound, isFalse);
    expect(all.where((x) => x.authenticatedFingerprint == 'peer-B').single.outbound, isTrue);
    expect(all.first.message.body, '你好 😀\nEnglish');
  });

  test('B2 volatile history is bounded and preserves the newest message', () {
    final ledger = LiveTextTrialLedger(maxEntries: 3);
    final ids = <String>[];
    for (var i = 0; i < 5; i++) {
      final msg = TextChatMessage.create('message $i');
      ids.add(msg.id);
      expect(ledger.recordIncoming(authenticatedFingerprint: 'peer', message: msg), isTrue);
    }
    expect(ledger.snapshot().length, 3);
    expect(ledger.snapshot().first.message.id, ids[2]);
    expect(ledger.snapshot().last.message.id, ids[4]);
  });

  test('B2 an absent or invalid identity never inserts text', () {
    final ledger = LiveTextTrialLedger();
    final message = TextChatMessage.create('sensitive');
    expect(() => ledger.recordIncoming(
      authenticatedFingerprint: ' ', message: message), throwsFormatException);
    expect(ledger.snapshot(), isEmpty);
  });

  test('B2 an invalid message never enters the received or sent inbox', () {
    final ledger = LiveTextTrialLedger();
    final forged = TextChatMessage(
      id: 'forged', createdAt: DateTime.now(), body: 'bad');
    expect(() => ledger.recordIncoming(
      authenticatedFingerprint: 'peer', message: forged), throwsFormatException);
    expect(ledger.snapshot(), isEmpty);
  });
}
