import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/media_copy_audit.dart';

void main() {
  late Directory root;
  late Directory media;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('linyue_e10_');
    media = Directory('${root.path}${Platform.pathSeparator}LinYuePickedImages');
    await media.create();
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> put(String name, int bytes, {int ageDays = 9}) async {
    final file = File('${media.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(List<int>.filled(bytes, 3), flush: true);
    await file.setLastModified(DateTime.now().subtract(Duration(days: ageDays)));
    return file;
  }

  test('read-only detail lists old unreferenced media and sorts by bytes', () async {
    final small = await put('1234567890123456_100_small.jpg', 4);
    final big = await put('1234567890123456_101_big.mp4', 25);
    final referenced = await put('1234567890123456_102_history.png', 40);
    final recent = await put('1234567890123456_103_new.mp4', 10, ageDays: 1);
    final unknown = await put('personal_media.mp4', 7);
    final result = await MediaCopyAudit.inspect(
      pickedMediaDirectory: media,
      referencedPaths: {referenced.path},
    );
    expect(result.complete, isTrue);
    expect(result.reviewFiles, 2);
    expect(result.reviewBytes, 29);
    expect(result.referencedFiles, 1);
    expect(result.recentFiles, 1);
    expect(result.otherFiles, 1);
    expect(result.reviewDetails.map((e) => e.name),
      ['1234567890123456_101_big.mp4', '1234567890123456_100_small.jpg']);
    expect(result.reviewDetailsTruncated, isFalse);
    for (final file in [small, big, referenced, recent, unknown]) {
      expect(await file.exists(), isTrue);
    }
  });

  test('bounds the detail list, but counts every review candidate', () async {
    for (var i = 0; i < 4; i++) {
      await put('1234567890123456_${200+i}_a.jpg', i + 2);
    }
    final result = await MediaCopyAudit.inspect(
      pickedMediaDirectory: media, referencedPaths: {}, maxDetails: 2);
    expect(result.reviewFiles, 4);
    expect(result.reviewDetails.length, 2);
    expect(result.reviewDetailsTruncated, isTrue);
    expect(result.reviewDetails[0].bytes, 5);
    expect(result.reviewDetails[1].bytes, 4);
    expect((await media.list().length), 4);
  });

  test('scan incomplete suppresses review details and never mutates files', () async {
    final file = await put('1234567890123456_300_temp.png', 11);
    await put('1234567890123456_301_keep.png', 8);
    final report = await MediaCopyAudit.inspect(
      pickedMediaDirectory: media, referencedPaths: {}, maxEntries: 1);
    expect(report.complete, isFalse);
    expect(report.reviewDetails, isEmpty);
    expect(await file.readAsBytes(), List<int>.filled(11, 3));
  });

  test('detail count has safe limits', () async {
    await expectLater(MediaCopyAudit.inspect(
      pickedMediaDirectory: media, referencedPaths: {}, maxDetails: 0),
      throwsArgumentError);
    await expectLater(MediaCopyAudit.inspect(
      pickedMediaDirectory: media, referencedPaths: {}, maxDetails: 101),
      throwsArgumentError);
  });
}
