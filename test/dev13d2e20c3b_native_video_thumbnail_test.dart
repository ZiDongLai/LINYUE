import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/native_video_frame_thumbnail.dart';
import 'package:nearlink/widgets/conversation_video_thumbnail.dart';

void main() {
  test('actual supported video types, not images or documents', () {
    for (final extension in [
      '.mp4', '.M4V', '.mov', '.mkv', '.webm', '.avi', '.wmv', '.3gp', '.mpeg'
    ]) {
      expect(NativeVideoFrameThumbnail.isVideoPath('test$extension'), isTrue);
    }
    for (final extension in ['.jpg', '.png', '.pdf', '.zip', '.exe']) {
      expect(NativeVideoFrameThumbnail.isVideoPath('test$extension'), isFalse);
    }
    expect(NativeVideoFrameThumbnail.isVideoPath('a.mp4\u0000bad'), isFalse);
    expect(NativeVideoFrameThumbnail.isVideoPath(null), isFalse);
  });

  test('only bounded, nonempty, regular local files are eligible', () async {
    final dir = await Directory.systemTemp.createTemp('linyue_c3b_preview_');
    try {
      final video = File('${dir.path}${Platform.pathSeparator}sample.mp4');
      await video.writeAsBytes(const [0, 1, 2], flush: true);
      expect(NativeVideoFrameThumbnail.eligibleFile(
        path: video.path, stat: await video.stat()), isTrue);
      final empty = File('${dir.path}${Platform.pathSeparator}empty.mp4');
      await empty.create();
      expect(NativeVideoFrameThumbnail.eligibleFile(
        path: empty.path, stat: await empty.stat()), isFalse);
      expect(NativeVideoFrameThumbnail.eligibleFile(
        path: dir.path, stat: await dir.stat()), isFalse);
      expect(await video.readAsBytes(), [0, 1, 2]); // no mutation
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('real encoded image signature and size validated', () {
    expect(NativeVideoFrameThumbnail.isValidPreview(
      Uint8List.fromList([0xff, 0xd8, 0xff, 0x00])), isTrue);
    expect(NativeVideoFrameThumbnail.isValidPreview(
      Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10, 0])), isTrue);
    expect(NativeVideoFrameThumbnail.isValidPreview(
      Uint8List.fromList([1, 2, 3, 4])), isFalse);
    expect(NativeVideoFrameThumbnail.isValidPreview(null), isFalse);
    expect(NativeVideoFrameThumbnail.isValidPreview(
      Uint8List(NativeVideoFrameThumbnail.maxPreviewBytes + 1)), isFalse);
  });

  testWidgets('missing video shows a placeholder without media mutation', (tester) async {
    NativeVideoFrameThumbnail.resetMemoryCacheForTest();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ConversationVideoThumbnail(
        path: '/missing/video.mp4', width: 200, height: 130,
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.movie_creation_outlined), findsOneWidget);
  });
}
