import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/received_batch_save_policy.dart';

void main() {
  final folder = Directory.systemTemp.path;
  String location(String name) => '$folder${Platform.pathSeparator}$name';
  File item(String name) => File(location(name));

  test('E15 only selects listed received files, never arbitrary paths', () {
    final files = [item('picture.jpg'), item('document.pdf')];
    final selected = ReceivedBatchSavePolicy.resolve(files,
        {location('outside-private.txt'), location('document.pdf')});
    expect(selected.map((f) => f.path), [location('document.pdf')]);
  });

  test('E15 preserves file-list order and de-duplicates repeated paths', () {
    final files = [item('a.png'), item('a.png'), item('b.mp4'), item('c.zip')];
    expect(ReceivedBatchSavePolicy.candidates(files).map((f) => f.path),
      [location('a.png'), location('b.mp4'), location('c.zip')]);
    expect(ReceivedBatchSavePolicy.resolve(files, {
      location('c.zip'), location('a.png'),
    }).map((f) => f.path), [location('a.png'), location('c.zip')]);
  });

  test('E15 caps large batches to 30 items without loading file bytes', () {
    final list = List.generate(100, (i) => item('test$i.jpg'));
    expect(ReceivedBatchSavePolicy.candidates(list), hasLength(30));
    expect(ReceivedBatchSavePolicy.resolve(list,
        list.map((file) => file.path)), hasLength(30));
    expect(ReceivedBatchSavePolicy.candidates(list, limit: 4), hasLength(4));
  });

  test('E15 empty and stale selections never save another file', () {
    final files = [item('new.mp4')];
    expect(ReceivedBatchSavePolicy.resolve(files, {}), isEmpty);
    expect(ReceivedBatchSavePolicy.resolve(files, {location('old.mp4')}), isEmpty);
    expect(ReceivedBatchSavePolicy.candidates(files, limit: 0), isEmpty);
  });

  test('E15 rejects relative paths and retains absolute originals', () {
    final files = [File('relative.jpg'), item('genuine.webp')];
    expect(ReceivedBatchSavePolicy.candidates(files).map((f) => f.path),
        [location('genuine.webp')]);
  });
}
