import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_file_failure_message.dart';
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';
import 'package:nearlink/bluetooth/bluetooth_native_diagnostics.dart';
import 'bluetooth_e32_test.dart' show FileWire, sha, id;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nearlink/files');
  for (final size in [10240, 183001]) {
    test(
      'FIX1 real Dart staging, final readback and receipt size=$size',
      () async {
        final w = FileWire();
        await w.init();
        w.beforeCommit = (f) async {
          expect(await f.length(), size);
          expect(w.received, isEmpty);
          expect(w.sent.where((e) => e.m['k'] == 'file-complete'), isEmpty);
        };
        final input = await w.source(size);
        final receipt = await w.transfer(input);
        expect(receipt.sha256, sha(await w.received.single.readAsBytes()));
        expect(w.progress.last.phase, startsWith('成功'));
        expect(w.sent.where((e) => e.m['k'] == 'file-complete').length, 1);
      },
    );
  }
  test(
    'FIX1 native EACCES rejects final ACK/history, next transfer can succeed',
    () async {
      final w = FileWire();
      await w.init();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'commitBluetoothReceivedFile');
            final args = call.arguments as Map;
            expect(args['transferId'], matches(RegExp(r'^[a-f0-9]{32}$')));
            expect(args['size'], 183001);
            throw PlatformException(
              code: 'BT_FILE_COMMIT',
              message: '手机保存权限受限，文件未完成保存。',
              details: {
                'stage': 'atomic_rename',
                'errno': 13,
                'commitResult': 'failed',
              },
            );
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      w.beforeCommit = (temp) async {
        await BluetoothFileStore.commitAndroid(
          temp,
          BluetoothFileOffer(
            id: w.progress.last.offer.id,
            name: 'sample.bin',
            size: 183001,
            sha256: sha(await temp.readAsBytes()),
          ),
        );
      };
      final input = await w.source(183001);
      await expectLater(w.transfer(input), throwsStateError);
      expect(w.received, isEmpty);
      expect(await w.inbox.list().toList(), isEmpty);
      expect(w.sent.where((e) => e.m['k'] == 'file-complete'), isEmpty);
      expect(w.progress.any((p) => p.phase.startsWith('失败')), isTrue);
      w.beforeCommit = null;
      await w.transfer(input);
      expect(w.received.length, 1);
      expect(
        sha(await w.received.single.readAsBytes()),
        sha(await input.readAsBytes()),
      );
      expect(w.sent.where((e) => e.m['k'] == 'file-complete').length, 1);
    },
  );
  test(
    'FIX1 channel carries opaque transfer ID and exact verified metadata',
    () async {
      Map? args;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            args = call.arguments as Map;
            return {'path': 'verified-final', 'size': 1, 'sha256': 'a' * 64};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final saved = await BluetoothFileStore.commitAndroid(
        File('payload.part'),
        BluetoothFileOffer(id: id, name: 'a.txt', size: 1, sha256: 'a' * 64),
      );
      expect(args!['transferId'], id);
      expect(args!['path'], 'payload.part');
      expect(args!['size'], 1);
      expect(args!['sha256'], 'a' * 64);
      expect(saved.path, 'verified-final');
    },
  );
  for (final raw in [
    'PlatformException(BT_FILE_COMMIT, ErrnoException: link failed: EACCES (Permission denied), /data/private/file.png)',
    'ENOSPC /data/private/user.txt',
    'FileSystemException: SHA256 mismatch /data/private/a.txt',
    'unknown native failure /data/private/file.txt',
    'timeout waiting final ACK /data/private/a.txt',
    'session closed /data/private/a.txt',
  ]) {
    test('FIX1 UI redacts developer error: ${raw.split(' ').first}', () {
      final feedback = bluetoothFileFailureMessage(raw);
      expect(feedback.contains('/data'), isFalse);
      expect(feedback.contains('PlatformException'), isFalse);
      expect(feedback.contains('ErrnoException'), isFalse);
      expect(feedback, isNotEmpty);
    });
  }
  test(
    'FIX1 diagnostic formatter includes commit gates but excludes arbitrary secrets',
    () {
      final text = formatBluetoothNativeDiagnostics({
        'platform': 'android',
        'fileCommitStage': 'atomic_rename',
        'fileCommitErrno': 13,
        'fileCommitDirectoryWritable': true,
        'fileCommitTemporaryHashVerified': true,
        'fileCommitFinalHashVerified': 'unknown',
        'fileCommitResult': 'failed',
        'fileCommitSourceTag': 'bt-work:abc123',
        'privateKey': 'SECRET',
        'path': '/private/user/file.png',
      });
      expect(text, contains('fileCommitStage=atomic_rename'));
      expect(text, contains('fileCommitErrno=13'));
      expect(text, contains('fileCommitTemporaryHashVerified=true'));
      expect(text, contains('fileCommitFinalHashVerified=unknown'));
      expect(text.contains('SECRET') || text.contains('/private'), isFalse);
    },
  );
}
