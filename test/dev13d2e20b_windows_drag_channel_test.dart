import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/windows_received_drag_out.dart';

void main() {
  test('E20-B native OLE method contract stays versioned', () {
    expect(WindowsReceivedDragOut.channelName,
        'linyue/windows_received_drag_out');
    expect(WindowsReceivedDragOut.methodName, 'startCopyDrag');
  });

  test('OLE COPY drop is not overstated as verified destination copy', () {
    expect(WindowsReceivedDragOut.interpretNativeResult('copied'),
        ReceivedDragOutResult.offeredToSystem);
  });

  test('cancel and denied results are different; no silent retry', () {
    expect(WindowsReceivedDragOut.interpretNativeResult('cancelled'),
        ReceivedDragOutResult.cancelled);
    expect(WindowsReceivedDragOut.interpretNativeResult('denied'),
        ReceivedDragOutResult.denied);
    expect(WindowsReceivedDragOut.interpretNativeResult('ole_unavailable'),
        ReceivedDragOutResult.unavailable);
    expect(WindowsReceivedDragOut.interpretNativeResult('failed'),
        ReceivedDragOutResult.failed);
    expect(WindowsReceivedDragOut.interpretNativeResult(null),
        ReceivedDragOutResult.failed);
  });
}
