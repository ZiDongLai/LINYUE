import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// E21-B FIX1 source-layout regression.  Native resize and topmost controls
// are still checked by E21-B's existing bridge tests and Windows UI testing.
void main() {
  late String miniShell;

  setUpAll(() {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('  Widget _buildWindowsMiniShell() {');
    final end = source.indexOf('  // Android home is always the conversation.', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    miniShell = source.substring(start, end);
  });

  test('mini header is a single compact status row, without redundant title', () {
    expect(miniShell, isNot(contains("Text('邻跃 · 迷你聊天'")));
    expect(miniShell, isNot(contains('Icons.forum_outlined')));
    expect(miniShell, contains('height: 34'));
    expect(miniShell, contains('未选择设备 · 请返回主窗口'));
    expect(miniShell, contains('需要身份验证'));
    expect(miniShell, contains('已配对，发送前验证'));
    expect(miniShell, contains('maxLines: 1'));
    expect(miniShell, contains('TextOverflow.ellipsis'));
  });

  test('pin and restore retain functional callbacks and accessible labels', () {
    expect(miniShell, contains('onPressed: _toggleMiniTopmost'));
    expect(miniShell, contains('onPressed: _restoreWindowsMainChat'));
    expect(miniShell, contains("'取消置顶' : '窗口置顶'"));
    expect(miniShell, contains("tooltip: '返回完整窗口'"));
    expect(miniShell, contains('BoxConstraints.tightFor('));
    expect(miniShell, contains('width: 35'));
    expect(miniShell, contains('height: 34'));
  });

  test('the shared conversation and composer remain in mini mode', () {
    expect(miniShell, contains('_mixedConversationItems('));
    expect(miniShell, contains('_windowsMiniComposer(peer)'));
    expect(miniShell, contains('owner.hasAuthenticatedRecipient'));
  });
}
