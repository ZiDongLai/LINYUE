import 'dart:math' as math;

/// Display-only layout caps for Windows and Android chat file bubbles.
/// These values never alter the original file, transferred bytes or codec.
class ChatMediaSizing {
  const ChatMediaSizing._();

  static double imageWidth({required bool mobile, required double viewportWidth}) {
    final cap = mobile ? 176.0 : 206.0;
    // Scale down on narrow screens, but don't let long screenshots occupy a
    // full chat column. An image can always be opened in the existing viewer.
    final responsive = viewportWidth * (mobile ? 0.51 : 0.25);
    return math.min(cap, math.max(96.0, responsive));
  }

  static double imageHeight({required bool mobile, required double viewportWidth}) {
    final width = imageWidth(mobile: mobile, viewportWidth: viewportWidth);
    return math.min(mobile ? 152.0 : 182.0, width * 0.89);
  }

  static double fileMaxWidth({required bool mobile, required double viewportWidth}) {
    final cap = mobile ? 254.0 : 298.0;
    final responsive = viewportWidth * (mobile ? 0.67 : 0.30);
    return math.min(cap, math.max(mobile ? 168.0 : 205.0, responsive));
  }
}
