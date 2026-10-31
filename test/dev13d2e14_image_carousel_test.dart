import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/transfer_history.dart';
import 'package:nearlink/ui/image_carousel_policy.dart';
import 'package:nearlink/ui/received_image_preview.dart';

TransferRecord _record(String name, String peer, DateTime at, {
  String direction = 'receive', String status = 'success',
}) => TransferRecord(
  name: name,
  peerName: peer,
  direction: direction,
  status: status,
  bytes: 1,
  timestamp: at,
  localPath: '/tmp/$name',
);

void main() {
  test('E14 conversation album is chronological and peer-isolated', () {
    final t = DateTime.utc(2026, 10, 20);
    final oldest = _record('older.png', 'Windows A', t);
    final recent = _record('latest.jpg', 'Windows A', t.add(const Duration(seconds: 3)));
    final other = _record('foreign.jpg', 'Windows B', t.add(const Duration(seconds: 4)));
    final failed = _record('failed.jpg', 'Windows A', t, status: 'failed');
    final video = _record('clip.mp4', 'Windows A', t);
    final ordered = ImageCarouselPolicy.forPeer(
      [other, recent, failed, video, oldest], recent);
    expect(ordered, [oldest, recent]);
  });

  test('E14 selected image remains in bounded album', () {
    final t = DateTime.utc(2026, 10, 20);
    final newestFirst = <TransferRecord>[
      for (var i = 99; i >= 0; i--)
        _record('$i.png', 'Windows A', t.add(Duration(minutes: i))),
    ];
    final selected = newestFirst[48];
    final ordered = ImageCarouselPolicy.forPeer(
        newestFirst, selected, maxEntries: 20);
    expect(ordered.length, 20);
    expect(ordered.contains(selected), isTrue);
    expect(ordered.first.name, isNot(ordered.last.name));
  });

  test('E14 refuses failed or non-image selections', () {
    final t = DateTime.utc(2026, 10, 20);
    expect(ImageCarouselPolicy.forPeer([], _record('clip.mp4', 'A', t)), isEmpty);
    expect(ImageCarouselPolicy.forPeer([], _record('no.jpg', 'A', t, status: 'failed')), isEmpty);
  });

  testWidgets('E14 image navigation updates title and current save action', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(MaterialApp(home: ReceivedImagePreviewPage(
      file: File('one.jpg'),
      displayName: 'one.jpg',
      saveLabel: '下载到相册',
      items: [
        ImagePreviewItem(file: File('one.jpg'), displayName: 'one.jpg',
          onSave: () => saved.add('one')),
        ImagePreviewItem(file: File('two.jpg'), displayName: 'two.jpg',
          onSave: () => saved.add('two')),
      ],
    )));
    await tester.pumpAndSettle();
    expect(find.text('one.jpg'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(find.text('two.jpg'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(find.text('下载到相册'));
    expect(saved, ['two']);
    await tester.tap(find.byTooltip('上一张'));
    await tester.pumpAndSettle();
    expect(find.text('one.jpg'), findsOneWidget);
    await tester.tap(find.text('下载到相册'));
    expect(saved, ['two', 'one']);
  });

  testWidgets('E14 sent-thumbnail has no misleading original download', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ReceivedImagePreviewPage(
      file: File('sent.jpg'),
      displayName: 'sent.jpg',
      saveLabel: '下载到相册',
      items: [
        ImagePreviewItem(file: File('sent.jpg'), displayName: 'sent.jpg',
          isSentThumbnail: true),
        ImagePreviewItem(file: File('received.jpg'), displayName: 'received.jpg',
          onSave: () {}),
      ],
    )));
    await tester.pumpAndSettle();
    expect(find.text('下载到相册'), findsNothing);
    expect(find.textContaining('发送记录仅保留缩略图'), findsOneWidget);
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(find.text('下载到相册'), findsOneWidget);
  });
}
