import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/received_file_actions.dart';

void main() {
  group('DEV13-D2A safe local file actions', () {
    test('safe passive formats can use Windows default app', () {
      expect(ReceivedFileActions.mayOpenWithSystem('movie.MP4'), isTrue);
      expect(ReceivedFileActions.mayOpenWithSystem('info.pdf'), isTrue);
      expect(ReceivedFileActions.mayOpenWithSystem('report.docx'), isTrue);
      expect(ReceivedFileActions.mayOpenWithSystem('photo.png'), isTrue);
    });
    test('programs, scripts, and extensionless files are blocked', () {
      for (final name in ['installer.exe', 'abc.bat', 'x.ps1', 'x.apk',
          'x.js', 'x.scr', 'x.lnk', 'readme', 'bad.docm']) {
        expect(ReceivedFileActions.mayOpenWithSystem(name), isFalse, reason: name);
      }
    });
    test('invalid names and traversal characters are blocked', () {
      for (final name in ['', '..', 'a/b.txt', r'a\\b.txt',
          'x:bad.txt', 'CON.txt', 'file?.jpg']) {
        expect(() => ReceivedFileActions.validateFileName(name), throwsFormatException,
            reason: name);
      }
      expect(ReceivedFileActions.validateFileName('测试 照片.jpg'), '测试 照片.jpg');
    });
    test('copy preserves bytes without altering original', () async {
      final root = await Directory.systemTemp.createTemp('linyue_d2a_');
      try {
        final srcDir = await Directory('${root.path}${Platform.pathSeparator}received').create();
        final targetDir = await Directory('${root.path}${Platform.pathSeparator}selected').create();
        final source = File('${srcDir.path}${Platform.pathSeparator}sample.bin');
        final data = List<int>.generate(1024 * 1024, (i) => i % 251);
        await source.writeAsBytes(data);
        final result = await ReceivedFileActions.saveCopyToDirectory(source, targetDir);
        expect(await result.readAsBytes(), data);
        expect(await source.readAsBytes(), data);
        print('[DEV13-D2A] STREAM_COPY_PASS');
      } finally {
        await root.delete(recursive: true);
      }
    });
    test('existing target remains untouched and new copy gets suffix', () async {
      final root = await Directory.systemTemp.createTemp('linyue_d2b_');
      try {
        final input = await Directory('${root.path}${Platform.pathSeparator}input').create();
        final target = await Directory('${root.path}${Platform.pathSeparator}target').create();
        final source = File('${input.path}${Platform.pathSeparator}note.txt');
        await source.writeAsString('new file');
        final existing = File('${target.path}${Platform.pathSeparator}note.txt');
        await existing.writeAsString('do not overwrite');
        final result = await ReceivedFileActions.saveCopyToDirectory(source, target);
        expect(result.uri.pathSegments.last, 'note (1).txt');
        expect(await result.readAsString(), 'new file');
        expect(await existing.readAsString(), 'do not overwrite');
        print('[DEV13-D2A] NO_OVERWRITE_PASS');
      } finally {
        await root.delete(recursive: true);
      }
    });
    test('missing source or destination is rejected', () async {
      final root = await Directory.systemTemp.createTemp('linyue_d2c_');
      try {
        final missing = File('${root.path}${Platform.pathSeparator}missing.txt');
        final valid = File('${root.path}${Platform.pathSeparator}valid.txt');
        await valid.writeAsString('abc');
        await expectLater(ReceivedFileActions.saveCopyToDirectory(missing, root), throwsA(isA<FileSystemException>()));
        await expectLater(ReceivedFileActions.saveCopyToDirectory(valid,
          Directory('${root.path}${Platform.pathSeparator}missingdir')),
          throwsA(isA<FileSystemException>()));
      } finally {
        await root.delete(recursive: true);
      }
    });
  });
}
