import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/ui/sent_original_source_policy.dart';

void main() {
  group('DEV13D2E5 FIX2 sent original path', () {
    late Directory root;
    late Directory temp;
    late Directory originals;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('linyue_fix2_');
      temp = await Directory('${root.path}${Platform.pathSeparator}tmp').create();
      originals = await Directory('${root.path}${Platform.pathSeparator}originals').create();
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('retains a real selected file outside picker cache', () async {
      final source = File('${originals.path}${Platform.pathSeparator}picture.png');
      await source.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final resolved = await SentOriginalSourcePolicy.resolve(
        candidatePath: source.path, temporaryDirectory: temp, expectedBytes: 4);
      expect(resolved, await source.resolveSymbolicLinks());
      expect(await source.readAsBytes(), <int>[1, 2, 3, 4]);
    });

    test('never retains an ephemeral file picker copy', () async {
      final transient = File('${temp.path}${Platform.pathSeparator}picture.png');
      await transient.writeAsBytes(<int>[1, 2, 3]);
      expect(await SentOriginalSourcePolicy.resolve(
        candidatePath: transient.path, temporaryDirectory: temp, expectedBytes: 3), isNull);
    });

    test('rejects missing, invalid-size and unavailable source paths', () async {
      final original = File('${originals.path}${Platform.pathSeparator}photo.png');
      await original.writeAsBytes(<int>[9, 8, 7]);
      expect(await SentOriginalSourcePolicy.resolve(
        candidatePath: original.path, temporaryDirectory: temp, expectedBytes: 4), isNull);
      expect(await SentOriginalSourcePolicy.resolve(
        candidatePath: '', temporaryDirectory: temp, expectedBytes: 3), isNull);
      expect(await SentOriginalSourcePolicy.resolve(
        candidatePath: '${originals.path}${Platform.pathSeparator}missing.png',
        temporaryDirectory: temp, expectedBytes: 3), isNull);
    });

    test('avoids falsely rejecting sibling path with same prefix', () async {
      final sibling = await Directory('${root.path}${Platform.pathSeparator}tmp_sibling').create();
      final picture = File('${sibling.path}${Platform.pathSeparator}photo.png');
      await picture.writeAsBytes(<int>[1]);
      expect(await SentOriginalSourcePolicy.resolve(
        candidatePath: picture.path, temporaryDirectory: temp, expectedBytes: 1),
        await picture.resolveSymbolicLinks());
    });
  });
}
