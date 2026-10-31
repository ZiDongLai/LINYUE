import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/android_received_share.dart';

void main() {
  test('all ordinary file names can be shared regardless of extension', () {
    for (final item in <String>[
      'file.PDF', 'clip.mp4', 'photo.JPEG', 'data.xlsx', 'model.3mf',
      'font.otf', 'backup.tar.zst', 'data.bin', 'tool.apk', 'script.ps1',
      'run.exe', 'test.bat', 'program.jar', 'hidden', '.private.pdf',
      'file.unknownext',
    ]) {
      expect(AndroidReceivedShare.isSupportedName(item), isTrue, reason: item);
    }
    for (final item in <String>['', '.', '..', 'a/b.txt', r'a\b.txt']) {
      expect(AndroidReceivedShare.isSupportedName(item), isFalse, reason: item);
    }
  });

  test('selected file directly within receive root is accepted', () async {
    final root = await Directory.systemTemp.createTemp('linyue_share_ok_');
    try {
      final child = File('${root.path}${Platform.pathSeparator}safe.pdf');
      await child.writeAsBytes([1, 2, 3]);
      final path = await AndroidReceivedShare.validateFile(
          file: child, receiveDirectory: root);
      expect(path, await child.resolveSymbolicLinks());
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('outside receive folder is never exposed by received-file action', () async {
    final parent = await Directory.systemTemp.createTemp('linyue_share_out_');
    final root = Directory('${parent.path}${Platform.pathSeparator}received');
    try {
      await root.create();
      final outside = File('${parent.path}${Platform.pathSeparator}outside.pdf');
      await outside.writeAsBytes([1]);
      await expectLater(
        AndroidReceivedShare.validateFile(file: outside, receiveDirectory: root),
        throwsA(isA<StateError>()),
      );
    } finally {
      await parent.delete(recursive: true);
    }
  });

  test('missing source fails closed but uncommon suffix is accepted', () async {
    final root = await Directory.systemTemp.createTemp('linyue_share_bad_');
    try {
      final nonexistent = File('${root.path}${Platform.pathSeparator}gone.pdf');
      await expectLater(
        AndroidReceivedShare.validateFile(file: nonexistent, receiveDirectory: root),
        throwsA(isA<FileSystemException>()),
      );
      final uncommon = File('${root.path}${Platform.pathSeparator}model.3mf');
      await uncommon.writeAsBytes([1]);
      expect(await AndroidReceivedShare.validateFile(
        file: uncommon, receiveDirectory: root),
        await uncommon.resolveSymbolicLinks());
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('user-selected local source may be shared outside receive root', () async {
    final root = await Directory.systemTemp.createTemp('linyue_share_local_');
    try {
      final source = File('${root.path}${Platform.pathSeparator}data.custom');
      await source.writeAsBytes([1, 2, 3]);
      expect(await AndroidReceivedShare.validateLocalFile(file: source),
        await source.resolveSymbolicLinks());
    } finally {
      await root.delete(recursive: true);
    }
  });
}
