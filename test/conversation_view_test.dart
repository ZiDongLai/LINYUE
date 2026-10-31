import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/transfer_history.dart';
import 'package:nearlink/services/conversation_view.dart';

TransferRecord entry(String name, String direction, String peer, int minute, int bytes) =>
    TransferRecord(
      name: name, peerName: peer, direction: direction, status: 'success',
      bytes: bytes, timestamp: DateTime.utc(2026, 10, 17, 12, minute),
    );

void main() {
  test('mix send/receive sorted newest first, but not other targets', () {
    final all = [
      entry('old.txt', 'send', 'Computer A', 1, 10),
      entry('from unknown', 'receive', '来源未验证', 3, 9),
      entry('other-device.txt', 'send', 'Computer B', 5, 7),
      entry('new.jpg', 'send', 'Computer A', 4, 2048),
    ];
    expect(recentConversationEntries(all, peerName: 'Computer A').map((x) => x.name).toList(),
        ['new.jpg', 'from unknown', 'old.txt']);
  });

  test('no peer still shows received records only', () {
    final all = [
      entry('in.jpg', 'receive', '未验证', 1, 1),
      entry('out.jpg', 'send', 'Phone', 2, 1),
    ];
    expect(recentConversationEntries(all, peerName: null).single.name, 'in.jpg');
  });

  test('recent limit and old 0-byte warning', () {
    final all = [
      entry('a.png', 'send', 'Phone', 1, 0),
      entry('b.bin', 'send', 'Phone', 2, 0),
      entry('c.txt', 'send', 'Phone', 3, 15),
    ];
    final visible = recentConversationEntries(all, peerName: 'Phone', maxEntries: 2);
    expect(visible.length, 2);
    expect(visible.first.name, 'c.txt');
    expect(conversationSizeLabel(all.first), contains('请核对'));
    expect(conversationSizeLabel(all.last), '15 B');
  });
}
