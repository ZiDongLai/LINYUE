import 'dart:async';
import 'dart:typed_data';

/// E32: counts actual framed bytes, including the four-byte length header.
/// Platform acceptance is queue admission, never a delivery receipt.
class BluetoothBoundedWriter {
  BluetoothBoundedWriter({
    required this.capacity,
    required this.write,
    this.timeout = const Duration(seconds: 15),
  });
  static const frameLimit = 16 * 1024, byteLimit = 64 * 1024;
  final Future<int> Function() capacity;
  final Future<void> Function(Uint8List) write;
  final Duration timeout;
  Future<void> _tail = Future.value();
  int pendingBytes = 0, peakBytes = 0;
  int backpressurePolls = 0, backpressureMicros = 0;
  bool _closed = false;

  Future<void> add(Uint8List bytes) {
    if (_closed ||
        bytes.isEmpty ||
        bytes.length > frameLimit ||
        pendingBytes + bytes.length > byteLimit) {
      throw StateError('Bluetooth framed-byte queue limit/disconnected');
    }
    pendingBytes += bytes.length;
    if (pendingBytes > peakBytes) peakBytes = pendingBytes;
    final operation = _tail
        .then((_) async {
          final clock = Stopwatch()..start();
          var waited = false;
          while (true) {
            if (_closed) throw StateError('Bluetooth writer closed');
            final free = await capacity();
            if (_closed) throw StateError('Bluetooth writer closed');
            if (free < 0 || free > byteLimit) {
              throw StateError('Invalid native byte capacity');
            }
            if (free >= bytes.length) {
              if (waited) backpressureMicros += clock.elapsedMicroseconds;
              break;
            }
            waited = true;
            backpressurePolls++;
            if (clock.elapsed >= timeout) {
              throw TimeoutException('Bluetooth native byte backpressure');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await write(bytes);
        })
        .whenComplete(() {
          pendingBytes -= bytes.length;
        });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  void close() {
    _closed = true;
  }
}
