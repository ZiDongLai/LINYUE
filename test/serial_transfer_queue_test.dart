import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/serial_transfer_queue.dart';

void main() {
  test('FIFO and enqueues while first job is running', () async {
    final latch = Completer<void>();
    final order = <int>[];
    final queue = SerialTransferQueue<int>(worker: (job) async {
      if (job.payload == 1) await latch.future;
      order.add(job.payload);
    });
    queue.enqueue([(1, 'first'), (2, 'second')]);
    queue.enqueue([(3, 'third')]);
    expect(queue.isSending, isTrue);
    expect(queue.pendingCount, 2);
    latch.complete();
    await queue.waitUntilIdle();
    expect(order, [1, 2, 3]);
    expect(queue.items.every((x) => x.state == SendQueueState.succeeded), true);
    queue.dispose();
  });

  test('failed item does not block next encrypted send task', () async {
    final queue = SerialTransferQueue<int>(worker: (job) async {
      if (job.payload == 1) throw StateError('failed upload');
    });
    queue.enqueue([(1, 'bad'), (2, 'good')]);
    await queue.waitUntilIdle();
    expect(queue.items.map((e) => e.state).toList(),
      [SendQueueState.failed, SendQueueState.succeeded]);
    queue.dispose();
  });

  test('cancel only pending; running job cannot be cancelled', () async {
    final latch = Completer<void>();
    final queue = SerialTransferQueue<int>(worker: (job) async {
      if (job.payload == 1) await latch.future;
    });
    queue.enqueue([(1, 'in progress'), (2, 'waiting')]);
    final active = queue.items.first;
    final pending = queue.items.last;
    expect(queue.cancelPending(active.id), false);
    expect(queue.cancelPending(pending.id), true);
    latch.complete();
    await queue.waitUntilIdle();
    expect(active.state, SendQueueState.succeeded);
    expect(pending.state, SendQueueState.cancelled);
    queue.dispose();
  });

  test('pending limit checked before mutating queue', () async {
    final latch = Completer<void>();
    final queue = SerialTransferQueue<int>(maxPending: 1, worker: (job) async {
      await latch.future;
    });
    queue.enqueue([(1, 'first')]);
    queue.enqueue([(2, 'second')]);
    expect(() => queue.enqueue([(3, 'too many')]), throwsStateError);
    expect(queue.items.length, 2);
    latch.complete();
    await queue.waitUntilIdle();
    queue.dispose();
  });
}
