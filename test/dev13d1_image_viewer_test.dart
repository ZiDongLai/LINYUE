import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/ui/received_image_preview.dart';

void main() {
  late Directory temp;
  setUp(() async { temp = await Directory.systemTemp.createTemp('linyue_d1_'); });
  tearDown(() async { if (await temp.exists()) await temp.delete(recursive: true); });

  test('static image available in local storage can be previewed', () async {
    final jpg = File('${temp.path}/test.jpg');
    await jpg.writeAsBytes([1, 2, 3]);
    expect(await mayPreviewLocalImage('test.jpg', jpg.path), isTrue);
    print('[DEV13D1] LOCAL_IMAGE_ALLOWED_PASS');
  });

  test('videos and PDFs never enter image decoder', () async {
    final file = File('${temp.path}/clip.mp4');
    await file.writeAsBytes([1, 2, 3]);
    expect(await mayPreviewLocalImage('clip.mp4', file.path), isFalse);
    expect(await mayPreviewLocalImage('paper.pdf', file.path), isFalse);
    print('[DEV13D1] NON_IMAGE_REJECT_PASS');
  });

  test('missing path fails closed', () async {
    expect(await mayPreviewLocalImage('test.jpg', null), isFalse);
    expect(await mayPreviewLocalImage('test.jpg', '${temp.path}/none.jpg'), isFalse);
    print('[DEV13D1] MISSING_SOURCE_REJECT_PASS');
  });

  test('oversize local image is not decoded', () async {
    final jpg = File('${temp.path}/big.jpg');
    await jpg.writeAsBytes(List<int>.filled(33, 1));
    expect(await mayPreviewLocalImage('big.jpg', jpg.path, maxSourceBytes: 32), isFalse);
    print('[DEV13D1] OVERSIZE_REJECT_PASS');
  });

  testWidgets('image viewer displays controls and sent-thumbnail disclosure', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ReceivedImagePreviewPage(
      file: File('${Directory.systemTemp.path}/not-an-image.jpg'),
      displayName: 'sent.jpg',
      isSentThumbnail: true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('sent.jpg'), findsOneWidget);
    expect(find.textContaining('当前显示缩略图'), findsOneWidget);
    expect(find.byTooltip('放大'), findsOneWidget);
    expect(find.byTooltip('还原'), findsOneWidget);
    expect(find.text('另存图片'), findsNothing);
    print('[DEV13D1] SENT_THUMBNAIL_VIEWER_PASS');
  });

  testWidgets('received-file viewer offers existing save callback', (tester) async {
    var invoked = 0;
    await tester.pumpWidget(MaterialApp(home: ReceivedImagePreviewPage(
      file: File('${Directory.systemTemp.path}/not-an-image.png'),
      displayName: 'received.png',
      onSave: () { invoked++; },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('另存图片'));
    expect(invoked, 1);
    print('[DEV13D1] RECEIVED_SAVE_ACTION_PASS');
  });
}
