import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/ui/chat_selection_and_actions_policy.dart';

void main() {
  group('DEV13D2E20-C3A FIX1 inside actions', () {
    test('outbound actions move opposite the outer right avatar', () {
      expect(ChatSelectionAndActionsPolicy.actionsBeforeBubble(
        outbound: true), isTrue);
    });

    test('incoming actions stay at the right as before', () {
      expect(ChatSelectionAndActionsPolicy.actionsBeforeBubble(
        outbound: false), isFalse);
    });
  });

  group('Chinese partial-text selection actions', () {
    test('copy/select-all retain native callbacks with Chinese labels', () {
      var copied = 0;
      var selectedAll = 0;
      var undesired = 0;
      final original = [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy, label: 'Copy',
          onPressed: () => copied++),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll, label: 'Select all',
          onPressed: () => selectedAll++),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste, label: 'Paste',
          onPressed: () => undesired++),
      ];
      final result = ChatSelectionAndActionsPolicy.chineseSelectionButtons(
        original);
      expect(result.length, 2);
      expect(result.map((x) => x.label).toList(), ['复制', '全选']);
      expect(result.map((x) => x.type).toList(),
        [ContextMenuButtonType.copy, ContextMenuButtonType.selectAll]);
      result[0].onPressed?.call();
      result[1].onPressed?.call();
      expect(copied, 1);
      expect(selectedAll, 1);
      expect(undesired, 0);
    });

    test('does not fabricate copy action where platform denies it', () {
      final result = ChatSelectionAndActionsPolicy.chineseSelectionButtons(
        [ContextMenuButtonItem(type: ContextMenuButtonType.custom,
          label: 'unknown', onPressed: () {})]);
      expect(result, isEmpty);
    });
  });
}
