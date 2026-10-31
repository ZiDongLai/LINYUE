import 'dart:io';

import 'package:flutter/services.dart';

import 'transfer_history.dart';
import 'windows_received_drag_out_policy.dart';

/// The Windows runner exposes an OLE IDataObject with CF_HDROP and offers
/// DROPEFFECT_COPY only. The native side repeats the E20-A filesystem checks.
enum ReceivedDragOutResult { offeredToSystem, cancelled, denied, unavailable, failed }

final class WindowsReceivedDragOut {
  const WindowsReceivedDragOut._();

  static const channelName = 'linyue/windows_received_drag_out';
  static const methodName = 'startCopyDrag';
  static const MethodChannel _channel = MethodChannel(channelName);

  static ReceivedDragOutResult interpretNativeResult(String? result) {
    switch (result) {
      case 'copied':
        // OLE reports a COPY drop; it cannot prove the target's async write.
        return ReceivedDragOutResult.offeredToSystem;
      case 'cancelled':
        return ReceivedDragOutResult.cancelled;
      case 'denied':
        return ReceivedDragOutResult.denied;
      case 'ole_unavailable':
        return ReceivedDragOutResult.unavailable;
      default:
        return ReceivedDragOutResult.failed;
    }
  }

  static Future<ReceivedDragOutResult> start({
    required TransferRecord record,
    required Directory? receiveRoot,
  }) async {
    if (!Platform.isWindows) return ReceivedDragOutResult.unavailable;
    final inspected = await WindowsReceivedDragOutPolicy.inspect(
      record: record,
      receiveRoot: receiveRoot,
    );
    if (!inspected.canDrag || receiveRoot == null) {
      return ReceivedDragOutResult.denied;
    }
    try {
      final result = await _channel.invokeMethod<String>(methodName, {
        'path': inspected.absolutePath,
        'root': receiveRoot.absolute.path,
        'bytes': inspected.sizeBytes,
      });
      return interpretNativeResult(result);
    } on MissingPluginException {
      return ReceivedDragOutResult.unavailable;
    } on PlatformException {
      return ReceivedDragOutResult.failed;
    }
  }
}
