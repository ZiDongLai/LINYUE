import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/conversation_card_interaction_policy.dart';
import 'package:nearlink/services/conversation_deletion_policy.dart';
import 'package:nearlink/services/native_video_frame_thumbnail.dart';
import 'package:nearlink/services/smart_file_open_policy.dart';
import 'package:nearlink/services/transfer_history.dart';
import 'package:nearlink/services/windows_received_drag_out_policy.dart';
import 'package:nearlink/ui/chat_card_display_policy.dart';
import 'package:nearlink/ui/chat_selection_and_actions_policy.dart';

/// DEV13D2E20-C4: regression gates across independently accepted batches.
/// Tests use disposable system-temp files only; no real LAN, app history,
/// phone photos, native drag, or media originals are touched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('message clock shows HH:mm only; avatars reflect local device', () {
    final clock = ChatCardDisplayPolicy.clock(DateTime(2026, 10, 21, 9, 6));
    expect(clock, '09:06');
    expect(clock, isNot(contains('加密')));
    expect(ChatCardDisplayPolicy.showPhoneAvatar(
        isAndroidClient: true, outbound: true), isTrue);
    expect(ChatCardDisplayPolicy.showPhoneAvatar(
        isAndroidClient: true, outbound: false), isFalse);
    expect(ChatCardDisplayPolicy.showPhoneAvatar(
        isAndroidClient: false, outbound: true), isFalse);
    expect(ChatCardDisplayPolicy.showPhoneAvatar(
        isAndroidClient: false, outbound: false), isTrue);
  });

  test('outgoing actions are inside, incoming unchanged; Chinese selection', () {
    expect(ChatSelectionAndActionsPolicy.actionsBeforeBubble(outbound: true),
        isTrue);
    expect(ChatSelectionAndActionsPolicy.actionsBeforeBubble(outbound: false),
        isFalse);
    var copyCount = 0;
    final items = ChatSelectionAndActionsPolicy.chineseSelectionButtons([
      ContextMenuButtonItem(type: ContextMenuButtonType.copy,
          label: 'Copy', onPressed: () => copyCount++),
      ContextMenuButtonItem(type: ContextMenuButtonType.selectAll,
          label: 'Select All', onPressed: () {}),
      ContextMenuButtonItem(type: ContextMenuButtonType.paste,
          label: 'Paste', onPressed: () {}),
    ]);
    expect(items.map((item) => item.label).toList(), ['复制', '全选']);
    items.first.onPressed?.call();
    expect(copyCount, 1);
  });

  test('only successful, received Windows cards are drag candidates', () {
    expect(ConversationCardInteractionPolicy.canDragEntireReceivedCard(
        isWindows: true, direction: 'receive', status: 'success',
        localPath: r'C:\LinYue\received\demo.pdf'), isTrue);
    expect(ConversationCardInteractionPolicy.canDragEntireReceivedCard(
        isWindows: false, direction: 'receive', status: 'success',
        localPath: '/tmp/demo.pdf'), isFalse);
    expect(ConversationCardInteractionPolicy.canDragEntireReceivedCard(
        isWindows: true, direction: 'send', status: 'success',
        localPath: r'C:\source.pdf'), isFalse);
    expect(ConversationCardInteractionPolicy.canDragEntireReceivedCard(
        isWindows: true, direction: 'receive', status: 'failed',
        localPath: r'C:\partial.pdf'), isFalse);
  });

  test('drag preflight stays read-only; size change immediately blocks', () async {
    final base = await Directory.systemTemp.createTemp('linyue_e20c4_drag_');
    try {
      final root = await Directory('${base.path}${Platform.pathSeparator}recv')
          .create();
      final received = File('${root.path}${Platform.pathSeparator}photo.png');
      await received.writeAsBytes([10, 20, 30, 40], flush: true);
      TransferRecord record(int size) => TransferRecord(
          name: 'photo.png', peerName: 'paired', direction: 'receive',
          status: 'success', bytes: size, timestamp: DateTime(2026, 10, 21),
          localPath: received.path);
      final original = await received.readAsBytes();
      final valid = await WindowsReceivedDragOutPolicy.inspect(
          record: record(4), receiveRoot: root);
      expect(valid.canDrag, isTrue);
      expect(await received.readAsBytes(), original);
      await received.writeAsBytes([10, 20, 30, 40, 50], flush: true);
      final changed = await WindowsReceivedDragOutPolicy.inspect(
          record: record(4), receiveRoot: root);
      expect(changed.block, ReceivedDragOutBlock.changedSize);
      expect(await received.exists(), isTrue);
    } finally {
      await base.delete(recursive: true);
    }
  });

  test('removing local history record does not delete original file', () async {
    final base = await Directory.systemTemp.createTemp('linyue_e20c4_history_');
    try {
      final original = File('${base.path}${Platform.pathSeparator}source.txt');
      final received = File('${base.path}${Platform.pathSeparator}received.txt');
      await original.writeAsString('original source - keep');
      await received.writeAsString('received bytes - keep');
      final store = TransferHistoryStore(customDirectory: base);
      await store.load();
      final sent = TransferRecord(name: 'source.txt', peerName: 'peer',
          direction: 'send', status: 'success', bytes: await original.length(),
          timestamp: DateTime(2026, 10, 21), sourcePath: original.path);
      final incoming = TransferRecord(name: 'received.txt', peerName: 'peer',
          direction: 'receive', status: 'success', bytes: await received.length(),
          timestamp: DateTime(2026, 10, 21), localPath: received.path);
      await store.append(sent);
      await store.append(incoming);
      expect(await store.removeRecord(incoming), isTrue);
      final restarted = TransferHistoryStore(customDirectory: base);
      await restarted.load();
      expect(restarted.records.length, 1);
      expect(restarted.records.single.direction, 'send');
      expect(await original.readAsString(), 'original source - keep');
      expect(await received.readAsString(), 'received bytes - keep');
    } finally {
      await base.delete(recursive: true);
    }
  });

  test('physical local-copy delete requires successful received entry', () {
    expect(ConversationDeletionPolicy.canDeleteReceivedCopy(
        direction: 'receive', status: 'success',
        localPath: '/received/video.mp4'), isTrue);
    expect(ConversationDeletionPolicy.canDeleteReceivedCopy(
        direction: 'send', status: 'success',
        localPath: '/user/videos/original.mp4'), isFalse);
    expect(ConversationDeletionPolicy.canDeleteReceivedCopy(
        direction: 'receive', status: 'failed',
        localPath: '/received/partial.mp4'), isFalse);
    expect(ConversationDeletionPolicy.canDeleteReceivedCopy(
        direction: 'receive', status: 'success', localPath: null), isFalse);
  });

  test('video preview validates file type, bound and image signature', () async {
    final base = await Directory.systemTemp.createTemp('linyue_e20c4_video_');
    try {
      final video = File('${base.path}${Platform.pathSeparator}clip.MP4');
      await video.writeAsBytes([1, 2, 3, 4], flush: true);
      final original = await video.readAsBytes();
      expect(NativeVideoFrameThumbnail.eligibleFile(
          path: video.path, stat: await video.stat()), isTrue);
      expect(NativeVideoFrameThumbnail.isVideoPath('image.jpg'), isFalse);
      expect(NativeVideoFrameThumbnail.isVideoPath('clip.mp4\u0000bad'), isFalse);
      expect(NativeVideoFrameThumbnail.isValidPreview(Uint8List.fromList(
          [0xff, 0xd8, 0xff, 0xe0])), isTrue);
      expect(NativeVideoFrameThumbnail.isValidPreview(
          Uint8List.fromList([1, 2, 3])), isFalse);
      expect(await video.readAsBytes(), original); // never rewrite media
      expect(ChatCardDisplayPolicy.offerVideoPlay(successful: false,
          videoExtension: true, originalPath: video.path), isFalse);
      expect(ChatCardDisplayPolicy.offerVideoPlay(successful: true,
          videoExtension: true, originalPath: video.path), isTrue);
    } finally {
      await base.delete(recursive: true);
    }
  });

  test('E16 dangerous extension cannot become a quick-open document', () {
    for (final unsafe in [
      'installer.apk', 'launcher.exe', 'script.ps1', 'report.docm',
      'macro.xlsm', 'presentation.pptm'
    ]) {
      expect(SmartFileOpenPolicy.isQuickDocument(unsafe), isFalse,
          reason: unsafe);
    }
    expect(SmartFileOpenPolicy.isQuickDocument('report.pdf'), isTrue);
    expect(ConversationCardInteractionPolicy.isImageOrVideo('video.mp4'),
        isTrue);
  });
}
