import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/android_received_open.dart';
import 'package:nearlink/services/received_file_actions.dart';

void main() {
  test('Android can try uncommon formats but blocks executable content', () {
    for (final name in <String>[
      'photo.PNG', 'photo.webp', 'report.pdf', 'notes.txt',
      'sheet.xlsx', 'clip.mp4', 'audio.mp3', 'model.3mf',
      'archive.tar.zst', 'unknown.customext', 'extensionless',
    ]) {
      expect(AndroidReceivedOpen.isSupportedName(name), isTrue, reason: name);
    }
    for (final name in <String>[
      'installer.apk', 'program.exe', 'script.ps1', 'run.bat',
      'program.jar', 'library.dll', 'run.sh',
    ]) {
      expect(AndroidReceivedOpen.isSupportedName(name), isFalse, reason: name);
    }
    // The Windows policy remains allow-list based; Android's unknown-format
    // fallback must not broaden desktop execution behavior.
    expect(ReceivedFileActions.mayOpenWithSystem('unknown.customext'), isFalse);
  });

  test('accepts a regular file directly inside the receive directory', () async {
    final root = await Directory.systemTemp.createTemp('linyue_open_ok_');
    try {
      final child = File('${root.path}${Platform.pathSeparator}photo.png');
      await child.writeAsBytes([1, 2, 3]);
      final path = await AndroidReceivedOpen.validateFile(
        file: child,
        receiveDirectory: root,
      );
      expect(path, await child.resolveSymbolicLinks());
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('unknown ordinary extension can be handed to Android app chooser', () async {
    final root = await Directory.systemTemp.createTemp('linyue_open_unknown_');
    try {
      final child = File('${root.path}${Platform.pathSeparator}model.3mf');
      await child.writeAsBytes([1, 2, 3]);
      expect(await AndroidReceivedOpen.validateFile(
        file: child, receiveDirectory: root),
        await child.resolveSymbolicLinks());
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('explicit outgoing local source can open outside receive root', () async {
    final root = await Directory.systemTemp.createTemp('linyue_open_local_');
    try {
      final source = File('${root.path}${Platform.pathSeparator}project.custom');
      await source.writeAsBytes([1, 2, 3]);
      expect(await AndroidReceivedOpen.validateLocalFile(file: source),
        await source.resolveSymbolicLinks());
      final executable = File('${root.path}${Platform.pathSeparator}tool.exe');
      await executable.writeAsBytes([1]);
      await expectLater(AndroidReceivedOpen.validateLocalFile(file: executable),
        throwsA(isA<StateError>()));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('rejects files outside the active receive directory', () async {
    final parent = await Directory.systemTemp.createTemp('linyue_open_out_');
    final root = Directory('${parent.path}${Platform.pathSeparator}received');
    try {
      await root.create();
      final outside = File('${parent.path}${Platform.pathSeparator}outside.pdf');
      await outside.writeAsBytes([1]);
      await expectLater(
        AndroidReceivedOpen.validateFile(file: outside, receiveDirectory: root),
        throwsA(isA<StateError>()),
      );
    } finally {
      await parent.delete(recursive: true);
    }
  });

  test('fails closed for missing files and unsupported executable types', () async {
    final root = await Directory.systemTemp.createTemp('linyue_open_bad_');
    try {
      final missing = File('${root.path}${Platform.pathSeparator}missing.pdf');
      await expectLater(
        AndroidReceivedOpen.validateFile(file: missing, receiveDirectory: root),
        throwsA(isA<FileSystemException>()),
      );
      final executable = File('${root.path}${Platform.pathSeparator}run.exe');
      await executable.writeAsBytes([1]);
      await expectLater(
        AndroidReceivedOpen.validateFile(file: executable, receiveDirectory: root),
        throwsA(isA<StateError>()),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
