import 'package:flutter/material.dart';

/// One input surface for both routes; callbacks remain bound by the home.
class WorkbenchComposer extends StatelessWidget {
  const WorkbenchComposer({
    super.key,
    required this.draft,
    required this.focus,
    required this.canText,
    required this.busy,
    required this.mobile,
    required this.onAddFile,
    required this.onSend,
  });
  final TextEditingController draft;
  final FocusNode focus;
  final bool canText, busy, mobile;
  final VoidCallback? onAddFile, onSend;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton.filledTonal(
        key: const Key('workbench-add-file'),
        tooltip: '添加文件',
        onPressed: onAddFile,
        icon: const Icon(Icons.add_rounded),
      ),
      Expanded(
        child: TextField(
          key: const Key('workbench-text-input'),
          controller: draft,
          focusNode: focus,
          autofocus: false,
          onTapOutside: (_) => focus.unfocus(),
          enabled: canText,
          minLines: 1,
          maxLines: mobile ? 4 : 3,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(
            hintText: canText ? '输入文字（回车换行）' : '连接并验证设备后即可发送',
            isDense: true,
            filled: true,
            fillColor: const Color(0x66102833),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filled(
        key: const Key('workbench-send-text'),
        tooltip: busy ? '等待对端确认' : '发送文字',
        onPressed: !canText || busy ? null : onSend,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.send_rounded),
      ),
    ],
  );
}
