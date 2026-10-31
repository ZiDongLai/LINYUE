import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/mobile_media_source_policy.dart';

void main() {
  group('DEV13D2E6 FIX2 gallery images and videos', () {
    late Directory root;
    late Directory staging;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('linyue_gallery_video_');
      staging = Directory('${root.path}${Platform.pathSeparator}staging');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('supports common gallery video and photo extensions', () {
      expect(MobileMediaSourcePolicy.isSupportedMediaName('a.JPG'), isTrue);
      expect(MobileMediaSourcePolicy.isSupportedMediaName('a.MP4'), isTrue);
      expect(MobileMediaSourcePolicy.isSupportedMediaName('b.mov'), isTrue);
      expect(MobileMediaSourcePolicy.isSupportedMediaName('c.webm'), isTrue);
      expect(MobileMediaSourcePolicy.isVideoName('clip.mp4'), isTrue);
      expect(MobileMediaSourcePolicy.isImageName('clip.mp4'), isFalse);
      expect(MobileMediaSourcePolicy.isSupportedMediaName('run.apk'), isFalse);
      expect(MobileMediaSourcePolicy.isSupportedMediaName('script.sh'), isFalse);
    });

    test('stages MP4 bytes unchanged and leaves original intact', () async {
      final src = File('${root.path}${Platform.pathSeparator}clip.MP4');
      final bytes = <int>[0, 1, 0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70];
      await src.writeAsBytes(bytes, flush: true);
      final copy = await MobileMediaSourcePolicy.stageFile(
        source: src, stagingRoot: staging, displayName: 'clip.MP4');
      expect(await copy.readAsBytes(), bytes);
      expect(await src.readAsBytes(), bytes);
      expect(copy.path, contains('clip.MP4'));
    });

    test('photo and video are staged independently without collisions', () async {
      final image = File('${root.path}${Platform.pathSeparator}a.jpg');
      final video = File('${root.path}${Platform.pathSeparator}a.mp4');
      await image.writeAsBytes([1, 2, 3]);
      await video.writeAsBytes([4, 5, 6]);
      final first = await MobileMediaSourcePolicy.stageFile(
        source: image, stagingRoot: staging, displayName: 'a.jpg');
      final second = await MobileMediaSourcePolicy.stageFile(
        source: video, stagingRoot: staging, displayName: 'a.mp4');
      expect(first.path, isNot(second.path));
      expect(await first.readAsBytes(), [1, 2, 3]);
      expect(await second.readAsBytes(), [4, 5, 6]);
    });

    test('video over size limit fails without partial staging', () async {
      final source = File('${root.path}${Platform.pathSeparator}large.mp4');
      await source.writeAsBytes([1, 2, 3, 4, 5]);
      await expectLater(MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: staging, displayName: 'large.mp4',
        maximumFileBytes: 4), throwsA(isA<StateError>()));
      expect(await staging.exists(), isFalse);
    });

    test('unsafe and non-media extensions are rejected', () async {
      final src = File('${root.path}${Platform.pathSeparator}evil.apk');
      await src.writeAsBytes([1, 2, 3]);
      await expectLater(MobileMediaSourcePolicy.stageFile(
        source: src, stagingRoot: staging, displayName: 'evil.apk'),
        throwsA(isA<FormatException>()));
      expect(MobileMediaSourcePolicy.safeName('bad\\folder.mp4'), 'folder.mp4');
    });
  });
}
