import 'dart:async';
import 'package:flutter/foundation.dart';

enum SendQueueState { pending, sending, succeeded, failed, cancelled }

class SendQueueItem<T> {
  SendQueueItem(this.id, this.payload, this.name);
  final int id;
  final T payload;
  final String name;
  SendQueueState state = SendQueueState.pending;
  String? error;
}

/// Runtime-only FIFO queue. Each item is sent exactly once, in order.
/// Cancelling is supported only for pending items; the active encrypted
/// transfer must finish or fail through its own network protocol.
class SerialTransferQueue<T> extends ChangeNotifier {
  SerialTransferQueue({required this.worker, this.maxPending = 60});
  final Future<void> Function(SendQueueItem<T> job) worker;
  final int maxPending;
  final List<SendQueueItem<T>> _items = [];
  bool _working = false;
  bool _closed = false;
  int _nextId = 0;

  List<SendQueueItem<T>> get items => List.unmodifiable(_items);
  bool get isSending => _working;
  int get pendingCount => _items.where((e) => e.state == SendQueueState.pending).length;
  SendQueueItem<T>? get current {
    for (final item in _items) {
      if (item.state == SendQueueState.sending) return item;
    }
    return null;
  }

  void enqueue(List<(T payload, String name)> values) {
    if (_closed) throw StateError('队列已关闭');
    if (values.isEmpty) return;
    if (pendingCount + values.length > maxPending) {
      throw StateError('排队任务超出 $maxPending 项上限，请等待部分文件发送后再添加');
    }
    for (final value in values) {
      _items.add(SendQueueItem<T>(++_nextId, value.$1, value.$2));
    }
    notifyListeners();
    if (!_working) unawaited(_drain());
  }

  bool cancelPending(int id) {
    for (final item in _items) {
      if (item.id == id && item.state == SendQueueState.pending) {
        item.state = SendQueueState.cancelled;
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  int cancelAllPending() {
    var count = 0;
    for (final item in _items) {
      if (item.state == SendQueueState.pending) {
        item.state = SendQueueState.cancelled;
        count++;
      }
    }
    if (count > 0) notifyListeners();
    return count;
  }

  Future<void> waitUntilIdle() async {
    while (_working) {
      final running = _drainFuture;
      if (running == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      } else {
        await running;
      }
    }
  }

  Future<void>? _drainFuture;

  Future<void> _drain() async {
    if (_working || _closed) return;
    _working = true;
    notifyListeners();
    final completer = Completer<void>();
    _drainFuture = completer.future;
    try {
      for (;;) {
        SendQueueItem<T>? job;
        for (final candidate in _items) {
          if (candidate.state == SendQueueState.pending) {
            job = candidate;
            break;
          }
        }
        if (job == null || _closed) break;
        job.state = SendQueueState.sending;
        if (!_closed) notifyListeners();
        try {
          await worker(job);
          job.state = SendQueueState.succeeded;
        } catch (e) {
          job.error = '$e';
          job.state = SendQueueState.failed;
        }
        if (!_closed) notifyListeners();
        // Do not retain indefinitely many completed file handles/URIs.
        final finished = _items.where((e) =>
          e.state == SendQueueState.succeeded || e.state == SendQueueState.failed ||
          e.state == SendQueueState.cancelled).toList();
        for (final old in finished.take((finished.length - 30).clamp(0, finished.length))) {
          _items.remove(old);
        }
      }
    } finally {
      _working = false;
      _drainFuture = null;
      completer.complete();
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
