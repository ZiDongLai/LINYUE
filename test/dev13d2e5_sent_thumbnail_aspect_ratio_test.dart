import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/ui/sent_image_preview_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<int>> makePng(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF28BFB5),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final result = data!.buffer.asUint8List(
      data.offsetInBytes, data.lengthInBytes,
    );
    image.dispose();
    picture.dispose();
    return result;
  }

  Future<(int, int)> dimensionsOf(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final result = (frame.image.width, frame.image.height);
      frame.image.dispose();
      return result;
    } finally {
      codec.dispose();
    }
  }

  test('landscape thumbnail keeps its original aspect ratio', () async {
    final root = await Directory.systemTemp.createTemp('linyue_d2e5_landscape_');
    try {
      final source = File('${root.path}/landscape.png');
      await source.writeAsBytes(await makePng(400, 200));
      final original = await source.readAsBytes();

      final path = await SentImagePreviewStore.createForFile(
        source: source,
        fileName: 'landscape.png',
        cacheDirectory: Directory('${root.path}/thumbs'),
      );

      expect(path, isNotNull);
      expect(await dimensionsOf(await File(path!).readAsBytes()), (256, 128));
      expect(await source.readAsBytes(), original);
      print('[DEV13D2E5] LANDSCAPE_ASPECT_RATIO_PASS');
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('portrait thumbnail keeps its original aspect ratio', () async {
    final root = await Directory.systemTemp.createTemp('linyue_d2e5_portrait_');
    try {
      final source = File('${root.path}/portrait.png');
      await source.writeAsBytes(await makePng(200, 400));

      final path = await SentImagePreviewStore.createForFile(
        source: source,
        fileName: 'portrait.png',
        cacheDirectory: Directory('${root.path}/thumbs'),
      );

      expect(path, isNotNull);
      expect(await dimensionsOf(await File(path!).readAsBytes()), (128, 256));
      print('[DEV13D2E5] PORTRAIT_ASPECT_RATIO_PASS');
    } finally {
      await root.delete(recursive: true);
    }
  });
}
