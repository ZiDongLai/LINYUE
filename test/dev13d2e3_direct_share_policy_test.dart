import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/android_received_share.dart';
import 'package:nearlink/services/received_file_actions.dart';
import 'package:nearlink/services/transfer_history.dart';

void main() {
  test('direct sharing is not limited to a hard-coded extension list', () {
    for (final name in <String>[
      'photo.png', 'archive.7z', 'model.3mf', 'font.otf',
      'project.custom', 'database', 'installer.apk',
    ]) {
      expect(AndroidReceivedShare.isSupportedName(name), isTrue, reason: name);
    }
  });

  test('Android open fallback accepts unknown types but blocks launchable types', () {
    expect(ReceivedFileActions.mayOpenWithSystem('project.custom', allowUnknown: true), isTrue);
    expect(ReceivedFileActions.mayOpenWithSystem('database', allowUnknown: true), isTrue);
    for (final name in <String>[
      'installer.apk', 'program.exe', 'script.ps1', 'run.bat', 'code.jar',
      'macro.xlsm', 'library.dll',
    ]) {
      expect(ReceivedFileActions.mayOpenWithSystem(name, allowUnknown: true),
        isFalse, reason: name);
    }
    expect(ReceivedFileActions.mayOpenWithSystem('project.custom'), isFalse);
  });

  test('sent source path is optional and old history records remain readable', () {
    final current = TransferRecord(
      name: 'model.3mf', peerName: 'Android · 我的手机', direction: 'send',
      status: 'success', bytes: 3, timestamp: DateTime.utc(2026, 10, 19),
      sourcePath: '/private/share-cache/model.3mf', managedShareCopy: true,
    );
    final decoded = TransferRecord.fromJson(current.toJson());
    expect(decoded.sourcePath, current.sourcePath);
    expect(decoded.managedShareCopy, isTrue);

    final old = TransferRecord.fromJson(<String, dynamic>{
      'name': 'old.txt', 'peerName': 'Windows', 'direction': 'send',
      'status': 'success', 'bytes': 1,
      'timestamp': '2026-10-18T00:00:00.000Z',
      'localPath': null, 'thumbnailPath': null,
    });
    expect(old.sourcePath, isNull);
    expect(old.managedShareCopy, isFalse);
  });
}
