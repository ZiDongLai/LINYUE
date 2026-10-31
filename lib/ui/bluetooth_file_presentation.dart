import '../bluetooth/bluetooth_file_lane.dart';
import '../services/transfer_progress.dart';

/// Existing transport uses this reason for an explicit local disconnect.
bool bluetoothFileWasCancelled(BluetoothFileProgress progress) =>
    progress.phase.startsWith('失败') && progress.error == '用户断开';

/// UI-only projection into the same live card used by LAN. No ACK/IO decisions.
TransferProgressInfo bluetoothFileProgressInfo(BluetoothFileProgress progress) {
  final phase = progress.phase.startsWith('成功')
      ? TransferProgressPhase.completed
      : progress.phase.startsWith('失败')
      ? TransferProgressPhase.failed
      : progress.phase.startsWith('接收中') || progress.phase.startsWith('已获')
      ? (progress.receiving
            ? TransferProgressPhase.receiving
            : TransferProgressPhase.uploading)
      : progress.phase.contains('校验') || progress.phase.contains('落盘')
      ? TransferProgressPhase.saving
      : TransferProgressPhase.awaitingApproval;
  return TransferProgressInfo(
    name: progress.offer.name,
    direction: progress.receiving ? 'receive' : 'send',
    phase: phase,
    totalBytes: progress.offer.size,
    transferredBytes: progress.bytes,
    elapsed: Duration.zero,
  );
}
