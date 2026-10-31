import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/android_received_share.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory receiveDirectory;
  late File receivedFile;
  final calls = <MethodCall>[];
  final content = <int>[0, 1, 2, 127, 128, 255];

  setUp(() async {
    receiveDirectory = await Directory.systemTemp.createTemp(
      'linyue_received_share_',
    );
    receivedFile = File(
      '${receiveDirectory.path}${Platform.pathSeparator}已接收 文件.pdf',
    );
    await receivedFile.writeAsBytes(content);
    calls.clear();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await receiveDirectory.delete(recursive: true);
  });

  // Exercise the installed share_plus Dart/method-channel boundary without
  // pretending the host runs Android. The real Android-only adapter and UI
  // exception handler are audited separately; the native chooser needs a device.
  Future<ShareResult> shareValidatedReceivedFile() async {
    final path = await AndroidReceivedShare.validateFile(
      file: receivedFile,
      receiveDirectory: receiveDirectory,
    );
    return SharePlus.instance.share(
      ShareParams(files: [XFile(path)], title: '分享文件'),
    );
  }

  test(
    'missing receive directory is rejected before the platform is called',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'target';
      });
      await expectLater(
        AndroidReceivedShare.validateFile(
          file: receivedFile,
          receiveDirectory: Directory('${receiveDirectory.path}/missing'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, isEmpty);
      expect(await receivedFile.readAsBytes(), content);
    },
  );

  test('a directory cannot masquerade as a received regular file', () async {
    final folder = await Directory(
      '${receiveDirectory.path}/not-a-file.pdf',
    ).create();
    await expectLater(
      AndroidReceivedShare.validateFile(
        file: File(folder.path),
        receiveDirectory: receiveDirectory,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'files nested below the receive root are not exposed as received files',
    () async {
      final nested = await Directory(
        '${receiveDirectory.path}/unfinished',
      ).create();
      final partial = await File(
        '${nested.path}/sample.pdf',
      ).writeAsBytes(content);
      await expectLater(
        AndroidReceivedShare.validateFile(
          file: partial,
          receiveDirectory: receiveDirectory,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await partial.readAsBytes(), content);
    },
  );

  test(
    'a file removed after listing is rejected without opening the share channel',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'target';
      });
      await receivedFile.delete();
      await expectLater(
        shareValidatedReceivedFile(),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'share_plus receives the canonical existing file path and MIME type',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'example.share/TargetActivity';
      });
      final canonical = await receivedFile.resolveSymbolicLinks();
      final result = await shareValidatedReceivedFile();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'share');
      final arguments = calls.single.arguments as Map;
      expect(arguments['paths'], [canonical]);
      expect(arguments['mimeTypes'], ['application/pdf']);
      expect(arguments['title'], '分享文件');
      expect(arguments['text'], isNull);
      expect(result.status, ShareResultStatus.success);
      expect(await receivedFile.readAsBytes(), content);
    },
  );

  test(
    'dismissal returns a normal result and preserves the received file',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => '');
      final result = await shareValidatedReceivedFile();
      expect(result.status, ShareResultStatus.dismissed);
      expect(await receivedFile.readAsBytes(), content);
    },
  );

  test('unavailable result is not reported as successful delivery', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => 'dev.fluttercommunity.plus/share/unavailable',
    );
    final result = await shareValidatedReceivedFile();
    expect(result.status, ShareResultStatus.unavailable);
    expect(result.status, isNot(ShareResultStatus.success));
    expect(await receivedFile.readAsBytes(), content);
  });

  test(
    'missing share target failure remains catchable and leaves the source intact',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'ShareActivityNotFound',
          message: 'No target',
        );
      });
      await expectLater(
        shareValidatedReceivedFile(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'ShareActivityNotFound',
          ),
        ),
      );
      expect(await receivedFile.readAsBytes(), content);
    },
  );

  test(
    'native plugin failure remains catchable and leaves the source intact',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'ShareFailed',
          message: 'Native share failed',
        );
      });
      await expectLater(
        shareValidatedReceivedFile(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'ShareFailed',
          ),
        ),
      );
      expect(await receivedFile.readAsBytes(), content);
    },
  );

  test(
    'file deletion between validation and native dispatch surfaces a catchable error',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        await receivedFile.delete();
        throw PlatformException(
          code: 'ShareFailed',
          message: 'File disappeared',
        );
      });
      await expectLater(
        shareValidatedReceivedFile(),
        throwsA(isA<PlatformException>()),
      );
      expect(await receivedFile.exists(), isFalse);
    },
  );

  test(
    'the Android received-file adapter rejects the host platform without dispatch',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'target';
      });
      await expectLater(
        AndroidReceivedShare.shareFile(
          file: receivedFile,
          receiveDirectory: receiveDirectory,
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(calls, isEmpty);
      expect(await receivedFile.readAsBytes(), content);
    },
    skip: Platform.isAndroid
        ? 'This case checks the non-Android host guard.'
        : false,
  );
}
