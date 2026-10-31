import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/ui/file_visual_badge.dart';

void main() {
  test('DEV13C1: image variants classified without case sensitivity', () {
    for (final name in ['a.PNG', 'report.JpEg', 'p.webp', 'p.heic']) {
      expect(fileKindFromName(name), FileVisualKind.image);
    }
    expect(fileKindFromName('photo.jpg.exe'), FileVisualKind.installer);
    expect(supportsInlineThumbnail('x.PNG'), isTrue);
    expect(supportsInlineThumbnail('x.gif'), isFalse);
    print('[DEV13C1] IMAGE_EXTENSION_PASS');
  });
  test('DEV13C1: common video/audio/document formats get types', () {
    expect(fileKindFromName('demo.mp4'), FileVisualKind.video);
    expect(fileKindFromName('song.flac'), FileVisualKind.audio);
    expect(fileKindFromName('manual.PDF'), FileVisualKind.pdf);
    expect(fileKindFromName('word.docx'), FileVisualKind.document);
    expect(fileKindFromName('sheet.XLSX'), FileVisualKind.spreadsheet);
    expect(fileKindFromName('slides.pptx'), FileVisualKind.slides);
    expect(fileKindFromName('files.zip'), FileVisualKind.archive);
    expect(fileKindFromName('app.apk'), FileVisualKind.installer);
    print('[DEV13C1] FILE_KIND_PASS');
  });
  test('DEV13C1: names with no extension get generic fallback', () {
    expect(fileKindFromName('README'), FileVisualKind.other);
    expect(fileKindFromName('.env'), FileVisualKind.other);
    expect(fileKindFromName('abc.'), FileVisualKind.other);
    expect(fileKindFromName(r'C:\photos\view.JPG'), FileVisualKind.image);
    expect(labelForFileVisualKind(FileVisualKind.other), '文件');
    print('[DEV13C1] SAFE_EXTENSION_FALLBACK_PASS');
  });
  test('DEV13C1: missing and empty paths never show thumbnails', () async {
    expect(await mayLoadImageThumbnail(null), isFalse);
    expect(await mayLoadImageThumbnail(''), isFalse);
    expect(await mayLoadImageThumbnail('__missing_dev13c1__.png'), isFalse);
    print('[DEV13C1] MISSING_FILE_FALLBACK_PASS');
  });
  test('DEV13C1: only size-limited local ordinary files are eligible', () async {
    final dir = await Directory.systemTemp.createTemp('dev13c1_');
    try {
      final file = File('${dir.path}${Platform.pathSeparator}a.png');
      await file.writeAsBytes([137, 80, 78, 71]);
      expect(await mayLoadImageThumbnail(file.path), isTrue);
      expect(await mayLoadImageThumbnail(file.path, maxSourceBytes: 3), isFalse);
      expect(await mayLoadImageThumbnail(dir.path), isFalse);
      print('[DEV13C1] SIZE_GUARD_PASS');
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('DEV13C1: zero-byte placeholder must never be decoded', () async {
    final dir = await Directory.systemTemp.createTemp('dev13c1_empty_');
    try {
      final file = File('${dir.path}${Platform.pathSeparator}empty.jpg');
      await file.writeAsBytes([]);
      expect(await mayLoadImageThumbnail(file.path), isFalse);
      print('[DEV13C1] EMPTY_IMAGE_GUARD_PASS');
    } finally {
      await dir.delete(recursive: true);
    }
  });
  testWidgets('DEV13C1: other formats render a type icon without a file', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileVisualBadge(fileName: 'video.mp4', size: 36)),
    ));
    expect(find.byType(FileVisualBadge), findsOneWidget);
  });
}
