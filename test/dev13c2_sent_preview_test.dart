import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/transfer_history.dart';
import 'package:nearlink/ui/sent_image_preview_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sent preview is a small independent PNG, persists as a history field', () async {
    final sandbox = await Directory.systemTemp.createTemp('linyue_sent_preview_');
    try {
      final source = File('${sandbox.path}/original.png');
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 16, 16),
          ui.Paint()..color = const ui.Color(0xFF20CCB4));
      final picture = recorder.endRecording();
      final image = await picture.toImage(16, 16);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(bytes, isNotNull);
      await source.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();

      final originalBytes = await source.readAsBytes();
      final cached = await SentImagePreviewStore.createForFile(
        source: source,
        fileName: 'photo.png',
        cacheDirectory: Directory('${sandbox.path}/previews'),
      );
      expect(cached, isNotNull);
      expect(await File(cached!).exists(), isTrue);
      expect(await source.readAsBytes(), originalBytes);
      final transfer = TransferRecord(
        name: 'photo.png', peerName: 'A', direction: 'send',
        status: 'success', bytes: originalBytes.length,
        timestamp: DateTime.utc(2026, 10, 18), thumbnailPath: cached);
      final restored = TransferRecord.fromJson(transfer.toJson());
      expect(restored.thumbnailPath, cached);
      expect(restored.localPath, isNull);
      await SentImagePreviewStore.prune({cached},
          cacheDirectory: Directory('${sandbox.path}/previews'));
      expect(await File(cached).exists(), isTrue);
      await SentImagePreviewStore.prune(<String>{},
          cacheDirectory: Directory('${sandbox.path}/previews'),
          minAge: Duration.zero);
      expect(await File(cached).exists(), isFalse);
      expect(await source.readAsBytes(), originalBytes);
    } finally {
      await sandbox.delete(recursive: true);
    }
  });

  test('non-image uploads never create previews or alter original', () async {
    final sandbox = await Directory.systemTemp.createTemp('linyue_sent_nonimage_');
    try {
      final original = File('${sandbox.path}/doc.txt');
      await original.writeAsString('hello');
      final cached = await SentImagePreviewStore.createForFile(
        source: original, fileName: 'doc.txt',
        cacheDirectory: Directory('${sandbox.path}/previews'),
      );
      expect(cached, isNull);
      expect(await original.readAsString(), 'hello');
    } finally {
      await sandbox.delete(recursive: true);
    }
  });

  test('legacy transfer records without thumbnailPath load unchanged', () {
    final transfer = TransferRecord.fromJson({
      'name': 'photo.png', 'peerName': 'A', 'direction': 'send',
      'status': 'success', 'bytes': 123,
      'timestamp': '2026-10-18T10:00:00.000Z',
      'localPath': null,
    });
    expect(transfer.thumbnailPath, isNull);
  });

  test('prune never deletes unknown files in preview cache', () async {
    final sandbox = await Directory.systemTemp.createTemp('linyue_sent_prune_');
    try {
      final dir = Directory('${sandbox.path}/previews');
      await dir.create();
      final unknown = File('${dir.path}/user_document.txt');
      await unknown.writeAsString('leave this alone');
      await SentImagePreviewStore.prune(<String>{}, cacheDirectory: dir);
      expect(await unknown.readAsString(), 'leave this alone');
    } finally {
      await sandbox.delete(recursive: true);
    }
  });
}
