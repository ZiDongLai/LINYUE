import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/transfer_history.dart';
import 'package:nearlink/ui/conversation_image_source.dart';

void main() {
  group('DEV13D2E5 conversation image source', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('linyue_d2e5_source_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    TransferRecord sent({
      String? sourcePath,
      String? thumbnailPath,
    }) => TransferRecord(
      name: 'photo.png',
      peerName: 'Windows',
      direction: 'send',
      status: 'success',
      bytes: 12,
      timestamp: DateTime.utc(2026, 10, 19),
      sourcePath: sourcePath,
      thumbnailPath: thumbnailPath,
    );

    test('sent image opens original source before thumbnail', () async {
      final original = File('${root.path}/original.png');
      final thumbnail = File('${root.path}/thumbnail.png');
      await original.writeAsBytes(<int>[1, 2, 3, 4, 5]);
      await thumbnail.writeAsBytes(<int>[9, 8, 7]);

      final result = await ConversationImageSource.resolve(sent(
        sourcePath: original.path,
        thumbnailPath: thumbnail.path,
      ));

      expect(result, isNotNull);
      expect(result!.file.path, original.path);
      expect(result!.isSentThumbnail, isFalse);
      print('[DEV13D2E5] SENT_ORIGINAL_PREFERRED_PASS');
    });

    test('missing original falls back to the generated thumbnail', () async {
      final thumbnail = File('${root.path}/thumbnail.png');
      await thumbnail.writeAsBytes(<int>[9, 8, 7]);

      final result = await ConversationImageSource.resolve(sent(
        sourcePath: '${root.path}/moved-original.png',
        thumbnailPath: thumbnail.path,
      ));

      expect(result, isNotNull);
      expect(result!.file.path, thumbnail.path);
      expect(result!.isSentThumbnail, isTrue);
      print('[DEV13D2E5] THUMBNAIL_FALLBACK_PASS');
    });

    test('received image uses the local received file', () async {
      final received = File('${root.path}/received.png');
      await received.writeAsBytes(<int>[1, 3, 5, 7]);

      final entry = TransferRecord(
        name: 'received.png',
        peerName: 'Windows',
        direction: 'receive',
        status: 'success',
        bytes: 4,
        timestamp: DateTime.utc(2026, 10, 19),
        localPath: received.path,
      );

      final result = await ConversationImageSource.resolve(entry);
      expect(result, isNotNull);
      expect(result!.file.path, received.path);
      expect(result!.isSentThumbnail, isFalse);
      print('[DEV13D2E5] RECEIVED_ORIGINAL_PASS');
    });

    test('non-image and failed records never resolve as image previews', () async {
      final file = File('${root.path}/document.pdf');
      await file.writeAsBytes(<int>[1, 2, 3]);

      final nonImage = TransferRecord(
        name: 'document.pdf', peerName: 'Windows', direction: 'send',
        status: 'success', bytes: 3, timestamp: DateTime.utc(2026, 10, 19),
        sourcePath: file.path,
      );
      final failed = TransferRecord(
        name: 'photo.png', peerName: 'Windows', direction: 'send',
        status: 'failed', bytes: 3, timestamp: DateTime.utc(2026, 10, 19),
        sourcePath: file.path,
      );

      expect(await ConversationImageSource.resolve(nonImage), isNull);
      expect(await ConversationImageSource.resolve(failed), isNull);
      print('[DEV13D2E5] NON_IMAGE_AND_FAILED_REJECT_PASS');
    });
  });
}
