import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/ui/file_name_display.dart';

void main() {
  test('short names remain legible and unchanged', () {
    expect(compactRecentFileName('photo.jpg'), 'photo.jpg');
  });
  test('long names keep recognizable beginning and extension', () {
    final full = 'Screenshot_20261018_173951_com.nearlink.nearlink.jpg';
    final short = compactRecentFileName(full);
    expect(short, startsWith('Screenshot'));
    expect(short, endsWith('link.jpg'));
    expect(short.contains('…'), isTrue);
    expect(full, 'Screenshot_20261018_173951_com.nearlink.nearlink.jpg');
  });
  test('unicode names are abbreviated without dividing code points', () {
    final full = '照片收藏_海边散步_十月十八日_照片最终版.png';
    final short = compactRecentFileName(full, head: 4, tail: 7);
    expect(short, startsWith('照片收藏'));
    expect(short, endsWith('最终版.png'));
  });
  test('reject nonsensical clipping parameters', () {
    expect(() => compactRecentFileName('photo.jpg', head: 0), throwsArgumentError);
  });
}
