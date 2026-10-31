import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/android_received_open.dart';
import 'package:nearlink/services/android_received_share.dart';
import 'package:nearlink/services/received_file_actions.dart';
import 'package:open_filex/open_filex.dart';

// Model a resolved link without requiring Windows symlink-creation privileges.
// All canonical targets and receive roots remain real disposable test files.
class _FileAlias implements File {
  _FileAlias(this.path, this.target);

  @override
  final String path;
  final File target;

  @override
  Uri get uri => File(path).uri;

  @override
  Future<bool> exists() => target.exists();

  @override
  Future<String> resolveSymbolicLinks() => target.resolveSymbolicLinks();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InaccessibleFile extends _FileAlias {
  _InaccessibleFile(super.path, super.target);

  @override
  Future<bool> exists() async =>
      throw FileSystemException('Access denied', path);
}

void main() {
  const documents = <String, String>{
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'csv': 'text/csv',
    'txt': 'text/plain',
  };

  for (final entry in documents.entries) {
    test(
      '${entry.key} uses its document MIME with case-insensitive extension',
      () {
        for (final extension in [entry.key, entry.key.toUpperCase()]) {
          expect(
            AndroidReceivedOpen.documentMimeType('已接收 文档.$extension'),
            entry.value,
          );
        }
      },
    );
  }

  test(
    'media and unknown extensions retain existing plugin MIME resolution',
    () {
      for (final name in [
        'photo.PNG',
        'music.mp3',
        'video.mp4',
        'file.custom',
        'database',
      ]) {
        expect(
          AndroidReceivedOpen.documentMimeType(name),
          isNull,
          reason: name,
        );
        expect(AndroidReceivedOpen.isSupportedName(name), isTrue, reason: name);
      }
    },
  );

  test('restricted names and invalid paths never acquire a document MIME', () {
    for (final name in [
      'run.APK',
      'run.EXE',
      'run.BAT',
      'run.SH',
      'run.ps1',
      'macro.docm',
      'macro.xlsm',
      'macro.pptm',
      '../report.pdf',
      r'a\report.pdf',
      '',
    ]) {
      expect(AndroidReceivedOpen.documentMimeType(name), isNull, reason: name);
      expect(AndroidReceivedOpen.isSupportedName(name), isFalse, reason: name);
    }
  });

  test('open restrictions do not restrict the independent sharing action', () {
    for (final name in ['installer.apk', 'script.sh', 'run.exe']) {
      expect(AndroidReceivedOpen.isSupportedName(name), isFalse);
      expect(AndroidReceivedShare.isSupportedName(name), isTrue);
    }
    expect(ReceivedFileActions.mayOpenWithSystem('file.custom'), isFalse);
    expect(ReceivedFileActions.mayOpenWithSystem('photo.PNG'), isTrue);
  });

  test('missing file and missing receive directory fail closed', () async {
    final root = await Directory.systemTemp.createTemp('linyue_open_missing_');
    try {
      final file = File('${root.path}/gone.pdf');
      await expectLater(
        AndroidReceivedOpen.validateFile(file: file, receiveDirectory: root),
        throwsA(isA<FileSystemException>()),
      );
      await file.writeAsBytes([1]);
      await expectLater(
        AndroidReceivedOpen.validateFile(
          file: file,
          receiveDirectory: Directory('${root.path}/missing'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsBytes(), [1]);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    'unreadable file errors remain catchable and leave the source unchanged',
    () async {
      final root = await Directory.systemTemp.createTemp('linyue_open_access_');
      try {
        final target = await File(
          '${root.path}/report.pdf',
        ).writeAsBytes([1, 2]);
        await expectLater(
          AndroidReceivedOpen.validateFile(
            file: _InaccessibleFile(target.path, target),
            receiveDirectory: root,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await target.readAsBytes(), [1, 2]);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'directories and nested receive files are not exposed as completed files',
    () async {
      final root = await Directory.systemTemp.createTemp('linyue_open_nested_');
      try {
        final nested = await Directory('${root.path}/nested.pdf').create();
        await expectLater(
          AndroidReceivedOpen.validateFile(
            file: File(nested.path),
            receiveDirectory: root,
          ),
          throwsA(isA<FileSystemException>()),
        );
        final part = await File('${nested.path}/report.pdf').writeAsBytes([1]);
        await expectLater(
          AndroidReceivedOpen.validateFile(file: part, receiveDirectory: root),
          throwsA(isA<StateError>()),
        );
        expect(await part.readAsBytes(), [1]);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('a resolved alias outside the receive root is rejected', () async {
    final parent = await Directory.systemTemp.createTemp('linyue_open_escape_');
    try {
      final root = await Directory('${parent.path}/received').create();
      final target = await File('${parent.path}/outside.pdf').writeAsBytes([1]);
      await expectLater(
        AndroidReceivedOpen.validateFile(
          file: _FileAlias('${root.path}/safe.pdf', target),
          receiveDirectory: root,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await target.readAsBytes(), [1]);
    } finally {
      await parent.delete(recursive: true);
    }
  });

  test(
    'safe-looking alias cannot open a canonical executable in the receive root',
    () async {
      final root = await Directory.systemTemp.createTemp('linyue_open_alias_');
      try {
        final executable = await File(
          '${root.path}/installer.apk',
        ).writeAsBytes([1, 2, 3]);
        final alias = _FileAlias('${root.path}/report.pdf', executable);
        await expectLater(
          AndroidReceivedOpen.validateFile(file: alias, receiveDirectory: root),
          throwsA(isA<StateError>()),
        );
        expect(await executable.readAsBytes(), [1, 2, 3]);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'current plugin error results remain distinct for the existing UI handlers',
    () {
      const expected = <int, ResultType>{
        0: ResultType.done,
        -1: ResultType.noAppToOpen,
        -2: ResultType.fileNotFound,
        -3: ResultType.permissionDenied,
        -4: ResultType.error,
      };
      for (final entry in expected.entries) {
        final result = OpenResult.fromJson({
          'type': entry.key,
          'message': 'test result',
        });
        expect(result.type, entry.value);
        expect(result.message, 'test result');
      }
    },
  );

  test(
    'non-Android host cannot launch a received file through this adapter',
    () async {
      final root = await Directory.systemTemp.createTemp('linyue_open_host_');
      try {
        final file = await File('${root.path}/safe.pdf').writeAsBytes([1]);
        await expectLater(
          AndroidReceivedOpen.openFile(file: file, receiveDirectory: root),
          throwsA(isA<UnsupportedError>()),
        );
        expect(await file.readAsBytes(), [1]);
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: Platform.isAndroid ? 'Checks the non-Android guard.' : false,
  );
}
