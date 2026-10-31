import 'package:flutter_test/flutter_test.dart';
import '../lib/ui/chat_card_display_policy.dart';

void main() {
  group('DEV13D2E20-C3A display safety policy', () {
    test('time is HH:mm only, without encryption or persistence status', () {
      final date = DateTime(2026, 10, 20, 21, 5);
      expect(ChatCardDisplayPolicy.clock(date), '21:05');
      expect(ChatCardDisplayPolicy.clock(date), isNot(contains('加密')));
      expect(ChatCardDisplayPolicy.clock(date).length, 5);
    });

    test('desktop/phone icons are symmetric between local and remote', () {
      expect(ChatCardDisplayPolicy.showPhoneAvatar(
        isAndroidClient: true, outbound: true), isTrue);
      expect(ChatCardDisplayPolicy.showPhoneAvatar(
        isAndroidClient: true, outbound: false), isFalse);
      expect(ChatCardDisplayPolicy.showPhoneAvatar(
        isAndroidClient: false, outbound: true), isFalse);
      expect(ChatCardDisplayPolicy.showPhoneAvatar(
        isAndroidClient: false, outbound: false), isTrue);
    });

    test('video play is never offered for failed records or absent local originals', () {
      expect(ChatCardDisplayPolicy.offerVideoPlay(
        successful: false, videoExtension: true,
        originalPath: 'x.mp4'), isFalse);
      expect(ChatCardDisplayPolicy.offerVideoPlay(
        successful: true, videoExtension: false,
        originalPath: 'x.txt'), isFalse);
      expect(ChatCardDisplayPolicy.offerVideoPlay(
        successful: true, videoExtension: true,
        originalPath: null), isFalse);
      expect(ChatCardDisplayPolicy.offerVideoPlay(
        successful: true, videoExtension: true,
        originalPath: ''), isFalse);
      expect(ChatCardDisplayPolicy.offerVideoPlay(
        successful: true, videoExtension: true,
        originalPath: 'x.mp4'), isTrue);
    });
  });
}
