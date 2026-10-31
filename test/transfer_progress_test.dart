import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/transfer_progress.dart';

void main() {
  test('counter clamps and percentage never exceeds file size', () {
    final p = TransferProgressInfo(name: 'a.bin', direction: 'send',
      phase: TransferProgressPhase.uploading,
      totalBytes: 100, transferredBytes: 147,
      elapsed: const Duration(seconds: 2));
    expect(p.safeBytes, 100);
    expect(p.percent, 100);
    expect(p.fraction, 1.0);
    expect(p.eta, isNull);
  });

  test('known elapsed yields measured average speed and estimated time', () {
    final p = TransferProgressInfo(name: 'a.bin', direction: 'send',
      phase: TransferProgressPhase.uploading,
      totalBytes: 1000, transferredBytes: 250,
      elapsed: const Duration(milliseconds: 500));
    expect(p.percent, 25);
    expect(p.speedBytesPerSecond, 500);
    expect(p.eta, const Duration(milliseconds: 1500));
  });

  test('zero bytes and pre-transfer stage do not fabricate progress', () {
    final p = TransferProgressInfo(name: 'empty', direction: 'receive',
      phase: TransferProgressPhase.awaitingApproval,
      totalBytes: 0, transferredBytes: 0, elapsed: Duration.zero);
    expect(p.percent, isNull);
    expect(p.speedBytesPerSecond, isNull);
    expect(p.eta, isNull);
    expect(p.isBytePhase, isFalse);
  });

  test('waiting for authenticated receipt is distinct from completion', () {
    final p = TransferProgressInfo(name: 'photo', direction: 'send',
      phase: TransferProgressPhase.verifying,
      totalBytes: 1000, transferredBytes: 1000,
      elapsed: const Duration(seconds: 1));
    expect(p.phaseLabel, contains('回执'));
    expect(p.isBytePhase, isFalse);
    expect(p.phase, isNot(TransferProgressPhase.completed));
  });
}
