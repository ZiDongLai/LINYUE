import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/conversation_card_interaction_policy.dart';

void main() {
  group('E20-C1 media actions', () {
    test('images and videos, including uppercase extensions, use one menu', () {
      for (final name in <String>[
        'image.jpg', '照片.PNG', 'drawing.webp', 'scan.heic',
        'movie.mp4', 'Travel.MOV', 'clip.mkv', 'movie.webm',
      ]) {
        expect(ConversationCardInteractionPolicy.isImageOrVideo(name), isTrue,
            reason: name);
      }
    });
    test('PDF, ZIP, executables and misleading double extensions are not media', () {
      for (final name in <String>[
        'document.pdf', 'archive.zip', 'run.exe', 'fake.jpg.exe', '',
      ]) {
        expect(ConversationCardInteractionPolicy.isImageOrVideo(name), isFalse,
            reason: name);
      }
    });
  });

  group('E20-C1 Windows whole-card drag gesture', () {
    bool allowed({
      bool windows = true,
      String direction = 'receive',
      String status = 'success',
      String? path = r'C:\\LinYue\\received\\test.jpg',
    }) => ConversationCardInteractionPolicy.canDragEntireReceivedCard(
          isWindows: windows,
          direction: direction,
          status: status,
          localPath: path,
        );
    test('only successful Windows received file with a path gets the gesture', () {
      expect(allowed(), isTrue);
      expect(allowed(windows: false), isFalse);
      expect(allowed(direction: 'send'), isFalse);
      expect(allowed(status: 'failed'), isFalse);
      expect(allowed(status: 'receiving'), isFalse);
      expect(allowed(path: null), isFalse);
      expect(allowed(path: '   '), isFalse);
    });
  });
}
