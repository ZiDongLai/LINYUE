import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/local_storage_overview.dart';

void main() {
  late Directory sandbox;
  late Directory support;
  late Directory received;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('linyue_e8_');
    support = Directory('${sandbox.path}${Platform.pathSeparator}support');
    received = Directory('${sandbox.path}${Platform.pathSeparator}received');
    await support.create();
    await received.create();
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('counts separate local original and private cache copies, not public album', () async {
    await File('${received.path}${Platform.pathSeparator}image.png')
        .writeAsBytes(List<int>.filled(13, 1));
    final picked = Directory('${support.path}${Platform.pathSeparator}LinYuePickedImages');
    await picked.create();
    await File('${picked.path}${Platform.pathSeparator}photo.mp4')
        .writeAsBytes(List<int>.filled(7, 2));
    final shot = await LocalStorageOverview.inspect(
        receivedDirectory: received, supportDirectory: support);
    expect(shot.buckets.length, 4);
    expect(shot.measuredBytes, 20);
    expect(shot.complete, isTrue);
    expect(shot.buckets[0].fileCount, 1);
    expect(shot.buckets[1].fileCount, 1);
  });

  test('never follows a symlink outside the app folder during accounting', () async {
    if (Platform.isWindows) return;
    final outside = Directory('${sandbox.path}${Platform.pathSeparator}outside');
    await outside.create();
    await File('${outside.path}${Platform.pathSeparator}secret.jpg')
        .writeAsBytes(List<int>.filled(90, 4));
    await Link('${received.path}${Platform.pathSeparator}linked')
        .create(outside.path);
    final report = await LocalStorageOverview.inspect(
        receivedDirectory: received, supportDirectory: support);
    expect(report.measuredBytes, 0);
    expect(report.complete, isFalse);
  });

  test('only stale orphan generated thumbnails are removed', () async {
    final thumb = Directory('${support.path}${Platform.pathSeparator}linyue_sent_thumbnails_v1');
    await thumb.create();
    Future<File> create(String name) async {
      final f = File('${thumb.path}${Platform.pathSeparator}$name');
      await f.writeAsBytes(List<int>.filled(8, 5));
      await f.setLastModified(DateTime.now().subtract(const Duration(days: 3)));
      return f;
    }
    final referenced = await create('sent_thumb_100_200.png');
    final orphan = await create('sent_thumb_101_201.png');
    final unrecognized = await create('userphoto.png');
    final newThumb = await create('sent_thumb_102_202.png');
    await newThumb.setLastModified(DateTime.now());
    final report = await LocalStorageOverview.pruneOrphanThumbnails(
        thumbnailDirectory: thumb, retainedPaths: {referenced.path});
    expect(report.filesDeleted, 1);
    expect(report.bytesFreed, 8);
    expect(await orphan.exists(), isFalse);
    expect(await referenced.exists(), isTrue);
    expect(await unrecognized.exists(), isTrue);
    expect(await newThumb.exists(), isTrue);
  });

  test('never permits a grace period below 24 hours', () async {
    final thumb = Directory('${support.path}${Platform.pathSeparator}linyue_sent_thumbnails_v1');
    await thumb.create();
    await expectLater(
      LocalStorageOverview.pruneOrphanThumbnails(
        thumbnailDirectory: thumb,
        retainedPaths: {},
        minimumAge: Duration.zero,
      ),
      throwsArgumentError,
    );
  });

  test('refuses symlink cache root and incomplete candidate scan', () async {
    final outside = Directory('${sandbox.path}${Platform.pathSeparator}outside');
    await outside.create();
    final outsideOriginal = File('${outside.path}${Platform.pathSeparator}sent_thumb_1_2.png');
    await outsideOriginal.writeAsBytes([1, 2, 3]);
    if (!Platform.isWindows) {
      final link = Link('${support.path}${Platform.pathSeparator}linyue_sent_thumbnails_v1');
      await link.create(outside.path);
      await expectLater(
        LocalStorageOverview.pruneOrphanThumbnails(
            thumbnailDirectory: Directory(link.path), retainedPaths: {}),
        throwsStateError,
      );
      expect(await outsideOriginal.exists(), isTrue);
    }
    final thumb = Directory('${support.path}${Platform.pathSeparator}safe_thumbnails');
    await thumb.create();
    for (var i = 0; i < 3; i++) {
      final file = File('${thumb.path}${Platform.pathSeparator}sent_thumb_200_$i.png');
      await file.writeAsBytes([1]);
      await file.setLastModified(DateTime.now().subtract(const Duration(days: 2)));
    }
    await expectLater(
      LocalStorageOverview.pruneOrphanThumbnails(
          thumbnailDirectory: thumb, retainedPaths: {}, maxEntries: 2),
      throwsStateError,
    );
    expect((await thumb.list().length), 3);
  });
}
