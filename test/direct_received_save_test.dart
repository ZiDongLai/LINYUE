import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/quick_received_save.dart';
import 'package:nearlink/services/received_file_actions.dart';

class _ReadFailure implements File {
  _ReadFailure(this.file);
  final File file;
  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  File get absolute => this;
  @override
  Future<FileStat> stat() => file.stat();
  @override
  Future<int> length() => file.length();
  @override
  Stream<List<int>> openRead([int? start, int? end]) => Stream.error(
    FileSystemException(
      'No space left on device / write failed',
      path,
      const OSError('disk full', 28),
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nearlink/files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory inbox;
  late Directory downloads;
  late QuickReceivedSaveIndex index;
  final calls = <MethodCall>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linyue_direct_save_');
    inbox = await Directory('${root.path}/received').create();
    downloads = await Directory('${root.path}/Downloads').create();
    index = QuickReceivedSaveIndex(File('${root.path}/save-index.json'));
    calls.clear();
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });
  Future<File> source(String name) =>
      File('${inbox.path}/$name').writeAsBytes([1, 2, 3]);

  for (final item in <String, String>{
    '照片.JPG': 'picture',
    '电影.MP4': 'video',
    '报告.pdf': 'document',
  }.entries) {
    test(
      '${item.value} selects the existing Android target and names its success',
      () async {
        final file = await source(item.key);
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return 'saved:content://media/external/${item.value}/1';
        });
        final result = await AndroidQuickReceivedSave.save(file, inbox);
        expect(calls, hasLength(1));
        expect(
          calls.single.method,
          item.value == 'document'
              ? 'quickSaveReceivedDocument'
              : 'archiveReceivedMedia',
        );
        expect(
          (calls.single.arguments as Map)['path'],
          await file.resolveSymbolicLinks(),
        );
        expect(result.category, item.value);
        expect(result.message, contains(item.key));
        expect(
          result.message,
          contains(item.value == 'document' ? '下载/LinYue' : '系统相册'),
        );
        expect(await file.readAsBytes(), [1, 2, 3]);
      },
    );
  }

  test(
    'all ordinary document suffixes use public Downloads, never the share/open channel',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'saved:content://media/external/downloads/1';
      });
      for (final suffix in [
        'PDF',
        'doc',
        'DOCX',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
        'csv',
        'txt',
        'zip',
        'custom',
      ]) {
        final file = await source('document.$suffix');
        final result = await AndroidQuickReceivedSave.save(file, inbox);
        expect(calls.last.method, 'quickSaveReceivedDocument');
        expect(result.category, 'document');
      }
    },
  );

  test(
    'missing and incomplete files are refused before native storage is called',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'saved:content://media/1';
      });
      await expectLater(
        AndroidQuickReceivedSave.save(File('${inbox.path}/missing.pdf'), inbox),
        throwsA(isA<FileSystemException>()),
      );
      for (final name in ['.linyue_part_1234', 'report.pdf.part.1234']) {
        final file = await source(name);
        await expectLater(
          AndroidQuickReceivedSave.save(file, inbox),
          throwsA(isA<FileSystemException>()),
        );
        expect(await file.readAsBytes(), [1, 2, 3]);
      }
      expect(calls, isEmpty);
      expect(
        QuickReceivedSavePolicy.availableForRecord(
          direction: 'receive',
          status: 'receiving',
          localPath: '${inbox.path}/x',
        ),
        isFalse,
      );
      expect(
        QuickReceivedSavePolicy.availableForRecord(
          direction: 'receive',
          status: 'failed',
          localPath: '${inbox.path}/x',
        ),
        isFalse,
      );
    },
  );

  test(
    'outside and nested files cannot escape the active inbox boundary',
    () async {
      final outside = await File('${root.path}/outside.pdf').writeAsBytes([1]);
      final nested = await Directory('${inbox.path}/nested').create();
      final child = await File('${nested.path}/file.pdf').writeAsBytes([1]);
      for (final file in [outside, child]) {
        await expectLater(
          QuickReceivedSavePolicy.validateSource(file, inbox),
          throwsA(isA<FileSystemException>()),
        );
        expect(await file.readAsBytes(), [1]);
      }
    },
  );

  test('invalid/internal names and directory objects are refused', () async {
    for (final name in [
      '',
      '.',
      '..',
      '../a.pdf',
      r'a\b.pdf',
      'a\u0000.pdf',
      '.linyue_part_x',
      'x.part.y',
    ]) {
      expect(
        QuickReceivedSavePolicy.isCompletedName(name),
        isFalse,
        reason: name,
      );
    }
    final folder = await Directory('${inbox.path}/folder.pdf').create();
    await expectLater(
      QuickReceivedSavePolicy.validateSource(File(folder.path), inbox),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'repeat taps join one pending save; next tap revalidates an existing receipt',
    () async {
      final file = await source('report.pdf');
      final result = Completer<String>();
      final called = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        called.complete();
        return result.future;
      });
      final first = AndroidQuickReceivedSave.save(file, inbox);
      final second = AndroidQuickReceivedSave.save(file, inbox);
      await called.future;
      expect(calls, hasLength(1));
      result.complete('saved:content://media/external/downloads/1');
      expect((await first).existing, isFalse);
      expect((await second).existing, isFalse);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'existing:content://media/external/downloads/1';
      });
      final repeated = await AndroidQuickReceivedSave.save(file, inbox);
      expect(calls, hasLength(2));
      expect(repeated.existing, isTrue);
      expect(repeated.message, contains('无需重复下载'));
    },
  );

  for (final code in ['NO_SPACE', 'PERMISSION_DENIED', 'QUICK_SAVE_FAILED']) {
    test(
      '$code remains a named failure, preserves the original and permits retry',
      () async {
        final file = await source('report.pdf');
        messenger.setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: code, message: '目标存储不可用');
        });
        await expectLater(
          AndroidQuickReceivedSave.save(file, inbox),
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)),
        );
        expect(await file.readAsBytes(), [1, 2, 3]);
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => 'saved:content://media/downloads/1',
        );
        expect(
          (await AndroidQuickReceivedSave.save(file, inbox)).existing,
          isFalse,
        );
      },
    );
  }

  test(
    'empty and malformed native receipts cannot mark a save successful',
    () async {
      final file = await source('report.pdf');
      for (final response in <String?>[
        null,
        '',
        'ok',
        'saved:file:///tmp/file',
        'existing:content:',
        'saved:content:/missing-authority',
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => response);
        await expectLater(
          AndroidQuickReceivedSave.save(file, inbox),
          throwsA(isA<StateError>()),
        );
      }
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'Windows prioritizes resolved Downloads for pictures, videos and documents',
    () {
      for (final category in ['picture', 'video', 'document']) {
        expect(
          QuickReceivedSavePolicy.windowsFolder(
            {'USERPROFILE': root.path},
            category,
            downloads,
          ).path,
          downloads.path,
        );
      }
    },
  );

  test(
    'Windows same-name target is retained and actual renamed file is returned',
    () async {
      final file = await source('report.pdf');
      final existing = await File(
        '${downloads.path}/report.pdf',
      ).writeAsString('user file');
      final saved = await QuickReceivedSaveIndex.saveWindows(
        file,
        downloads,
        index,
      );
      expect(saved.uri.pathSegments.last, 'report (1).pdf');
      expect(await existing.readAsString(), 'user file');
      expect(await saved.readAsBytes(), [1, 2, 3]);
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(
        (await QuickReceivedSaveIndex.saveWindows(file, downloads, index)).path,
        saved.path,
      );
    },
  );

  test(
    'Windows removed/modified destination yields a new copy without overwrite',
    () async {
      final file = await source('file.txt');
      final first = await QuickReceivedSaveIndex.saveWindows(
        file,
        downloads,
        index,
      );
      await first.writeAsString('modified by user');
      final second = await QuickReceivedSaveIndex.saveWindows(
        file,
        downloads,
        index,
      );
      expect(second.path, isNot(first.path));
      expect(await first.readAsString(), 'modified by user');
      await second.delete();
      final third = await QuickReceivedSaveIndex.saveWindows(
        file,
        downloads,
        index,
      );
      expect(await third.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'Windows invalid destination and missing file fail without deleting an original',
    () async {
      final file = await source('file.txt');
      await expectLater(
        QuickReceivedSaveIndex.saveWindows(
          file,
          Directory('${root.path}/missing'),
          index,
        ),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        QuickReceivedSaveIndex.saveWindows(
          File('${inbox.path}/missing.txt'),
          downloads,
          index,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'Windows copy I/O failure cleans only its incomplete destination',
    () async {
      final file = await source('file.txt');
      final existing = await File(
        '${downloads.path}/unrelated.txt',
      ).writeAsString('keep');
      await expectLater(
        QuickReceivedSaveIndex.saveWindows(
          _ReadFailure(file),
          downloads,
          index,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(await existing.readAsString(), 'keep');
      expect(await File('${downloads.path}/file.txt').exists(), isFalse);
      expect(await index.lookup(file), isNull);
    },
  );

  test(
    'Windows corrupt auxiliary index cannot overwrite a user copy',
    () async {
      final file = await source('file.txt');
      await index.indexFile.writeAsString('not valid JSON');
      final existing = await File(
        '${downloads.path}/file.txt',
      ).writeAsString('keep');
      final saved = await QuickReceivedSaveIndex.saveWindows(
        file,
        downloads,
        index,
      );
      expect(saved.path, isNot(existing.path));
      expect(await existing.readAsString(), 'keep');
    },
  );

  test(
    'unsafe output filename cannot traverse the selected target directory',
    () async {
      final file = await source('file.txt');
      await expectLater(
        ReceivedFileActions.saveCopyToDirectory(
          file,
          downloads,
          fileName: '../escape.txt',
        ),
        throwsFormatException,
      );
      expect(await File('${root.path}/escape.txt').exists(), isFalse);
    },
  );
}
