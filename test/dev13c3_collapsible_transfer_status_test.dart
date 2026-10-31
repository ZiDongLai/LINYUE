import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/transfer_progress.dart';
import 'package:nearlink/ui/collapsible_transfer_status.dart';

TransferProgressInfo sample({
  required String name,
  required String direction,
  TransferProgressPhase phase = TransferProgressPhase.uploading,
  int total = 1024 * 1024,
  int sent = 512 * 1024,
  Duration elapsed = const Duration(seconds: 1),
}) => TransferProgressInfo(
  name: name,
  direction: direction,
  phase: phase,
  totalBytes: total,
  transferredBytes: sent,
  elapsed: elapsed,
);

Widget harness(List<TransferProgressInfo> records, {double width = 1200}) =>
    MaterialApp(home: Scaffold(body: Center(child: SizedBox(
      width: width,
      child: CollapsibleTransferStatus(
        entries: records,
        detailsBuilder: (entry) => Text('详细数据：${entry.name}',
          key: Key('detail-${entry.direction}')),
      ),
    ))));

void main() {
  testWidgets('collapsed by default shows only file name, measured speed and bar', (tester) async {
    await tester.pumpWidget(harness([
      sample(name: 'image.png', direction: 'send'),
    ]));
    expect(find.text('image.png'), findsOneWidget);
    expect(find.text('512.0 KiB/s'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('transfer-status-details')), findsNothing);
    await tester.tap(find.byKey(const Key('transfer-status-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('transfer-status-details')), findsOneWidget);
    expect(find.text('详细数据：image.png'), findsOneWidget);
    await tester.tap(find.byKey(const Key('transfer-status-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('transfer-status-details')), findsNothing);
  });

  testWidgets('send and receive show separate compact rows on mobile width', (tester) async {
    await tester.pumpWidget(harness([
      sample(name: 'very_long_sender_filename_20261018_photo.png', direction: 'send'),
      sample(name: 'mobile-photo.jpg', direction: 'receive', sent: 256 * 1024),
    ], width: 360));
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    expect(find.text('mobile-photo.jpg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed progress stays complete and rate is not called real-time', (tester) async {
    await tester.pumpWidget(harness([
      sample(name: 'done.jpg', direction: 'send',
        phase: TransferProgressPhase.completed,
        total: 1024, sent: 1024),
    ]));
    expect(find.textContaining('已完成'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, 1.0);
  });

  testWidgets('failed transfer visibly says failed and never animates indefinitely', (tester) async {
    await tester.pumpWidget(harness([
      sample(name: 'broken.zip', direction: 'receive',
        phase: TransferProgressPhase.failed, sent: 0, total: 0),
    ]));
    expect(find.text('传输失败'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, 0.0);
  });

  testWidgets('verification is not mislabeled as finished', (tester) async {
    await tester.pumpWidget(harness([
      sample(name: 'waiting.pdf', direction: 'send',
        phase: TransferProgressPhase.verifying, sent: 1024, total: 1024),
    ]));
    expect(find.text('校验中'), findsOneWidget);
    expect(find.textContaining('已完成'), findsNothing);
  });
}
