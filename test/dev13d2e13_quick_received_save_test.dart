import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/quick_received_save.dart';

void main() {
  test('E13 only successful received records expose quick save', () {
    expect(QuickReceivedSavePolicy.availableForRecord(direction: 'receive', status: 'success', localPath: '/received/a.pdf'), isTrue);
    expect(QuickReceivedSavePolicy.availableForRecord(direction: 'send', status: 'success', localPath: '/received/a.pdf'), isFalse);
    expect(QuickReceivedSavePolicy.availableForRecord(direction: 'receive', status: 'failed', localPath: '/received/a.pdf'), isFalse);
    expect(QuickReceivedSavePolicy.availableForRecord(direction: 'receive', status: 'success'), isFalse);
  });

  test('E13 categorizes media without decoding or recompressing', () {
    expect(QuickReceivedSavePolicy.category('photo.HEIC'), 'picture');
    expect(QuickReceivedSavePolicy.category('movie.MP4'), 'video');
    expect(QuickReceivedSavePolicy.category('report.pdf'), 'document');
    expect(QuickReceivedSavePolicy.category('data.zip'), 'document');
  });

  test('E13 Windows default folder policy and fallback', () {
    final downloads = Directory('/home/test/Downloads');
    expect(QuickReceivedSavePolicy.windowsFolder({}, 'picture', downloads).path, downloads.path);
    expect(QuickReceivedSavePolicy.windowsFolder({'USERPROFILE': 'C:/Users/example'}, 'document', downloads).path, downloads.path);
  });

  test('E13 reuses an intact saved copy, changed copy never overwritten', () async {
    final dir = await Directory.systemTemp.createTemp('linyue_e13_');
    try {
      final original = File('${dir.path}${Platform.pathSeparator}photo.png');
      await original.writeAsBytes(List<int>.generate(512, (n) => n % 256));
      final output = Directory('${dir.path}${Platform.pathSeparator}output')..createSync();
      final index = QuickReceivedSaveIndex(File('${dir.path}${Platform.pathSeparator}index.json'));
      final first = await QuickReceivedSaveIndex.saveWindows(original, output, index);
      final second = await QuickReceivedSaveIndex.saveWindows(original, output, index);
      expect(first.path, second.path);
      expect(await first.readAsBytes(), await original.readAsBytes());
      await first.writeAsString('changed by user');
      final third = await QuickReceivedSaveIndex.saveWindows(original, output, index);
      expect(third.path, isNot(first.path));
      expect(await first.readAsString(), 'changed by user');
      expect(await third.readAsBytes(), await original.readAsBytes());
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
