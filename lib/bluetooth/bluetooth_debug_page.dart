// B2: advanced B1 sample controls, embedded in the connection sheet only.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bluetooth_transport.dart';

class BluetoothDiagnostics extends StatefulWidget {
  const BluetoothDiagnostics({
    super.key,
    required this.transport,
    this.errorDetail = '',
  });
  final BluetoothTransport transport;
  final String errorDetail;
  @override
  State<BluetoothDiagnostics> createState() => _BluetoothDiagnosticsState();
}

class _BluetoothDiagnosticsState extends State<BluetoothDiagnostics> {
  bool busy = false;
  String result = '';
  Future<void> _run(Future<void> Function() action, String success) async {
    if (busy) return;
    setState(() {
      busy = true;
      result = '';
    });
    try {
      await action();
      if (mounted) {
        setState(() {
          result = success;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          result = '测试未确认，请查看诊断：$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    final t = widget.transport;
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '仅发送内置公开样本。成功须收到对端有效ACK，不以本机写入作为送达。',
            style: TextStyle(fontSize: 11),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                key: const Key('refresh-native-bluetooth-diagnostics'),
                onPressed: busy
                    ? null
                    : () => _run(t.refreshNativeDiagnostics, '已刷新原生诊断（未建立新连接）'),
                child: const Text('刷新原生日志'),
              ),
              TextButton(
                onPressed: busy || !t.authenticated
                    ? null
                    : () => _run(
                        () => t.sendTest(utf8.encode('邻跃 E25-B1 UTF-8 测试 ✓')),
                        '对端已确认收到UTF-8样本',
                      ),
                child: const Text('测试文字'),
              ),
              TextButton(
                onPressed: busy || !t.authenticated
                    ? null
                    : () => _run(
                        () => t.sendTest(List<int>.generate(256, (i) => i)),
                        '对端已确认收到二进制样本',
                      ),
                child: const Text('测试二进制'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        await t.refreshNativeDiagnostics();
                        await Clipboard.setData(
                          ClipboardData(
                            text: [
                              widget.errorDetail,
                              t.nativeDiagnostics,
                              ...t.events,
                            ].join('\n'),
                          ),
                        );
                      }, '诊断已复制'),
                child: const Text('复制诊断'),
              ),
            ],
          ),
          if (result.isNotEmpty)
            Text(result, style: const TextStyle(fontSize: 11)),
          if (widget.errorDetail.isNotEmpty)
            SelectableText(
              widget.errorDetail,
              style: const TextStyle(fontSize: 11),
            ),
          if (t.nativeDiagnostics.isNotEmpty)
            SelectableText(
              t.nativeDiagnostics,
              key: const Key('native-bluetooth-diagnostics'),
              style: const TextStyle(fontSize: 10),
            ),
          for (final bytes in t.receivedTests)
            Text(
              '收到${bytes.length}字节：${bytes.length == 256 ? bytes.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ') : utf8.decode(bytes, allowMalformed: true)}',
              style: const TextStyle(fontSize: 11),
            ),
          SelectableText(
            t.events.join('\n'),
            style: const TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }
}
