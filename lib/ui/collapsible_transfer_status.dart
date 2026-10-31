// DEV13C3: compact transport-status presentation shared by Windows/Android.
// UI only: never changes encryption, consent, file IO or progress counters.
import 'package:flutter/material.dart';
import '../services/transfer_progress.dart';

class CollapsibleTransferStatus extends StatefulWidget {
  const CollapsibleTransferStatus({
    super.key,
    required this.entries,
    required this.detailsBuilder,
  });

  final List<TransferProgressInfo> entries;
  final Widget Function(TransferProgressInfo) detailsBuilder;

  @override
  State<CollapsibleTransferStatus> createState() => _CollapsibleTransferStatusState();
}

class _CollapsibleTransferStatusState extends State<CollapsibleTransferStatus> {
  // Every new conversation-status widget starts compact on both platforms.
  bool _expanded = false;

  String _speedLabel(TransferProgressInfo progress) {
    final speed = progress.speedBytesPerSecond;
    final speedText = speed != null && speed > 0
        ? '${_formatRate(speed)}/s'
        : null;
    switch (progress.phase) {
      case TransferProgressPhase.completed:
        return speedText == null ? '已完成' : '已完成 · $speedText';
      case TransferProgressPhase.failed:
        return '传输失败';
      case TransferProgressPhase.preparing:
        return '准备中';
      case TransferProgressPhase.authenticating:
        return '验证中';
      case TransferProgressPhase.awaitingApproval:
        return '等待接收确认';
      case TransferProgressPhase.verifying:
        return '校验中';
      case TransferProgressPhase.saving:
        return '保存中';
      case TransferProgressPhase.uploading:
      case TransferProgressPhase.receiving:
        return speedText ?? '测速中';
    }
  }

  String _formatRate(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MiB';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KiB';
    }
    return '${bytesPerSecond.round()} B';
  }

  double? _barValue(TransferProgressInfo entry) {
    if (entry.phase == TransferProgressPhase.completed) return 1.0;
    if (entry.phase == TransferProgressPhase.failed) return entry.fraction ?? 0.0;
    return entry.fraction;
  }

  Widget _compactEntry(TransferProgressInfo entry, {required bool showChevron}) {
    final failed = entry.phase == TransferProgressPhase.failed;
    final completed = entry.phase == TransferProgressPhase.completed;
    final tint = failed
        ? const Color(0xFFFFB39E)
        : completed ? const Color(0xFF95EAD0) : const Color(0xFF74D9D2);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(entry.direction == 'send'
                ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                size: 16, color: tint),
            const SizedBox(width: 5),
            Expanded(child: Text(entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            Text(_speedLabel(entry),
                maxLines: 1,
                style: TextStyle(fontSize: 11, color: tint)),
            if (showChevron) ...[
              const SizedBox(width: 8),
              Icon(_expanded ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
                  size: 21, color: const Color(0xFFA9C0C3)),
            ],
          ]),
          const SizedBox(height: 7),
          LinearProgressIndicator(
            value: _barValue(entry),
            minHeight: 5,
            color: tint,
            backgroundColor: const Color(0x442D6570),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0x33152D3A),
        border: Border.all(color: const Color(0x6680C9C4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const Key('transfer-status-toggle'),
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < widget.entries.length; i++) ...[
                      if (i != 0) const SizedBox(height: 6),
                      _compactEntry(widget.entries[i], showChevron: i == 0),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1, color: Color(0x443E7379)),
            Padding(
              key: const Key('transfer-status-details'),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('传输详情',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFFA9C0C3))),
                  const SizedBox(height: 8),
                  for (var i = 0; i < widget.entries.length; i++) ...[
                    if (i != 0) const SizedBox(height: 12),
                    widget.detailsBuilder(widget.entries[i]),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
