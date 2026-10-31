import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/media_copy_audit.dart';

void main() {
  late Directory root;
  late Directory picked;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('linyue_e9_');
    picked = Directory('${root.path}${Platform.pathSeparator}LinYuePickedImages');
    await picked.create();
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> make(String name, {int bytes = 9, int daysOld = 10}) async {
    final f = File('${picked.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(List<int>.filled(bytes, 6));
    await f.setLastModified(DateTime.now().subtract(Duration(days: daysOld)));
    return f;
  }

  test('audit is read-only and never deletes original media', () async {
    final keep = await make('1234567890123456_123456_photo.jpg');
    final older = await make('1234567890123457_123457_movie.mp4', bytes: 14);
    final recent = await make('1234567890123458_123458_recent.jpg', daysOld: 1);
    final unknown = await make('personal.jpg');
    final report = await MediaCopyAudit.inspect(
      pickedMediaDirectory: picked, referencedPaths: {keep.path});
    expect(report.complete, isTrue);
    expect(report.totalFiles, 4);
    expect(report.referencedFiles, 1);
    expect(report.reviewFiles, 1);
    expect(report.reviewBytes, 14);
    expect(report.recentFiles, 1);
    expect(report.otherFiles, 1);
    for (final f in [keep, older, recent, unknown]) {
      expect(await f.exists(), isTrue);
    }
  });

  test('does not follow symlinks or pretend to have a complete scan', () async {
    if (Platform.isWindows) return;
    final external = await Directory.systemTemp.createTemp('linyue_e9_external_');
    try {
      await File('${external.path}${Platform.pathSeparator}secret.jpg').writeAsBytes([1]);
      await Link('${picked.path}${Platform.pathSeparator}linked').create(external.path);
      final result = await MediaCopyAudit.inspect(
          pickedMediaDirectory: picked, referencedPaths: {});
      expect(result.complete, isFalse);
      expect(result.totalFiles, 0);
      expect(await File('${external.path}${Platform.pathSeparator}secret.jpg').exists(), isTrue);
    } finally {
      await external.delete(recursive: true);
    }
  });

  test('refuses short review age and reports scan limit', () async {
    await make('1234567890123456_123456_foo.png');
    await make('1234567890123457_123457_bar.png');
    await expectLater(
      MediaCopyAudit.inspect(pickedMediaDirectory: picked,
        referencedPaths: {}, minimumAge: const Duration(hours: 1)),
      throwsArgumentError,
    );
    final report = await MediaCopyAudit.inspect(pickedMediaDirectory: picked,
        referencedPaths: {}, maxEntries: 1);
    expect(report.complete, isFalse);
    expect(report.reviewFiles, 1);
    expect((await picked.list().length), 2);
  });

  test('unknown or symlinked root is never treated as safe', () async {
    final linkPath = '${root.path}${Platform.pathSeparator}picked_link';
    if (!Platform.isWindows) {
      await Link(linkPath).create(picked.path);
      final report = await MediaCopyAudit.inspect(
        pickedMediaDirectory: Directory(linkPath), referencedPaths: {});
      expect(report.complete, isFalse);
    }
    final missing = Directory('${root.path}${Platform.pathSeparator}absent');
    final report = await MediaCopyAudit.inspect(
      pickedMediaDirectory: missing, referencedPaths: {});
    expect(report.complete, isTrue);
    expect(report.totalFiles, 0);
  });
}
