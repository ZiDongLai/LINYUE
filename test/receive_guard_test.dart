import 'package:flutter_test/flutter_test.dart';
import '../lib/services/receive_guard.dart';

void main() {
  test('default receive prompt and manual pause', () {
    final guard = ReceiveGuard();
    final now = DateTime.utc(2026, 10, 17, 9);
    expect(guard.check('192.168.1.8', at: now), ReceiveDecision.prompt);
    guard.receivingEnabled = false;
    expect(guard.check('192.168.1.8', at: now), ReceiveDecision.paused);
    guard.receivingEnabled = true;
    expect(guard.check('192.168.1.8', at: now), ReceiveDecision.prompt);
  });

  test('three declines in ten minutes block only that source', () {
    final guard = ReceiveGuard();
    final at = DateTime.utc(2026, 10, 17, 9);
    for (var n = 0; n < 3; n++) {
      guard.noteDecline('192.168.1.8', at: at.add(Duration(minutes: n)));
    }
    expect(guard.check('192.168.1.8', at: at.add(const Duration(minutes: 2))),
        ReceiveDecision.blocked);
    expect(guard.check('192.168.1.9', at: at.add(const Duration(minutes: 2))),
        ReceiveDecision.prompt);
    expect(guard.check('192.168.1.8', at: at.add(const Duration(minutes: 13))),
        ReceiveDecision.prompt);
  });

  test('successful acceptance clears rolling declines', () {
    final guard = ReceiveGuard();
    final at = DateTime.utc(2026, 10, 17, 9);
    guard.noteDecline('192.168.1.8', at: at);
    guard.noteDecline('192.168.1.8', at: at.add(const Duration(minutes: 1)));
    guard.noteAccepted('192.168.1.8');
    guard.noteDecline('192.168.1.8', at: at.add(const Duration(minutes: 2)));
    expect(guard.check('192.168.1.8', at: at.add(const Duration(minutes: 2))),
        ReceiveDecision.prompt);
  });

  test('manual block and unblock', () {
    final guard = ReceiveGuard();
    final at = DateTime.utc(2026, 10, 17, 9);
    guard.block('10.0.0.2', at: at);
    expect(guard.check('10.0.0.2', at: at), ReceiveDecision.blocked);
    guard.clearBlocks();
    expect(guard.check('10.0.0.2', at: at), ReceiveDecision.prompt);
  });

  test('declines expire outside rolling window', () {
    final guard = ReceiveGuard();
    final at = DateTime.utc(2026, 10, 17, 9);
    guard.noteDecline('10.0.0.2', at: at);
    guard.noteDecline('10.0.0.2', at: at.add(const Duration(minutes: 9)));
    guard.noteDecline('10.0.0.2', at: at.add(const Duration(minutes: 11)));
    expect(guard.check('10.0.0.2', at: at.add(const Duration(minutes: 11))), ReceiveDecision.prompt);
  });
}
