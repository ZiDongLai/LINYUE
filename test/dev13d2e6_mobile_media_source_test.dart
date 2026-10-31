import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/mobile_media_source_policy.dart';

void main() {
  group('DEV13D2E6 safe picked-media staging', () {
    late Directory root;
    late Directory staging;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('linyue_dev13d2e6_');
      staging = Directory('${root.path}${Platform.pathSeparator}staging');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('copies bytes unchanged and preserves the source file', () async {
      final source = File('${root.path}${Platform.pathSeparator}photo.PNG');
      await source.writeAsBytes(<int>[0, 255, 1, 2, 42], flush: true);
      final copy = await MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: staging, displayName: 'photo.PNG');
      expect(await copy.readAsBytes(), await source.readAsBytes());
      expect(await source.exists(), isTrue);
      expect(copy.path, contains('photo.PNG'));
    });

    test('unique copies never overwrite an existing selected photo', () async {
      final source = File('${root.path}${Platform.pathSeparator}photo.jpg');
      await source.writeAsBytes(<int>[1, 2, 3], flush: true);
      final first = await MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: staging, displayName: 'photo.jpg');
      final second = await MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: staging, displayName: 'photo.jpg');
      expect(first.path, isNot(second.path));
      expect(await first.readAsBytes(), <int>[1, 2, 3]);
      expect(await second.readAsBytes(), <int>[1, 2, 3]);
    });

    test('unsupported extension, missing and oversize files fail closed', () async {
      final source = File('${root.path}${Platform.pathSeparator}photo.jpg');
      await source.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      expect(MobileMediaSourcePolicy.isImageName('evil.apk'), isFalse);
      expect(MobileMediaSourcePolicy.isImageName('a.heic'), isTrue);
      await expectLater(MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: staging, displayName: 'photo.exe'),
        throwsA(isA<FormatException>()));
      await expectLater(MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: staging, displayName: 'photo.jpg', maximumFileBytes: 3),
        throwsA(isA<StateError>()));
      expect(await staging.exists(), isFalse);
    });

    test('removes dangerous path separators from picked filenames', () {
      expect(MobileMediaSourcePolicy.safeName('../test.png'), 'test.png');
      expect(MobileMediaSourcePolicy.safeName('folder\\test.png'), 'test.png');
    });
  });
}
