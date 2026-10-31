import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/ui/chat_media_sizing.dart';

void main() {
  test('desktop images remain modest even on large monitors', () {
    expect(ChatMediaSizing.imageWidth(mobile: false, viewportWidth: 1920), 206);
    expect(ChatMediaSizing.imageHeight(mobile: false, viewportWidth: 1920), lessThanOrEqualTo(182));
  });

  test('phone preview stays comfortably inside chat column', () {
    expect(ChatMediaSizing.imageWidth(mobile: true, viewportWidth: 390), lessThanOrEqualTo(176));
    expect(ChatMediaSizing.imageHeight(mobile: true, viewportWidth: 390), lessThanOrEqualTo(152));
  });

  test('narrow phone adapts without exceeding width', () {
    final width = ChatMediaSizing.imageWidth(mobile: true, viewportWidth: 290);
    expect(width, lessThan(160));
    expect(ChatMediaSizing.imageHeight(mobile: true, viewportWidth: 290), lessThan(152));
  });

  test('document and video file cards have identical compact caps', () {
    expect(ChatMediaSizing.fileMaxWidth(mobile: false, viewportWidth: 1600), 298);
    expect(ChatMediaSizing.fileMaxWidth(mobile: true, viewportWidth: 390), 254);
  });
}
