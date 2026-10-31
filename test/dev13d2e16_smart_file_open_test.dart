import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/smart_file_open_policy.dart';
import 'package:nearlink/services/received_file_actions.dart';

void main() {
  test('E16 common office documents open through system handler directly', () {
    for (final name in ['sheet.xlsx', 'sheet.XLS', 'report.pdf',
        'report.DOCX', 'show.pptx', 'table.csv', 'readme.txt', 'memo.md']) {
      expect(SmartFileOpenPolicy.isQuickDocument(name), isTrue, reason: name);
    }
    expect(SmartFileOpenPolicy.documentKind('year.XLSX'), '表格');
    expect(SmartFileOpenPolicy.documentKind('monthly.PDF'), 'PDF');
  });

  test('E16 does not bypass confirmation for executable or macro files', () {
    for (final name in ['install.apk', 'file.exe', 'run.ps1', 'a.xlsm',
        'a.docm', 'a.pptm', '../report.pdf', r'folder\report.pdf']) {
      expect(SmartFileOpenPolicy.isQuickDocument(name), isFalse, reason: name);
    }
  });

  test('E16 unknown and media types keep earlier user confirmation', () {
    for (final name in ['video.mp4', 'photo.png', 'archive.zip',
        'data.3mf', 'extensionless', '']) {
      expect(SmartFileOpenPolicy.isQuickDocument(name), isFalse, reason: name);
    }
  });

  test('E16 keeps platform system-open protections intact', () {
    expect(ReceivedFileActions.mayOpenWithSystem('report.xlsx'), isTrue);
    expect(ReceivedFileActions.mayOpenWithSystem('file.exe', allowUnknown: true), isFalse);
    expect(ReceivedFileActions.mayOpenWithSystem('unknown.3mf'), isFalse);
    expect(SmartFileOpenPolicy.actionLabel('report.xlsx', isAndroid: true),
      '直接打开表格文件');
    expect(SmartFileOpenPolicy.actionLabel('photo.png', isAndroid: false),
      '用系统默认应用打开');
  });
}
