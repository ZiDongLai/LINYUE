import 'package:flutter/material.dart';

/// DEV13D2E20-C3A FIX1: purely presentational placement and text-selection menu.
/// This class does not edit messages, delete files, or change transport state.
abstract final class ChatSelectionAndActionsPolicy {
  /// Avatar stays on the outer edge: outgoing avatar is on the right.
  /// Only outgoing actions move to the left of the bubble; incoming stays right.
  static bool actionsBeforeBubble({required bool outbound}) => outbound;

  /// Keep the native selection operation but use Chinese labels.
  /// Offer only native COPY / SELECT ALL actions. The separate three-dot
  /// menu keeps full-message copy and local-history deletion available.
  static List<ContextMenuButtonItem> chineseSelectionButtons(
    List<ContextMenuButtonItem> buttons,
  ) {
    return buttons.where((item) =>
        item.type == ContextMenuButtonType.copy ||
        item.type == ContextMenuButtonType.selectAll).map((item) {
      return ContextMenuButtonItem(
        type: item.type,
        label: item.type == ContextMenuButtonType.copy ? '复制' : '全选',
        onPressed: item.onPressed,
      );
    }).toList(growable: false);
  }

  static Widget buildChineseSelectionToolbar(
    BuildContext context,
    EditableTextState state,
  ) {
    final items = chineseSelectionButtons(state.contextMenuButtonItems);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }
}
