import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/mobile_media_source_policy.dart';

void main() {
  group('DEV13D2E7 received media album policy', () {
    test('recognizes photos and videos regardless of extension case', () {
      for (final name in ['photo.JPG', 'photo.HEIC', 'frame.png']) {
        expect(MobileMediaSourcePolicy.isImageName(name), isTrue, reason: name);
        expect(MobileMediaSourcePolicy.isVideoName(name), isFalse, reason: name);
      }
      for (final name in ['movie.MP4', 'clip.mov', 'film.webm', 'edit.mkv']) {
        expect(MobileMediaSourcePolicy.isVideoName(name), isTrue, reason: name);
        expect(MobileMediaSourcePolicy.isImageName(name), isFalse, reason: name);
      }
    });

    test('unsupported documents and executable files are not auto-archived', () {
      for (final name in ['notes.txt', 'contract.pdf', 'backup.zip', 'app.apk', 'run.sh', 'fake.mp4.exe']) {
        expect(MobileMediaSourcePolicy.isSupportedMediaName(name), isFalse,
            reason: name);
      }
    });

    test('both verified and legacy receive callbacks call media archiver', () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(source.contains('Future<void> _autoArchiveReceivedMedia(File file)'),
          isTrue);
      expect(RegExp(r'unawaited\(_autoArchiveReceivedMedia\(file\)\)')
          .allMatches(source).length, 2);
      expect(source.contains("'archiveReceivedMedia'"), isTrue);
      expect(source.contains('MobileMediaSourcePolicy.isVideoName(name)'),
          isTrue);
    });

    test('Android MediaStore uses separate image/video collections and rollback', () {
      final native = File('android/app/src/main/kotlin/com/nearlink/nearlink/MainActivity.kt')
          .readAsStringSync();
      expect(native.contains('"archiveReceivedMedia" ->'), isTrue);
      expect(native.contains('MediaStore.Video.Media.EXTERNAL_CONTENT_URI'), isTrue);
      expect(native.contains('MediaStore.Images.Media.EXTERNAL_CONTENT_URI'), isTrue);
      expect(native.contains('Environment.DIRECTORY_MOVIES'), isTrue);
      expect(native.contains('Environment.DIRECTORY_PICTURES'), isTrue);
      expect(native.contains('source.parentFile != allowed'), isTrue);
      expect(native.contains('count != countExpected'), isTrue);
      expect(native.contains('contentResolver.delete(it, null, null)'), isTrue);
    });
  });
}
