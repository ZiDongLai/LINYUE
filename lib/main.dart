import 'bluetooth/bluetooth_file_store.dart';
// E40-P0: compile/export only. No store instance or transport integration.
export 'bluetooth/checkpoint_primitives/checkpoint_store.dart';
import 'bluetooth/bluetooth_file_policy.dart';
import 'ui/bluetooth_file_presentation.dart';
import 'ui/workbench_composer.dart';
import 'bluetooth/bluetooth_source_stage.dart';
import 'services/received_file_visibility.dart';
import 'bluetooth/bluetooth_file_failure_message.dart';
import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'bluetooth/bluetooth_transport.dart';
import 'bluetooth/bluetooth_connection_controller.dart';
import 'bluetooth/bluetooth_connection_sheet.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:desktop_drop/desktop_drop.dart';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart' hide XFile;
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'services/nearlink_service.dart';
import 'services/same_platform_live_connection.dart';
import 'services/same_platform_connection_policy.dart';
import 'services/manual_peer_target_store.dart';
import 'services/peer_management_policy.dart';
import 'services/authenticated_peer_binding_policy.dart';
import 'services/windows_mini_chat_session_coordinator.dart';
import 'services/windows_mini_window_bridge.dart';
import 'services/windows_mini_window_preferences.dart';
import 'services/transfer_history.dart';
import 'services/received_file_actions.dart';
import 'services/smart_file_open_policy.dart';
import 'services/conversation_text_protocol.dart';
import 'services/live_text_trial_ledger.dart';
import 'services/encrypted_text_history_runtime.dart';
import 'services/encrypted_text_history_store.dart';
import 'services/conversation_timeline_merge.dart';
import 'services/quick_received_save.dart';
import 'services/received_batch_save_policy.dart';
import 'services/mobile_media_source_policy.dart';
import 'services/local_received_file_manager.dart';
import 'services/local_storage_overview.dart';
import 'services/media_copy_audit.dart';
import 'services/media_receipt_health.dart';
import 'services/android_received_share.dart';
import 'services/android_received_open.dart';
import 'package:open_filex/open_filex.dart' show ResultType;
import 'services/conversation_view.dart';
import 'services/transfer_progress.dart';
import 'services/receive_guard.dart';
import 'services/serial_transfer_queue.dart';
import 'services/outbound_retry_policy.dart';
import 'services/outbound_resume_task_presentation.dart';
import 'services/windows_received_drag_out.dart';
import 'services/conversation_card_interaction_policy.dart';
import 'services/conversation_deletion_policy.dart';
import 'services/receive_directory_preference.dart';
import 'services/disk_capacity_guard.dart';
import 'widgets/device_identity_panel.dart';
import 'security/device_identity.dart';
import 'security/platform_identity_vault.dart';
import 'security/in_app_pairing.dart';
import 'security/secure_file_channel.dart';
import 'security/outbound_resume_journal.dart';
import 'security/outbound_resume_controller.dart';
import 'security/outbound_consistency_audit.dart';
import 'security/outbound_storage_health.dart';
import 'security/trusted_auto_receive_policy.dart';
import 'ui/file_name_display.dart';
import 'ui/file_visual_badge.dart';
import 'ui/chat_media_sizing.dart';
import 'ui/chat_card_display_policy.dart';
import 'ui/chat_selection_and_actions_policy.dart';
import 'widgets/conversation_video_thumbnail.dart';
import 'ui/sent_image_preview_store.dart';
import 'ui/collapsible_transfer_status.dart';
import 'ui/received_image_preview.dart';
import 'ui/conversation_image_source.dart';
import 'ui/image_carousel_policy.dart';
import 'ui/sent_original_source_policy.dart';

typedef _SecureSendJob = ({
  NearPeer peer,
  PlatformFile? selected,
  OutboundResumeRecord? resume,
});

/// One device-menu command returned after the popup/dialog routes close.
/// An address here is only a locator, never an authenticated identity.
class _DeviceManagerSelection {
  const _DeviceManagerSelection({
    required this.action,
    required this.peerId,
    required this.peerIp,
  });
  final String action;
  final String? peerId;
  final String peerIp;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LinYueApp());
}

// Adapts one Windows filesystem drop into file_picker 13.x's abstract API.
// The existing NearLinkService keeps its tested PlatformFile sendFile contract.
// This is for ordinary local files; folders and cloud-only drops stay unsupported.
final class _DroppedPlatformFile extends PlatformFile {
  _DroppedPlatformFile(this._source, this._fileBytes);

  final DropItemFile _source;
  final int _fileBytes;

  @override
  String get name => _source.name;

  @override
  Uri get uri => Uri.file(_source.path, windows: Platform.isWindows);

  @override
  String? get path => _source.path;

  @override
  DropItemFile get xFile => _source;

  @override
  int? lengthSync() => _fileBytes;

  @override
  Future<int?> length() async => _fileBytes;

  @override
  Future<Uint8List> readAsBytes() => _source.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      _source.openRead().map((chunk) => Uint8List.fromList(chunk));
}

// A gallery/camera result is temporary. After staging a durable private copy,
// present it through the existing PlatformFile API without modifying the
// battle-tested secure transfer queue.
final class _MobileStagedMediaFile extends PlatformFile {
  _MobileStagedMediaFile(this._file, this._displayName);
  final File _file;
  final String _displayName;

  @override
  String get name => _displayName;

  @override
  String? get path => _file.path;

  @override
  Uri get uri => _file.uri;

  @override
  XFile get xFile => XFile(_file.path, name: _displayName);

  @override
  int? lengthSync() => _file.lengthSync();

  @override
  Future<int?> length() => _file.length();

  @override
  Future<Uint8List> readAsBytes() => _file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      _file.openRead().map((part) => Uint8List.fromList(part));
}

enum MobileTab { nearby, transfer, settings }

enum DesktopTab { nearby, transfer, files, settings }

enum HistoryFilter { all, sent, received }

enum _ReceiveApproval { block, decline, once, auto }

class LinYueApp extends StatelessWidget {
  const LinYueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '邻跃 LINYUE · v0.5.65 DEV13D2E38',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF081721),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF74D9D2),
          secondary: Color(0xFF43C4BF),
          surface: Color(0xFF102732),
          onSurface: Color(0xFFE2EEEC),
        ),
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: const Color(0xFFE2EEEC),
          displayColor: const Color(0xFFE2EEEC),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF122B34),
          contentTextStyle: TextStyle(color: Color(0xFFE2EEEC)),
        ),
        dividerColor: const Color(0x332A4A55),
      ),
      home: const TransferHome(),
    );
  }
}

class TransferHome extends StatefulWidget {
  const TransferHome({super.key});

  @override
  State<TransferHome> createState() => _TransferHomeState();
}

class _TransferHomeState extends State<TransferHome> {
  // 保留 v0.1.1 Android ACTION_CREATE_DOCUMENT 原生另存为通道。
  static const MethodChannel _fileChannel = MethodChannel('nearlink/files');
  late final NearLinkService service;
  final TextEditingController ipController = TextEditingController();
  final List<File> received = [];
  final Set<String> _autoArchivedMediaPaths = {};
  final Set<String> _autoArchivingMediaPaths = {};
  final Set<String> _quickSavedReceivedPaths = {};
  final Set<String> _quickSavingReceivedPaths = {};
  QuickReceivedSaveIndex? _windowsQuickSaveIndex;
  // E15 Android-only UI selection: never includes sent records or remote files.
  final Set<String> _batchSelectedReceivedPaths = <String>{};
  bool _batchSelectionMode = false;
  bool _batchSaveBusy = false;
  int _batchSaveCompleted = 0;
  int _batchSaveTotal = 0;
  bool sending = false;
  late final SerialTransferQueue<_SecureSendJob> _sendQueue;
  OutboundResumeController? _outboundController;
  List<OutboundResumeRecord> _pendingRestores = const [];
  final Set<String> _enqueuedResumeIds = {};
  final Set<String> _attemptedResumesThisRun = {};
  bool _showAllResumeTasks = false;
  final OutboundRetryPolicy _outboundRetryPolicy = const OutboundRetryPolicy();
  final OutboundResumeTaskPresentation _resumeTaskPresentation =
      const OutboundResumeTaskPresentation();
  Timer? _restoreTimer;
  bool _resumeChecking = false;
  bool _resumeCleanupRunning = false;
  bool _storageHealthScanning = false;
  bool _storageOverviewBusy = false;
  bool _mediaCopyAuditBusy = false;
  bool _historyLoadedForCleanup = false;
  final DiskCapacityGuard _diskCapacityGuard = const DiskCapacityGuard();
  int _preparingBatches = 0;
  String? _resumeJournalError;
  final ReceiveDirectoryPreference _receiveDirectoryPreference =
      ReceiveDirectoryPreference();
  Directory? _receiveDirectory;
  Directory? _defaultReceiveDirectory;

  String? error;
  final TransferHistoryStore historyStore = TransferHistoryStore();
  // Runtime-only request controls; no keys and no claims of encryption.
  final ReceiveGuard receiveGuard = ReceiveGuard();
  late final TrustedAutoReceivePolicy _autoReceivePolicy =
      TrustedAutoReceivePolicy(_pairIdentity.vault);
  String? _autoReceiveLoadError;
  bool _incomingDialogOpen = false;
  List<TransferRecord> history = [];
  HistoryFilter historyFilter = HistoryFilter.all;
  MobileTab mobileTab = MobileTab.nearby;
  DesktopTab desktopTab = DesktopTab.nearby;
  // DEV13B2: noncritical desktop details stay behind one-line preview strips.
  bool _rightIdleStatusOpen = false;
  bool _rightQueueOpen = false;
  bool _rightRecentOpen = false;
  // Device selection is only an in-app session, NOT a cryptographically verified pairing.
  String? _activePeerId;
  bool _dropHover = false;
  String? _activeTransferName;
  TransferProgressInfo? _outgoingProgress;
  TransferProgressInfo? _incomingProgress;
  DateTime? _lastProgressRenderAt;
  DateTime? _lastIncomingRenderAt;
  // DEV9B: signed pairing supplies trust for the encrypted chat transport.
  late final DeviceIdentityManager _pairIdentity = DeviceIdentityManager(
    const PlatformIdentityVault(),
  );
  BluetoothConnectionController? _bluetoothConnection;
  bool _connectionSheetOpen = false;
  bool _bluetoothFileBusy = false;
  ({String fingerprint, String peerName, String path, bool managed})?
  _bluetoothUnconfirmedSend;
  bool _workbenchFilePickerOpen = false;
  bool _bluetoothReceiveRootChanging = false;
  bool _useBluetoothText = false;
  String? _bluetoothHistoryLoadedFor;
  final Map<String, TextChatMessage> _bluetoothUnconfirmed = {};
  void _bluetoothStateChanged() {
    if (!mounted) return;
    setState(() {});
    final t = _bluetoothConnection?.transport;
    if (t?.authenticated == true &&
        t!.peerFingerprint.isNotEmpty &&
        _bluetoothHistoryLoadedFor != t.peerFingerprint) {
      _bluetoothHistoryLoadedFor = t.peerFingerprint;
      unawaited(_loadPeerTextHistory(t.peerFingerprint));
    }
  }

  BluetoothFileStore _windowsBluetoothFileStore(Directory inbox) =>
      BluetoothFileStore(
        inbox: inbox,
        work: Directory(
          '${inbox.path}${Platform.pathSeparator}.linyue_part_bt_e33',
        ),
        allowWindowsNestedWork: true,
        reliableResults: true,
        maxBytes: bluetoothBuildFileLimit(),
        commit: (temporary, offer) =>
            BluetoothFileStore.commitWindows(temporary, offer, inbox),
      );

  Future<bool> _approveBluetoothFile(BluetoothFileOffer offer) async {
    final t = _bluetoothConnection?.transport;
    if (!mounted ||
        !receiveGuard.receivingEnabled ||
        _incomingDialogOpen ||
        t?.authenticated != true ||
        !_pairIdentity.entries.any(
          (e) => e.fingerprint == t!.peerFingerprint,
        )) {
      return false;
    }
    final fingerprint = t!.peerFingerprint;
    _incomingDialogOpen = true;
    try {
      return await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF112B35),
                  title: const Text('蓝牙文件接收请求'),
                  content: Text(
                    '${t.peerName}\n${offer.name} · ${offer.size} 字节\n已验证身份 · 当前蓝牙文件传输不支持断点续传',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('拒绝'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('接收'),
                    ),
                  ],
                ),
              ) ==
              true &&
          mounted &&
          t.authenticated &&
          t.peerFingerprint == fingerprint &&
          receiveGuard.receivingEnabled;
    } finally {
      _incomingDialogOpen = false;
    }
  }

  Future<void> _receiveBluetoothFile(
    BluetoothFileOffer offer,
    File file,
  ) async {
    final t = _bluetoothConnection?.transport;
    if (!mounted || t?.authenticated != true) throw StateError('蓝牙接收会话已关闭');
    final fingerprint = t!.peerFingerprint;
    await _recordBluetoothTransfer(
      TransferRecord(
        name: file.uri.pathSegments.last,
        peerName: t.peerName,
        direction: 'receive',
        status: 'success',
        bytes: offer.size,
        timestamp: DateTime.now(),
        localPath: file.path,
        transport: 'bluetooth',
        peerFingerprint: fingerprint,
        transferId: offer.id,
        sha256: offer.sha256,
      ),
    );
    if (!mounted || !t.authenticated || t.peerFingerprint != fingerprint)
      throw StateError('蓝牙接收身份已改变');
    setState(() {
      if (!received.any((f) => f.path == file.path)) received.insert(0, file);
    });
    _toast('蓝牙接收完成：${offer.name}（SHA-256已校验）');
  }

  Future<void> _pickBluetoothSmallFile() async {
    final t = _bluetoothConnection?.transport;
    if (!(Platform.isWindows || Platform.isAndroid) ||
        !_useBluetoothText ||
        t?.fileSendReady != true ||
        _bluetoothFileBusy) {
      _toast('此方向蓝牙文件未就绪或对端不支持，不会改用局域网');
      return;
    }
    final fingerprint = t!.peerFingerprint;
    if (t.hasUnconfirmedFile) {
      await _confirmBluetoothFileResult();
      return;
    }
    final peerName = t.peerName;
    setState(() => _bluetoothFileBusy = true);
    File? source;
    BluetoothFileOffer? receipt;
    BluetoothSourceStage? stagedSource;
    try {
      final negotiatedMax = t.maxFileBytes;
      final files = await FilePicker.pickFiles(
        type: FileType.any,
        dialogTitle: '蓝牙单文件（最大${bluetoothFileLimitLabel(negotiatedMax)}）',
      );
      if (files.isEmpty) return;
      if (files.length != 1) {
        throw StateError('请选择一个文件');
      }
      if (!mounted ||
          !_useBluetoothText ||
          !identical(t, _bluetoothConnection?.transport) ||
          !t.fileSendReady ||
          t.peerFingerprint != fingerprint) {
        throw StateError('会话或通道已改变，请重新选择');
      }
      final fileName = bluetoothFileName(files.single.name);
      final size = await _checkedFileLength(files.single);
      if (size > negotiatedMax) {
        _toast(
          '蓝牙单文件超过双方协商上限${bluetoothFileLimitLabel(negotiatedMax)}，不会改走局域网',
        );
        return;
      }
      if (Platform.isAndroid) {
        stagedSource = await BluetoothSourceStage.create(
          root: await getTemporaryDirectory(),
          name: fileName,
          declaredSize: size,
          read: files.single.readAsByteStream,
          maxBytes: negotiatedMax,
        );
        source = await _retainOutgoingShareCopy(
          source: stagedSource.file,
          fileName: fileName,
          expectedBytes: size,
        );
      } else {
        if (files.single.path == null) throw StateError('请选择一个本地普通文件');
        source = File(files.single.path!);
        if (await source.length() > negotiatedMax) {
          _toast('蓝牙文件超过协商上限，不会改走局域网');
          return;
        }
      }
      if (!mounted ||
          !_useBluetoothText ||
          !identical(t, _bluetoothConnection?.transport) ||
          !t.fileSendReady ||
          t.peerFingerprint != fingerprint) {
        throw StateError('蓝牙身份或通道已改变，请重新选择');
      }
      receipt = await t.sendFile(source, name: fileName);
      try {
        await _recordBluetoothTransfer(
          TransferRecord(
            name: receipt.name,
            peerName: peerName,
            direction: 'send',
            status: 'success',
            bytes: receipt.size,
            timestamp: DateTime.now(),
            sourcePath: source.path,
            managedShareCopy: Platform.isAndroid,
            transport: 'bluetooth',
            peerFingerprint: fingerprint,
            transferId: receipt.id,
            sha256: receipt.sha256,
          ),
        );
      } catch (_) {
        if (mounted) _toast('对端已保存文件，但本机历史记录保存失败，请保留诊断。');
        return;
      }
      _toast('蓝牙文件已获对端最终确认：${receipt.name}');
    } catch (e) {
      if (t.hasUnconfirmedFile && source != null) {
        _bluetoothUnconfirmedSend = (
          fingerprint: fingerprint,
          peerName: peerName,
          path: source.path,
          managed: Platform.isAndroid,
        );
      }
      if (mounted)
        _toast(
          t.hasUnconfirmedFile
              ? '文件结果未确认，请点击核对结果；不会重复发送。'
              : bluetoothFileFailureMessage(e),
        );
    } finally {
      try {
        await stagedSource?.dispose();
      } catch (_) {
        service.logDiagnostic('蓝牙选择缓存清理未完成');
      }
      if (mounted) setState(() => _bluetoothFileBusy = false);
    }
  }

  Future<void> _confirmBluetoothFileResult() async {
    final t = _bluetoothConnection?.transport,
        pending = _bluetoothUnconfirmedSend;
    if (_bluetoothFileBusy ||
        t?.hasUnconfirmedFile != true ||
        pending == null ||
        !_useBluetoothText ||
        t!.peerFingerprint != pending.fingerprint) {
      _toast('原蓝牙会话不可核对，文件结果仍未确认。');
      return;
    }
    setState(() => _bluetoothFileBusy = true);
    try {
      final offer = await t.confirmFileResult();
      _bluetoothUnconfirmedSend = null;
      try {
        await _recordBluetoothTransfer(
          TransferRecord(
            name: offer.name,
            peerName: pending.peerName,
            direction: 'send',
            status: 'success',
            bytes: offer.size,
            timestamp: DateTime.now(),
            sourcePath: pending.path,
            managedShareCopy: pending.managed,
            transport: 'bluetooth',
            peerFingerprint: pending.fingerprint,
            transferId: offer.id,
            sha256: offer.sha256,
          ),
        );
      } catch (_) {
        if (mounted) _toast('对端已确认保存，但本机发送历史写入失败，请保留诊断。');
        return;
      }
      _toast('对端文件与接收记录已核验成功。');
    } catch (e) {
      if (mounted) _toast('文件结果仍未确认，请保留对端文件和诊断，不要重复发送。');
    } finally {
      if (mounted) setState(() => _bluetoothFileBusy = false);
    }
  }

  Future<void> _receiveBluetoothText(
    String fingerprint,
    TextChatMessage message,
  ) async {
    final t = _bluetoothConnection?.transport;
    if (!mounted ||
        t?.authenticated != true ||
        t!.peerFingerprint != fingerprint ||
        !_pairIdentity.entries.any((e) => e.fingerprint == fingerprint) ||
        !await _loadPeerTextHistory(fingerprint)) {
      throw StateError('Bluetooth authenticated history receiver unavailable');
    }
    final prior = (await _textHistoryRuntime!.store.loadPeer(
      fingerprint,
    )).where((e) => e.message.id == message.id).toList();
    if (prior.isNotEmpty &&
        (prior.single.outbound ||
            prior.single.message.body != message.body ||
            prior.single.message.createdAt != message.createdAt)) {
      throw StateError(
        'Bluetooth text ID conflicts with existing authenticated history',
      );
    }
    await _textHistoryRuntime!.store.saveConfirmed(
      authenticatedFingerprint: fingerprint,
      message: message,
      outbound: false,
    );
    _textTrialLedger.recordIncoming(
      authenticatedFingerprint: fingerprint,
      message: message,
    );
    if (mounted) _textTrialItems.value = _textTrialLedger.snapshot();
  }

  Future<void> _sendBluetoothText() async {
    final t = _bluetoothConnection?.transport;
    if (!_useBluetoothText || t?.textReady != true) {
      _toast('蓝牙文字通道未就绪或已断开；没有改用局域网发送');
      return;
    }
    await _sendTextTrial(
      peer: null,
      fingerprint: t!.peerFingerprint,
      draft: _textTrialDraft,
      bluetooth: true,
    );
  }

  InAppPairingService? _pairing;
  final SamePlatformLiveConnection _samePlatformConnections =
      SamePlatformLiveConnection();
  bool _pairingBusy = false;
  bool _pairingDialogOpen = false;
  String? _pairingError;
  final Set<String> _pairedPeerIds = {};
  // A peer ID alone is NOT identity; fingerprints are learned only from
  // an authenticated DEV8 SAS pairing or signed resume.
  final Map<String, String> _verifiedFingerprints = {};
  // Manual IPs are locators only; persistence never grants device trust.
  ManualPeerTargetStore? _manualPeerTargetStore;
  final Set<String> _manualPeerTargetIps = <String>{};
  // E22-C FIX2: transient failed reconnects permit explicit removal of a
  // non-responding discovery card; no trusted identity is ever deleted.
  final Set<String> _failedReconnectKeys = <String>{};
  final Set<String> _reconnectingKeys = <String>{};
  // E18-B: confirmed text is durable, encrypted at rest, and identity-scoped.
  final LiveTextTrialLedger _textTrialLedger = LiveTextTrialLedger(
    maxEntries: 1000,
  );
  final ValueNotifier<List<TrialTextItem>> _textTrialItems = ValueNotifier([]);
  final ValueNotifier<bool> _textTrialBusy = ValueNotifier(false);
  final TextEditingController _textTrialDraft = TextEditingController();
  // E21-B: one existing TransferHome/engine/queue/history. Mini is a compact
  // view of THIS owner and resizes the same native HWND, not another engine.
  final WindowsMiniChatSessionCoordinator _miniCoordinator =
      WindowsMiniChatSessionCoordinator();
  final WindowsMiniWindowBridge _miniWindow = WindowsMiniWindowBridge();
  bool _miniWindowPinned = false;
  String _miniSizePreset = 'medium';
  MiniWindowPreferences? _miniWindowPreferences;
  MiniWindowPreference _miniStoredPreference = const MiniWindowPreference();
  Future<void>? _miniPreferencesReady;
  Timer? _miniPositionPoll;
  bool _miniCaptureBusy = false;

  final FocusNode _conversationInputFocus = FocusNode(debugLabel: '邻跃文字输入');
  EncryptedTextHistoryRuntime? _textHistoryRuntime;
  String? _textHistoryStartupError;
  final Set<String> _loadedTextHistoryFingerprints = {};
  final Set<String> _blockedTextHistoryFingerprints = {};
  // If remote ACK succeeded but local disk commit failed, retry local commit
  // with the same message ID before allowing another network send.
  final Map<String, TextChatMessage> _acknowledgedAwaitingLocalSave = {};
  final Set<String> _historyRestoreInFlight = {};
  SecureFileChannel? _secureChannel;
  bool _secureReady = false;
  String? _secureStartupError;

  String _peerKey(NearPeer peer) => '${peer.id}|${peer.ip}';

  NearPeer? get _activePeer {
    // A single visible peer becomes the ready-to-send target automatically.
    // With several peers the user must choose the intended recipient.
    // Once explicitly selected, never silently switch to a different device.
    if (_activePeerId == null) {
      return service.peers.length == 1 ? service.peers.first : null;
    }
    for (final peer in service.peers) {
      if (peer.id == _activePeerId) return peer;
    }
    return null;
  }

  void _choosePeer(NearPeer peer) {
    if (_workbenchRouteLocked) return;
    if (_activePeer?.id != peer.id) _textTrialDraft.clear();
    setState(() {
      _activePeerId = peer.id;
      desktopTab = DesktopTab.nearby;
      mobileTab = MobileTab.nearby;
    });
    // Restore only an existing signed session. Selecting a device does not
    // silently start a new pairing prompt for an unknown identity.
    unawaited(_restorePeerTextHistoryIfResumable(peer));
  }

  Future<void> _restorePeerTextHistoryIfResumable(NearPeer peer) async {
    final key = _peerKey(peer);
    final known = _verifiedFingerprints[key];
    if (known != null) {
      await _loadPeerTextHistory(known, forceReload: true);
      return;
    }
    if (!_secureReady ||
        _pairing == null ||
        _historyRestoreInFlight.contains(key))
      return;
    _historyRestoreInFlight.add(key);
    try {
      final result = await _pairing!.tryResume(remoteIp: peer.ip);
      if (result == null ||
          !_pairIdentity.entries.any(
            (entry) => entry.fingerprint == result.fingerprint,
          ))
        return;
      if (!mounted) return;
      setState(() {
        _pairedPeerIds.add(peer.id);
        _verifiedFingerprints[key] = result.fingerprint;
      });
      service.recordDiscoverySignature(peer.ip, 'history_signed_resume');
      await _loadPeerTextHistory(result.fingerprint);
    } catch (_) {
      // History restore is best-effort; it must not pop up a new pairing dialog.
    } finally {
      _historyRestoreInFlight.remove(key);
    }
  }

  bool get isDesktop => MediaQuery.sizeOf(context).width >= 980;

  @override
  void initState() {
    super.initState();
    if (kDebugMode && (Platform.isAndroid || Platform.isWindows)) {
      _bluetoothConnection = BluetoothConnectionController(
        transport: BluetoothTransport(
          identity: _pairIdentity,
          server: Platform.isAndroid,
          androidPlatform: Platform.isAndroid,
          textEnabled: true,
          filesEnabled: true,
          reverseFilesEnabled: true,
        ),
      );
      _bluetoothConnection!.transport.onText = _receiveBluetoothText;
      _bluetoothConnection!.transport.approveFile = _approveBluetoothFile;
      _bluetoothConnection!.transport.onFileReceived = _receiveBluetoothFile;
      _bluetoothConnection!.transport.canReceiveText = () =>
          _textHistoryRuntime != null;
      _bluetoothConnection!.addListener(_bluetoothStateChanged);
    }
    _sendQueue = SerialTransferQueue<_SecureSendJob>(worker: _sendQueuedFile);
    _sendQueue.addListener(_onSendQueueChanged);
    final name = Platform.isWindows
        ? 'Windows · ${Platform.environment['COMPUTERNAME'] ?? '本机'}'
        : 'Android · 我的手机';
    service = NearLinkService(deviceName: name, allowLegacyFileTransfer: false);
    service.askReceiver = _confirmReceipt;
    service.receivedFile = (file) {
      if (!mounted) return;
      setState(() => received.insert(0, file));
      _toast('接收成功：${file.uri.pathSegments.last}');
      // The v0.1 protocol callback provides the saved File, not sender identity.
      Future<void>.microtask(() => _recordReceived(file));
      unawaited(_autoArchiveReceivedMedia(file));
    };
    if (Platform.isWindows) {
      _miniPreferencesReady = _loadWindowsMiniWindowPreferences();
    }
    Future<void>.microtask(_startup);
  }

  // E21-C1: window geometry is non-sensitive UI data, separately stored in
  // application support. The main app and secure session remain unchanged.
  Future<void> _loadWindowsMiniWindowPreferences() async {
    try {
      final support = await getApplicationSupportDirectory();
      final store = MiniWindowPreferences(
        Directory('${support.path}${Platform.pathSeparator}LinYueMiniWindow'),
      );
      final loaded = await store.load();
      if (!mounted) return;
      _miniWindowPreferences = store;
      _miniStoredPreference = loaded;
      _miniSizePreset = loaded.preset;
    } catch (_) {
      // Damaged/missing UI preferences must never prevent app startup.
    }
  }

  Future<void> _persistWindowsMiniPlacement() async {
    if (!Platform.isWindows || !_miniCoordinator.visible || _miniCaptureBusy)
      return;
    _miniCaptureBusy = true;
    try {
      final placement = await _miniWindow.getSnapshot();
      if (placement == null || !_miniCoordinator.visible) return;
      final updated = MiniWindowPreference(
        preset: placement.preset,
        saved: placement,
      );
      if (updated == _miniStoredPreference) return;
      final store = _miniWindowPreferences;
      if (store == null) return;
      await store.save(updated);
      _miniStoredPreference = updated;
    } catch (_) {
      // Best effort: do not corrupt or reset chat history for window UI data.
    } finally {
      _miniCaptureBusy = false;
    }
  }

  Future<void> _resizeWindowsMiniChat(String preset) async {
    if (!Platform.isWindows || !_miniCoordinator.visible) return;
    if (!await _miniWindow.resizeMini(preset)) {
      if (mounted) _toast('迷你窗口尺寸调整失败');
      return;
    }
    if (!mounted) return;
    setState(() => _miniSizePreset = preset);
    await _persistWindowsMiniPlacement();
  }

  Future<void> _initializeEncryptedTextHistory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}LinYueEncryptedTextHistory',
    );
    final runtime = EncryptedTextHistoryRuntime(
      vault: _pairIdentity.vault,
      directory: directory,
    );
    await runtime.initialize();
    _textHistoryRuntime = runtime;
    _textHistoryStartupError = null;
  }

  Future<void> _startup() async {
    final startupClock = Stopwatch()..start();

    // DEV13D2E5: bring LAN discovery online before local history/journal audits.
    // Discovery is not a trust signal and does not enable plaintext transfer.
    try {
      await service.start();
      service.logDiagnostic(
        '启动诊断：设备发现服务已就绪（${startupClock.elapsedMilliseconds} ms）',
      );
      // Restore saved manual IP locators for the fallback path. These addresses
      // are never considered paired identities; secure signed resume is still required.
      await _restoreManualPeerTargets();
    } catch (e) {
      if (mounted) setState(() => error = '设备发现启动失败：$e');
      service.logDiagnostic('启动诊断：设备发现启动失败：$e');
    }

    service.logDiagnostic('启动诊断：开始读取本地历史');
    try {
      await historyStore.load();
      _historyLoadedForCleanup = true;
      if (mounted) setState(() => history = historyStore.records);
      unawaited(_pruneOutboundShareCache());
      service.logDiagnostic(
        '启动诊断：本地历史加载完成（${startupClock.elapsedMilliseconds} ms）',
      );
    } catch (e) {
      _toast('读取本地传输历史失败：$e');
    }

    try {
      final appDocs = await getApplicationDocumentsDirectory();
      _defaultReceiveDirectory = Directory(
        '${appDocs.path}${Platform.pathSeparator}NearLinkReceived',
      );
      _receiveDirectory = await _receiveDirectoryPreference.load(
        _defaultReceiveDirectory!,
      );
      if ((Platform.isAndroid || Platform.isWindows) &&
          _bluetoothConnection != null) {
        await _receiveDirectory!.create(recursive: true);
        final inbox = _receiveDirectory!;
        _bluetoothConnection!.transport.fileStore = Platform.isAndroid
            ? BluetoothFileStore(
                inbox: inbox,
                work: Directory(
                  '${appDocs.path}${Platform.pathSeparator}LinYueBluetoothE32',
                ),
                reliableResults: true,
                maxBytes: bluetoothBuildFileLimit(),
              )
            : _windowsBluetoothFileStore(inbox);
      }

      // Sender sources stay in app-private Documents, not the picker cache.
      // A damaged journal is NEVER overwritten silently.
      service.logDiagnostic(
        '启动诊断：开始检查断点续传记录（${startupClock.elapsedMilliseconds} ms）',
      );
      try {
        final privateRoot = await getApplicationSupportDirectory();
        final folder = Directory(
          '${privateRoot.path}${Platform.pathSeparator}LinYueOutboundResume',
        );
        final controller = OutboundResumeController(
          journal: OutboundResumeJournal(folder),
          sourcesDirectory: Directory(
            '${folder.path}${Platform.pathSeparator}sources',
          ),
        );
        // DEV12-D4B2: finish only durable cleanup intents, then inspect
        // remaining sources READ-ONLY before allowing any auto-requeue.
        final replay = await controller.reconcileCleanupIntents();
        final loaded = await controller.load();
        final audit = await OutboundConsistencyAudit(
          journal: controller.journal,
          sourcesDirectory: controller.sourcesDirectory,
        ).inspect();
        final blocked = <String>{
          for (final issue in audit.issues)
            if (issue.taskId != null) issue.taskId!,
        };
        final globalUnsafe =
            audit.has(OutboundAuditCode.unsafeStagingRoot) ||
            audit.has(OutboundAuditCode.stagingRootMissing) ||
            audit.has(OutboundAuditCode.journalUnreadable);
        final safe = <OutboundResumeRecord>[
          for (final record in loaded)
            if (!globalUnsafe &&
                !blocked.contains(record.taskId) &&
                record.status != OutboundResumeStatus.cleanupPending)
              record,
        ];
        _outboundController = controller;
        if (mounted) setState(() => _pendingRestores = safe);
        final withheld = loaded.length - safe.length;
        if (withheld > 0 || replay.failed > 0) {
          _toast(
            '已暂停 $withheld 项异常恢复任务；'
            '${replay.failed} 项清理待人工核对，请查看存储体检。',
          );
        }
        service.logDiagnostic(
          '启动诊断：断点续传检查完成（${startupClock.elapsedMilliseconds} ms）',
        );
      } catch (e) {
        _resumeJournalError = '$e';
        _toast('未完成任务记录不可用；大文件已安全停止：$e');
        service.logDiagnostic(
          '启动诊断：断点续传检查异常（${startupClock.elapsedMilliseconds} ms）',
        );
      }
      await _reloadReceivedFiles();
      service.logDiagnostic(
        '启动诊断：接收文件列表加载完成（${startupClock.elapsedMilliseconds} ms）',
      );
    } catch (e) {
      if (mounted) setState(() => error = '启动失败：$e');
    }

    // Identity failures never enable plaintext transfer; discovery remains available.
    try {
      service.logDiagnostic(
        '启动诊断：开始身份初始化（${startupClock.elapsedMilliseconds} ms）',
      );
      await _pairIdentity.initialize();
      service.logDiagnostic(
        '启动诊断：身份初始化完成（${startupClock.elapsedMilliseconds} ms）',
      );
      // E18-B: create/load the AES-256 key only in platform secure storage.
      // Failure blocks text history and text ACKs, but leaves file transfer alone.
      try {
        await _initializeEncryptedTextHistory();
        service.logDiagnostic('启动诊断：本机加密聊天历史就绪');
      } catch (e) {
        _textHistoryStartupError = '$e';
        service.logDiagnostic('启动诊断：本机加密聊天历史不可用：$e');
        _toast('本机加密聊天历史不可用，文字收发暂不可用；文件传输不受影响。');
      }
      // An invalid or inaccessible grant store must NEVER auto-accept.
      try {
        await _autoReceivePolicy.load();
        _autoReceiveLoadError = null;
      } catch (e) {
        _autoReceiveLoadError = '$e';
        _toast('自动接收授权无法读取，文件将逐次询问：$e');
      }
      if (!mounted) return;
      final pairing = InAppPairingService(
        _pairIdentity,
        deviceName: service.deviceName,
      );
      pairing.onIncomingRequest = _showPairingPrompt;
      pairing.onPaired = (result) {
        if (!mounted) return;
        service.recordDiscoverySignature(
          result.remoteIp,
          'signed_pairing_callback',
        );
        final activeBefore = _activePeer;
        final shouldSelect = AuthenticatedPeerBindingPolicy.shouldSelectPeer(
          activePeerIp: activeBefore?.ip,
          remoteIp: result.remoteIp,
        );
        var matchingPeers = service.peers
            .where((peer) => peer.ip == result.remoteIp)
            .toList();
        var manualTargetsChanged = false;
        // Discovery can be unavailable while a valid signed pairing over a
        // manually entered IP succeeds. Create a locator so the authenticated
        // message history has a concrete conversation to bind to.
        if (AuthenticatedPeerBindingPolicy.shouldCreateManualLocator(
              knownPeerIps: service.peers.map((peer) => peer.ip),
              authenticatedRemoteIp: result.remoteIp,
            ) &&
            SamePlatformConnectionPolicy.isPlausibleLanAddress(
              result.remoteIp,
            )) {
          try {
            service.addManualPeer(result.remoteIp);
            manualTargetsChanged =
                _manualPeerTargetIps.add(result.remoteIp) ||
                manualTargetsChanged;
          } catch (e) {
            service.logDiagnostic('签名配对完成，但本机设备条目绑定失败：$e');
          }
          matchingPeers = service.peers
              .where((peer) => peer.ip == result.remoteIp)
              .toList();
        }
        // Persist only manual locators. Discovery identities and display names
        // remain untrusted and cannot authorize future transfers.
        if (matchingPeers.any((peer) => peer.isManual)) {
          manualTargetsChanged =
              _manualPeerTargetIps.add(result.remoteIp) || manualTargetsChanged;
        }
        if (manualTargetsChanged) unawaited(_persistManualPeerTargets());
        setState(() {
          for (final peer in matchingPeers) {
            _pairedPeerIds.add(peer.id);
            _verifiedFingerprints[_peerKey(peer)] = result.fingerprint;
          }
          if (shouldSelect && matchingPeers.isNotEmpty) {
            _activePeerId = matchingPeers.first.id;
          }
        });
        // Load the authenticated identity's history even when the current view
        // remains on another peer; the timeline still filters by fingerprint.
        unawaited(_loadPeerTextHistory(result.fingerprint));
        service.logDiagnostic('签名配对完成：已绑定 ${matchingPeers.length} 个本机设备条目');
        _toast('身份已登记：${result.remoteName}，可使用安全传输');
      };
      await pairing.start();
      _pairing = pairing;
      service.logDiagnostic(
        '启动诊断：配对服务就绪（${startupClock.elapsedMilliseconds} ms）',
      );
      // Start only after the OS identity has been loaded. No insecure fallback
      // exists if secure startup fails or this port is unavailable.
      final encryptedReceiver = SecureFileChannel(
        _pairIdentity,
        targetDirectory: _receiveDirectory ?? _defaultReceiveDirectory!,
        receiveDiskGuard: _diskCapacityGuard,
      );
      encryptedReceiver.askReceiver = _confirmSecureReceipt;
      encryptedReceiver.onIncomingProgress = (update) {
        if (!mounted) return;
        final now = DateTime.now();
        if (_lastIncomingRenderAt == null ||
            now.difference(_lastIncomingRenderAt!).inMilliseconds >= 150 ||
            update.phase != _incomingProgress?.phase ||
            update.transferredBytes == update.totalBytes) {
          _lastIncomingRenderAt = now;
          setState(() => _incomingProgress = update);
        }
      };
      encryptedReceiver.onStorageWarning = (message) {
        if (mounted) _toast('接收前容量检查：$message');
      };
      encryptedReceiver.onVerifiedReceived = (file, fingerprint) {
        if (!mounted) return;
        setState(() => received.insert(0, file));
        final peerName =
            _pairIdentity.entries
                .where((entry) => entry.fingerprint == fingerprint)
                .map((entry) => entry.name)
                .firstOrNull ??
            '已验证设备';
        _toast('已加密接收：${file.uri.pathSegments.last}');
        unawaited(_autoArchiveReceivedMedia(file));
        Future<void>.microtask(
          () => _recordTransfer(
            TransferRecord(
              name: file.uri.pathSegments.last,
              peerName: peerName,
              direction: 'receive',
              status: 'success',
              bytes: file.lengthSync(),
              timestamp: DateTime.now(),
              localPath: file.path,
            ),
          ),
        );
      };
      // E18-B: ACK only after authenticated local encrypted-history commit.
      // Duplicate IDs already committed locally are safe to ACK idempotently.
      encryptedReceiver
          .onVerifiedTextMessage = (message, authenticatedFingerprint) async {
        if (!mounted ||
            _textHistoryRuntime == null ||
            !_pairIdentity.entries.any(
              (entry) => entry.fingerprint == authenticatedFingerprint,
            )) {
          return false;
        }
        if (!await _loadPeerTextHistory(authenticatedFingerprint)) return false;
        try {
          final inserted = await _textHistoryRuntime!.store.saveConfirmed(
            authenticatedFingerprint: authenticatedFingerprint,
            message: message,
            outbound: false,
          );
          final displayed = _textTrialLedger.recordIncoming(
            authenticatedFingerprint: authenticatedFingerprint,
            message: message,
          );
          if (mounted) _textTrialItems.value = _textTrialLedger.snapshot();
          if (inserted && displayed && mounted) _toast('收到并加密保存文字消息');
          return true;
        } catch (e) {
          if (e is FormatException || e is StateError) {
            _blockedTextHistoryFingerprints.add(authenticatedFingerprint);
          }
          if (mounted) _toast('本机文字历史保存失败，未向对端确认接收：$e');
          return false;
        }
      };
      await encryptedReceiver.start();
      _secureChannel = encryptedReceiver;
      if (mounted)
        setState(() {
          _secureReady = true;
          _secureStartupError = null;
          _pairingError = null;
        });
      service.logDiagnostic(
        '启动诊断：加密接收服务就绪（${startupClock.elapsedMilliseconds} ms）',
      );
      // Recover only tasks already authorized by the sender, and only after
      // a new signed proof of the exact registered receiver identity.
      _restoreTimer ??= Timer.periodic(
        const Duration(seconds: 9),
        (_) => unawaited(_restorePending()),
      );
      unawaited(_restorePending());
      final startupPeer = _activePeer;
      if (startupPeer != null) {
        unawaited(_restorePeerTextHistoryIfResumable(startupPeer));
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _pairingError = '$e';
          _secureStartupError = '$e';
          _secureReady = false;
        });
      service.logDiagnostic(
        '启动诊断：身份或加密服务初始化失败（${startupClock.elapsedMilliseconds} ms）',
      );
    }
  }

  // Only an already signature-authenticated, registered identity can use an
  // explicit receiver-side auto-accept grant. IP/name alone never qualify.
  Future<bool> _confirmSecureReceipt(SecureIncomingOffer incoming) async {
    if (!mounted || !_secureReady) return false;
    final registered = _pairIdentity.entries.any(
      (entry) => entry.fingerprint == incoming.fingerprint,
    );
    if (!registered ||
        !TrustedAutoReceivePolicy.isFingerprint(incoming.fingerprint)) {
      return false;
    }
    // Pause and temporary blocks override all saved grants.
    final guardDecision = receiveGuard.check(incoming.remoteIp);
    if (guardDecision != ReceiveDecision.prompt) return false;
    if (_autoReceivePolicy.mayAutoAccept(
      incoming.fingerprint,
      authenticatedRegisteredIdentity: registered,
      receivingAllowed: receiveGuard.receivingEnabled,
    )) {
      receiveGuard.noteAccepted(incoming.remoteIp);
      return true;
    }
    return _confirmReceipt(
      FileOffer(
        name: incoming.fileName,
        size: incoming.size,
        senderName: incoming.peerName,
        remoteIp: incoming.remoteIp,
      ),
      encrypted: true,
      verifiedFingerprint: incoming.fingerprint,
    );
  }

  Future<bool> _showPairingPrompt(PairingPrompt request) async {
    if (!mounted || _pairingDialogOpen) return false;
    _pairingDialogOpen = true;
    try {
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF102C37),
          title: Text(request.incoming ? '来自附近设备的首次配对' : '核对设备配对码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(request.remoteName, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                request.comparisonCode.substring(0, 3) +
                    ' ' +
                    request.comparisonCode.substring(3),
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                  color: Color(0xFF91E6DF),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '确认手机和电脑显示的数字完全相同，再按“数字相同”。\n'
                '无需输入号码，也不需要微信或复制身份卡。',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.5),
              ),
              const SizedBox(height: 10),
              const Text(
                '首次验证成功后，文件会通过安全通道传输；旧明文入口已关闭。',
                style: TextStyle(color: Color(0xFFF2B84B), fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('不一致 / 取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('数字相同，确认'),
            ),
          ],
        ),
      );
      return result == true;
    } finally {
      _pairingDialogOpen = false;
    }
  }

  /// Load the authenticated peer's durable history into the current bounded UI ledger.
  /// Corrupt ciphertext/key mismatch fails closed; it is never auto-cleared.
  Future<bool> _loadPeerTextHistory(
    String fingerprint, {
    bool forceReload = false,
  }) async {
    if (_blockedTextHistoryFingerprints.contains(fingerprint)) return false;
    if (!forceReload && _loadedTextHistoryFingerprints.contains(fingerprint))
      return true;
    final runtime = _textHistoryRuntime;
    if (runtime == null) {
      if (mounted)
        _toast(
          '本机加密聊天历史不可用，文字收发已暂停：'
          '${_textHistoryStartupError ?? '安全存储尚未就绪'}',
        );
      return false;
    }
    try {
      final records = await runtime.store.loadPeer(fingerprint);
      for (final item in records) {
        if (item.outbound) {
          _textTrialLedger.recordOutgoingConfirmed(
            authenticatedFingerprint: fingerprint,
            message: item.message,
          );
        } else {
          _textTrialLedger.recordIncoming(
            authenticatedFingerprint: fingerprint,
            message: item.message,
          );
        }
      }
      _loadedTextHistoryFingerprints.add(fingerprint);
      if (mounted) _textTrialItems.value = _textTrialLedger.snapshot();
      return true;
    } catch (e) {
      if (e is FormatException || e is StateError) {
        _blockedTextHistoryFingerprints.add(fingerprint);
      }
      if (mounted)
        _toast(
          '无法验证该设备的本机加密聊天历史，文字收发已暂停；'
          '不会自动清空记录，文件传输仍可使用。',
        );
      return false;
    }
  }

  // DEV13D2E18-C. Local text-only deletion; file history and received media
  // are stored elsewhere and MUST NOT be touched by these operations.
  Future<void> _manageLocalTextHistory(NearPeer peer) async {
    final fingerprint = _verifiedFingerprints[_peerKey(peer)];
    if (fingerprint == null ||
        !_pairIdentity.entries.any(
          (entry) => entry.fingerprint == fingerprint,
        )) {
      _toast('请先完成设备身份验证，再管理本机文字历史');
      return;
    }
    if (_textTrialBusy.value ||
        _acknowledgedAwaitingLocalSave.containsKey(fingerprint)) {
      _toast('存在文字发送或待补存任务，请处理完成后再管理历史');
      return;
    }
    if (_blockedTextHistoryFingerprints.contains(fingerprint)) {
      _toast('加密文字历史校验失败，已禁止修改原始记录');
      return;
    }
    final runtime = _textHistoryRuntime;
    if (runtime == null) {
      _toast('本机加密文字历史尚未就绪');
      return;
    }
    late final List<PersistedTextItem> items;
    try {
      items = await runtime.store.loadPeer(fingerprint);
    } catch (_) {
      _blockedTextHistoryFingerprints.add(fingerprint);
      _toast('本机加密文字历史无法验证，拒绝删除且保留原始数据');
      return;
    }
    if (!mounted) return;
    if (items.isEmpty) {
      _toast('当前设备没有可管理的本机文字历史');
      return;
    }
    final chosen = <String>{};
    // true = all for this peer; false = selected IDs; null = cancelled.
    final all = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, updateDialog) => AlertDialog(
          title: const Text('本机文字历史管理'),
          content: SizedBox(
            width: 460,
            height: math.min(470.0, 104.0 + items.length * 65.0),
            child: Column(
              children: [
                const Text(
                  '仅删除本机当前认证设备的文字记录；不会删除对方消息、文件历史、接收文件或系统相册内容。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (c, i) {
                      final entry = items[i];
                      final id = entry.message.id;
                      return CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: chosen.contains(id),
                        title: Text(
                          entry.message.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${entry.outbound ? '已发送' : '已接收'} · '
                          '${_historyTimestamp(entry.message.createdAt)}',
                        ),
                        onChanged: (enabled) => updateDialog(() {
                          if (enabled == true) {
                            chosen.add(id);
                          } else {
                            chosen.remove(id);
                          }
                        }),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('清空本设备文字'),
            ),
            FilledButton(
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: Text('删除选中 (${chosen.length})'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || all == null) return;
    final removalCount = all ? items.length : chosen.length;
    if (removalCount == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除本机文字历史？'),
        content: Text(
          '本次将仅在当前设备本地删除 $removalCount 条文字记录。'
          '对方设备不会同步删除。删除后无法从本机历史恢复，文件和图库不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_textTrialBusy.value ||
        _acknowledgedAwaitingLocalSave.containsKey(fingerprint) ||
        _blockedTextHistoryFingerprints.contains(fingerprint)) {
      _toast('发送状态已改变，取消删除以保护消息记录');
      return;
    }
    try {
      // E18-A store serializes all read/write operations per instance.
      if (all) {
        await runtime.store.clearPeer(fingerprint);
      } else {
        await runtime.store.deleteMessages(
          authenticatedFingerprint: fingerprint,
          messageIds: Set<String>.of(chosen),
        );
      }
      // Rebuild the ephemeral UI cache from committed encrypted history.
      _textTrialLedger.removePeer(authenticatedFingerprint: fingerprint);
      _loadedTextHistoryFingerprints.remove(fingerprint);
      final restored = await _loadPeerTextHistory(
        fingerprint,
        forceReload: true,
      );
      if (mounted)
        _toast(restored ? '本机文字历史删除完成（不影响对方或文件）' : '本地删除已提交，但刷新失败；请重新打开会话核查');
    } catch (_) {
      _toast('文字历史删除失败；未清理缓存，原始加密数据已保留');
    }
  }

  Future<String> _ensureSecureIdentity(NearPeer peer) async {
    if (!_secureReady || _secureChannel == null || _pairing == null) {
      throw StateError(
        '安全传输尚未就绪：${_secureStartupError ?? _pairingError ?? '等待初始化'}',
      );
    }
    final key = _peerKey(peer);
    final previous = _verifiedFingerprints[key];
    if (previous != null &&
        _pairIdentity.entries.any((entry) => entry.fingerprint == previous)) {
      if (!await _loadPeerTextHistory(previous)) {
        throw StateError('本机加密聊天历史不可用，文字发送已暂停');
      }
      return previous;
    }
    if (_pairingBusy && !_samePlatformConnections.isConnecting(peer.ip)) {
      throw StateError('正在配对其他设备，请稍候');
    }
    setState(() => _pairingBusy = true);
    try {
      // This transparent proof is not a new human pairing prompt.
      // Only unknown identities enter the DEV8 six-digit double confirmation.
      final pairing = _pairing!;
      final result = await _samePlatformConnections.resolve(
        remoteIp: peer.ip,
        localFingerprint: _pairIdentity.local.fingerprint,
        secureChannelReady: _secureReady && _secureChannel != null,
        isRegistered: (fingerprint) => _pairIdentity.entries.any(
          (entry) => entry.fingerprint == fingerprint,
        ),
        trySignedResume: () => pairing.tryResume(remoteIp: peer.ip),
        initiateSignedPairing: () => pairing.initiate(
          remoteIp: peer.ip,
          remoteName: peer.name,
          confirm: _showPairingPrompt,
        ),
      );
      if (!_pairIdentity.entries.any(
        (e) => e.fingerprint == result.fingerprint,
      )) {
        throw StateError('身份未登记，禁止发送');
      }
      if (mounted)
        setState(() {
          _pairedPeerIds.add(peer.id);
          _verifiedFingerprints[key] = result.fingerprint;
        });
      service.recordDiscoverySignature(peer.ip, 'secure_operation_preflight');
      if (!await _loadPeerTextHistory(result.fingerprint)) {
        throw StateError('本机加密聊天历史不可用，文字发送已暂停');
      }
      return result.fingerprint;
    } finally {
      if (mounted) setState(() => _pairingBusy = false);
    }
  }

  // E18-B: the unified composer now commits confirmed text to encrypted local history.
  Future<void> _sendInlineText(NearPeer peer) async {
    if (_useBluetoothText) {
      await _sendBluetoothText();
      return;
    }
    if (_textTrialBusy.value) return;
    final originalText = _textTrialDraft.text;
    if (!ConversationTextProtocol.isValidBody(originalText)) {
      _toast('请输入文字，最多 8 KiB UTF-8，不能包含控制字符');
      return;
    }
    final String fingerprint;
    try {
      fingerprint = await _ensureSecureIdentity(peer);
    } catch (e) {
      _toast('加密身份验证失败：$e');
      return;
    }
    if (!mounted) return;
    // Recheck after an asynchronous pairing prompt: never send a draft to a
    // different active peer just because the user switched sessions.
    if (_useBluetoothText ||
        _activePeer?.id != peer.id ||
        _textTrialDraft.text != originalText) {
      _toast('会话或文字已改变，请核对后重新发送');
      return;
    }
    await _sendTextTrial(
      peer: peer,
      fingerprint: fingerprint,
      draft: _textTrialDraft,
    );
  }

  bool get _workbenchRouteLocked {
    final p = _bluetoothConnection?.transport.fileProgress;
    final activeFile =
        p != null && !p.phase.startsWith('成功') && !p.phase.startsWith('失败');
    return _workbenchFilePickerOpen ||
        _bluetoothFileBusy ||
        _textTrialBusy.value ||
        sending ||
        activeFile;
  }

  void _selectWorkbenchRoute(bool bluetooth) {
    if (_workbenchRouteLocked || _useBluetoothText == bluetooth) return;
    setState(() => _useBluetoothText = bluetooth);
    if (bluetooth && _bluetoothConnection?.transport.active != true)
      unawaited(_showConnectionMethods());
  }

  Future<void> _addWorkbenchFile() async {
    if (_workbenchFilePickerOpen) return;
    final bluetooth = _useBluetoothText;
    final peer = _activePeer;
    if (!bluetooth && peer == null) return;
    setState(() {
      _workbenchFilePickerOpen = true;
      if (!bluetooth) _activePeerId = peer!.id;
    });
    try {
      if (bluetooth) {
        await _pickBluetoothSmallFile();
      } else if (Platform.isAndroid) {
        await _showAndroidAddFileSources();
      } else {
        await _pickFilesForActivePeer();
      }
    } finally {
      if (mounted) setState(() => _workbenchFilePickerOpen = false);
    }
  }

  Widget _unifiedTextComposer(NearPeer? peer, {required bool mobile}) {
    final canText = _useBluetoothText
        ? _bluetoothConnection?.transport.textReady == true
        : peer != null;
    return ValueListenableBuilder<bool>(
      valueListenable: _textTrialBusy,
      builder: (context, busy, _) => WorkbenchComposer(
        draft: _textTrialDraft,
        focus: _conversationInputFocus,
        canText: canText,
        busy: busy,
        mobile: mobile,
        onAddFile: _workbenchFilePickerOpen || _bluetoothFileBusy
            ? null
            : (_useBluetoothText
                  ? _bluetoothConnection?.transport.fileSendReady == true
                  : peer != null)
            ? _addWorkbenchFile
            : null,
        onSend: () =>
            _useBluetoothText ? _sendBluetoothText() : _sendInlineText(peer!),
      ),
    );
  }

  // E20-C2: a text bubble may be deleted ONLY from local authenticated
  // encrypted history. The remote peer's text and all file data remain intact.
  Future<void> _deleteOneLocalTextMessage(TrialTextItem item) async {
    final active = _activePeer;
    final fingerprint = item.authenticatedFingerprint;
    if (active == null ||
        _verifiedFingerprints[_peerKey(active)] != fingerprint ||
        !_pairIdentity.entries.any((e) => e.fingerprint == fingerprint)) {
      _toast('当前会话身份无法验证，不能删除该文字');
      return;
    }
    if (_textTrialBusy.value ||
        _acknowledgedAwaitingLocalSave.containsKey(fingerprint)) {
      _toast('当前有文字发送或待补存任务，请稍后再删除');
      return;
    }
    if (_blockedTextHistoryFingerprints.contains(fingerprint)) {
      _toast('本机加密文字历史校验异常，禁止删除');
      return;
    }
    final runtime = _textHistoryRuntime;
    if (runtime == null || !await _loadPeerTextHistory(fingerprint)) {
      _toast('本机加密文字历史尚未就绪，不能删除');
      return;
    }
    // Confirm record existence before offering destructive action.
    try {
      final saved = await runtime.store.loadPeer(fingerprint);
      if (!saved.any((e) => e.message.id == item.message.id)) {
        _toast('这条文字不在本机加密历史中，无法删除');
        return;
      }
    } catch (e) {
      _blockedTextHistoryFingerprints.add(fingerprint);
      _toast('读取文字历史失败，原始记录已保留：$e');
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条文字？'),
        content: const Text(
          '只删除本机当前认证会话中的这一条加密文字记录；'
          '不会删除对方设备上的文字，也不会影响任何文件。删除后不可从本机恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除本机文字'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final current = _activePeer;
    if (current == null ||
        _verifiedFingerprints[_peerKey(current)] != fingerprint ||
        _textTrialBusy.value ||
        _acknowledgedAwaitingLocalSave.containsKey(fingerprint) ||
        _blockedTextHistoryFingerprints.contains(fingerprint)) {
      _toast('设备身份或发送状态已变化，取消删除');
      return;
    }
    try {
      final removed = await runtime.store.deleteMessages(
        authenticatedFingerprint: fingerprint,
        messageIds: {item.message.id},
      );
      if (removed == 0) {
        _toast('文字已不存在，无需重复删除');
        return;
      }
      _textTrialLedger.removePeer(authenticatedFingerprint: fingerprint);
      _loadedTextHistoryFingerprints.remove(fingerprint);
      final reloaded = await _loadPeerTextHistory(
        fingerprint,
        forceReload: true,
      );
      if (mounted)
        _toast(reloaded ? '已删除本机文字记录（对方不会同步删除）' : '删除已提交，界面刷新失败，请重新打开会话');
    } catch (e) {
      if (e is FormatException || e is StateError) {
        _blockedTextHistoryFingerprints.add(fingerprint);
      }
      if (mounted) _toast('删除失败，未主动清除缓存：$e');
    }
  }

  Future<void> _showTextBubbleActions(TrialTextItem item) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('文字操作')),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制文字'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: item.message.body));
                _toast('文字已复制');
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Color(0xFFFF9C9C),
              ),
              title: const Text('删除本机文字记录'),
              subtitle: const Text('只删除本机，不影响对方'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_deleteOneLocalTextMessage(item));
              },
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  // Directional icons only; legacy file history cannot prove sender identity.
  Widget _conversationDeviceAvatar({
    required bool outbound,
    required bool mobile,
  }) {
    final phone = ChatCardDisplayPolicy.showPhoneAvatar(
      isAndroidClient: Platform.isAndroid,
      outbound: outbound,
    );
    final icon = phone
        ? Icons.smartphone_rounded
        : Icons.desktop_windows_rounded;
    return Tooltip(
      message: outbound ? '本机消息' : '对方消息',
      child: Container(
        width: mobile ? 30 : 28,
        height: mobile ? 30 : 28,
        decoration: BoxDecoration(
          color: outbound ? const Color(0xFF205B60) : const Color(0xFF173540),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0x886AD0CA)),
        ),
        child: Icon(
          icon,
          size: mobile ? 18 : 17,
          color: const Color(0xFFC5F3EE),
        ),
      ),
    );
  }

  Widget _conversationTimeLabel(DateTime date, {required bool outbound}) =>
      Padding(
        padding: const EdgeInsets.only(top: 4, left: 3, right: 3),
        child: Text(
          ChatCardDisplayPolicy.clock(date),
          style: const TextStyle(fontSize: 10, color: Color(0xFFA9C0C3)),
        ),
      );

  Widget _conversationTextActionsButton(TrialTextItem item) => IconButton(
    tooltip: '文字操作',
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 30, height: 30),
    onPressed: () => unawaited(_showTextBubbleActions(item)),
    icon: const Icon(
      Icons.more_horiz_rounded,
      size: 19,
      color: Color(0xFFC2F4EF),
    ),
  );

  Widget _conversationTextBubble(TrialTextItem item, {required bool mobile}) {
    final outgoing = item.outbound;
    final avatar = _conversationDeviceAvatar(
      outbound: outgoing,
      mobile: mobile,
    );
    // DEV13D2E20-C3A FIX1: SelectableText owns long-press/drag selection.
    // More actions are deliberately separate, so selection and deletion
    // cannot compete for the same long-press gesture.
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: mobile ? 240 : 380),
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
      decoration: BoxDecoration(
        color: outgoing ? const Color(0xFF205A5B) : const Color(0xFF173743),
        border: Border.all(color: const Color(0x6657CFC8)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SelectableText(
        item.message.body,
        contextMenuBuilder:
            ChatSelectionAndActionsPolicy.buildChineseSelectionToolbar,
      ),
    );
    final message = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: outgoing
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        // Keep the actions on the inward side, opposite the avatar.
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (ChatSelectionAndActionsPolicy.actionsBeforeBubble(
              outbound: outgoing,
            )) ...[
              _conversationTextActionsButton(item),
              const SizedBox(width: 2),
            ],
            Flexible(child: bubble),
            if (!ChatSelectionAndActionsPolicy.actionsBeforeBubble(
              outbound: outgoing,
            )) ...[
              const SizedBox(width: 2),
              _conversationTextActionsButton(item),
            ],
          ],
        ),
        _conversationTimeLabel(item.message.createdAt, outbound: outgoing),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 5),
      child: Row(
        mainAxisAlignment: outgoing
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!outgoing) ...[avatar, const SizedBox(width: 7)],
          Flexible(child: message),
          if (outgoing) ...[const SizedBox(width: 7), avatar],
        ],
      ),
    );
  }

  Widget _mixedConversationItems({
    required NearPeer? peer,
    required bool mobile,
    required List<TransferRecord> files,
    required List<TransferProgressInfo> live,
  }) {
    if (_useBluetoothText) {
      final fp = _bluetoothConnection?.transport.peerFingerprint;
      return ValueListenableBuilder<List<TrialTextItem>>(
        valueListenable: _textTrialItems,
        builder: (context, texts, _) {
          final merged = ConversationTimelineMerge.merge(
            files: history
                .where(
                  (f) => f.transport == 'bluetooth' && f.peerFingerprint == fp,
                )
                .toList(),
            texts: texts,
            authenticatedFingerprint: fp,
          );
          final progress = _bluetoothConnection?.transport.fileProgress;
          final recorded =
              progress != null &&
              history.any(
                (f) =>
                    f.transport == 'bluetooth' &&
                    f.peerFingerprint == fp &&
                    f.transferId == progress.offer.id &&
                    f.direction == (progress.receiving ? 'receive' : 'send') &&
                    f.status == 'success',
              );
          final hasProgress =
              progress != null &&
              !(recorded && progress.phase.startsWith('成功'));
          if (merged.isEmpty && !hasProgress)
            return const Center(child: Text('可以发送文字，也可以点击＋发送文件'));
          return ListView.builder(
            reverse: true,
            itemCount: merged.length + (hasProgress ? 1 : 0),
            itemBuilder: (context, i) {
              if (hasProgress && i == 0) {
                final p = progress;
                final terminal =
                    p.phase.startsWith('成功') || p.phase.startsWith('失败');
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _conversationLiveBubble(
                      bluetoothFileProgressInfo(p),
                      mobile: mobile,
                      error: p.error.isEmpty || bluetoothFileWasCancelled(p)
                          ? ''
                          : bluetoothFileFailureMessage(p.error),
                      cancelled: bluetoothFileWasCancelled(p),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: terminal
                          ? (!p.receiving &&
                                    _bluetoothConnection
                                            ?.transport
                                            .fileSendReady ==
                                        true
                                ? TextButton(
                                    onPressed:
                                        _workbenchFilePickerOpen ||
                                            _bluetoothFileBusy
                                        ? null
                                        : _bluetoothConnection!
                                              .transport
                                              .hasUnconfirmedFile
                                        ? _confirmBluetoothFileResult
                                        : _addWorkbenchFile,
                                    child: Text(
                                      _bluetoothConnection!
                                              .transport
                                              .hasUnconfirmedFile
                                          ? '核对结果'
                                          : '重新选择文件',
                                    ),
                                  )
                                : const SizedBox.shrink())
                          : TextButton(
                              onPressed: () =>
                                  unawaited(_bluetoothConnection!.stop()),
                              child: const Text('停止传输并断开'),
                            ),
                    ),
                  ],
                );
              }
              final entry = merged[i - (hasProgress ? 1 : 0)];
              return entry.text != null
                  ? _conversationTextBubble(entry.text!, mobile: mobile)
                  : _conversationRecordBubble(entry.file!, mobile: mobile);
            },
          );
        },
      );
    }
    return ValueListenableBuilder<List<TrialTextItem>>(
      valueListenable: _textTrialItems,
      builder: (context, texts, _) {
        final fingerprint = peer == null
            ? null
            : _verifiedFingerprints[_peerKey(peer)];
        final merged = ConversationTimelineMerge.merge(
          files: files.where((f) => f.transport != 'bluetooth').toList(),
          texts: texts,
          authenticatedFingerprint: fingerprint,
          maxEntries: 120,
        );
        if (merged.isEmpty && live.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                peer == null ? '等待设备连接后即可发送文字或文件' : '可以发送文字，也可以点击＋发送文件',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFA9C0C3), fontSize: 13),
              ),
            ),
          );
        }
        return ListView.builder(
          reverse: true,
          itemCount: live.length + merged.length,
          itemBuilder: (context, index) {
            if (index < live.length) {
              return _conversationLiveBubble(live[index], mobile: mobile);
            }
            final entry = merged[index - live.length];
            final text = entry.text;
            if (text != null)
              return _conversationTextBubble(text, mobile: mobile);
            return _conversationRecordBubble(entry.file!, mobile: mobile);
          },
        );
      },
    );
  }

  Future<void> _sendTextTrial({
    required NearPeer? peer,
    required String fingerprint,
    required TextEditingController draft,
    bool bluetooth = false,
  }) async {
    if (_textTrialBusy.value ||
        (!bluetooth && (!_secureReady || _secureChannel == null)))
      return;
    final runtime = _textHistoryRuntime;
    if (runtime == null) {
      _toast('本机加密聊天历史不可用，文字发送已暂停；文件传输不受影响。');
      return;
    }
    final body = draft.text;
    if (!ConversationTextProtocol.isValidBody(body)) {
      _toast('请输入非空文字，最多 8 KiB UTF-8，不能包含控制字符');
      return;
    }
    if (!_pairIdentity.entries.any((e) => e.fingerprint == fingerprint) ||
        (bluetooth
            ? (_bluetoothConnection?.transport.textReady != true ||
                  _bluetoothConnection?.transport.peerFingerprint !=
                      fingerprint)
            : (peer == null ||
                  _verifiedFingerprints[_peerKey(peer)] != fingerprint))) {
      _toast('设备身份已变化，请重新确认当前会话');
      return;
    }
    _textTrialBusy.value = true;
    try {
      if (!await _loadPeerTextHistory(fingerprint, forceReload: true)) return;
      // If the remote already ACKed a prior send but our disk commit failed,
      // retry that exact local commit first; never retransmit it with a new ID.
      final pending = _acknowledgedAwaitingLocalSave[fingerprint];
      if (pending != null) {
        try {
          await runtime.store.saveConfirmed(
            authenticatedFingerprint: fingerprint,
            message: pending,
            outbound: true,
          );
          _textTrialLedger.recordOutgoingConfirmed(
            authenticatedFingerprint: fingerprint,
            message: pending,
          );
          _acknowledgedAwaitingLocalSave.remove(fingerprint);
          if (bluetooth) _bluetoothUnconfirmed.remove(fingerprint);
          if (mounted) _textTrialItems.value = _textTrialLedger.snapshot();
          if (draft.text == pending.body) {
            if (mounted) {
              draft.clear();
              _toast('上次已确认的文字已补存到本机加密历史；未重复发送。');
            }
            return;
          }
        } catch (e) {
          if (e is FormatException || e is StateError) {
            _blockedTextHistoryFingerprints.add(fingerprint);
          }
          _toast('上次已被对端确认，但本机历史仍未保存；本次没有发送新文字。$e');
          return;
        }
      }

      if (draft.text != body) {
        if (mounted) _toast('等待本机历史检查期间，输入文字已改变；请核对后重新发送。');
        return;
      }
      final retry = bluetooth ? _bluetoothUnconfirmed[fingerprint] : null;
      final message = retry != null && retry.body == body
          ? retry
          : TextChatMessage.create(body);
      if (bluetooth) _bluetoothUnconfirmed[fingerprint] = message;
      TextSendReceipt receipt;
      try {
        if (bluetooth) {
          final t = _bluetoothConnection!.transport;
          if (!_useBluetoothText ||
              !t.textReady ||
              t.peerFingerprint != fingerprint) {
            throw StateError('蓝牙已断开或会话已改变');
          }
          await t.sendText(message);
          receipt = TextSendReceipt(
            messageId: message.id,
            alreadyReceived: false,
          );
        } else {
          receipt = await _secureChannel!.sendText(
            ip: peer!.ip,
            port: secureFilePort,
            remoteFingerprint: fingerprint,
            message: message,
          );
        }
        if (receipt.messageId != message.id) {
          throw StateError('收到不匹配的加密文字确认');
        }
      } catch (e) {
        // Keep the unsent draft intact; do not show as delivered on failure.
        if (mounted) _toast('文字未确认送达：$e');
        return;
      }

      try {
        await runtime.store.saveConfirmed(
          authenticatedFingerprint: fingerprint,
          message: message,
          outbound: true,
        );
      } catch (e) {
        // Remote acceptance is real; distinguish it from local persistence failure.
        _acknowledgedAwaitingLocalSave[fingerprint] = message;
        if (e is FormatException || e is StateError) {
          _blockedTextHistoryFingerprints.add(fingerprint);
          if (mounted)
            _toast(
              '对端已确认接收，但本机历史无法验证或保存；'
              '文字通信已暂停，草稿保留。请勿清空历史或重置密钥，先保留诊断信息。$e',
            );
        } else {
          if (mounted)
            _toast(
              '对端已确认接收，但本机历史暂时保存失败。保留草稿；'
              '再次点击发送会先尝试补存这条消息，不会重复发送它。$e',
            );
        }
        return;
      }
      _textTrialLedger.recordOutgoingConfirmed(
        authenticatedFingerprint: fingerprint,
        message: message,
      );
      if (mounted) _textTrialItems.value = _textTrialLedger.snapshot();
      if (bluetooth) _bluetoothUnconfirmed.remove(fingerprint);
      if (mounted && draft.text == body) draft.clear();
    } finally {
      if (mounted) _textTrialBusy.value = false;
    }
  }

  Future<void> _pairOrResume(NearPeer peer) async {
    try {
      await _ensureSecureIdentity(peer);
      _toast('安全身份验证完成，可直接发送加密文件');
    } catch (e) {
      _toast('安全连接未完成：$e');
    }
  }

  Widget _pairControl(NearPeer peer, {bool mobile = false}) {
    final paired = _pairedPeerIds.contains(peer.id);
    return TextButton.icon(
      onPressed: paired || _pairingBusy ? null : () => _pairOrResume(peer),
      icon: _pairingBusy
          ? const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              paired
                  ? Icons.check_circle_outline_rounded
                  : Icons.verified_user_outlined,
              size: 17,
            ),
      label: Text(
        paired ? '已配对' : '首次配对',
        style: TextStyle(fontSize: mobile ? 12 : 13),
      ),
      style: TextButton.styleFrom(foregroundColor: const Color(0xFF83DAD3)),
    );
  }

  Future<void> _recordBluetoothTransfer(TransferRecord entry) async {
    await historyStore.appendBluetoothConfirmed(entry);
    if (mounted) setState(() => history = historyStore.records);
    unawaited(_pruneOutboundShareCache());
  }

  Future<void> _recordTransfer(TransferRecord entry) async {
    try {
      await historyStore.append(entry);
      if (mounted) setState(() => history = historyStore.records);
      unawaited(_pruneOutboundShareCache());
      // Old previews removed from bounded history can be pruned after a
      // 24-hour grace period; this avoids races with concurrent transfers.
      unawaited(
        SentImagePreviewStore.prune(
          historyStore.records
              .map((r) => r.thumbnailPath)
              .whereType<String>()
              .toSet(),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => history = historyStore.records);
      _toast('传输已结束，但历史保存失败：$e');
    }
  }

  // Android 10+ scoped MediaStore copy. The received original remains in
  // private storage for history, open and share. Album failure never turns a
  // successful encrypted transfer into an unsuccessful one.
  Future<void> _autoArchiveReceivedMedia(File file) async {
    if (!Platform.isAndroid) return;
    final name = file.uri.pathSegments.last;
    final isImage = MobileMediaSourcePolicy.isImageName(name);
    final isVideo = MobileMediaSourcePolicy.isVideoName(name);
    if (!isImage && !isVideo) return;
    final mediaLabel = isVideo ? '视频' : '图片';
    final path = file.path;
    if (_autoArchivedMediaPaths.contains(path) ||
        !_autoArchivingMediaPaths.add(path))
      return;
    try {
      if (!await file.exists()) return;
      final galleryUri = await _fileChannel.invokeMethod<String>(
        'archiveReceivedMedia',
        <String, Object>{'path': path},
      );
      if (galleryUri != null && galleryUri.isNotEmpty) {
        _autoArchivedMediaPaths.add(path);
        if (mounted) {
          setState(() => _quickSavedReceivedPaths.add(path));
          _toast('$mediaLabel 已自动保存到系统相册 · 邻跃');
        }
      }
    } catch (e) {
      // Preserve the received file if publishing to MediaStore fails.
      service.logDiagnostic('接收$mediaLabel 相册备份失败（不影响传输）：$e');
      if (mounted) _toast('$mediaLabel 已接收，但自动保存相册失败：$e');
    } finally {
      _autoArchivingMediaPaths.remove(path);
    }
  }

  Future<void> _recordReceived(File file) async {
    try {
      if (!await file.exists()) return;
      await _recordTransfer(
        TransferRecord(
          name: file.uri.pathSegments.last,
          peerName: '来源设备（旧协议未记录设备名）',
          direction: 'receive',
          status: 'success',
          bytes: await file.length(),
          timestamp: DateTime.now(),
          localPath: file.path,
        ),
      );
    } catch (e) {
      _toast('保存接收历史失败：$e');
    }
  }

  Future<void> _reloadReceivedFiles() async {
    final directory =
        _receiveDirectory ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}NearLinkReceived',
        );
    if (await directory.exists()) {
      final entries = await directory
          .list()
          .where(
            (e) =>
                e is File &&
                !e.path
                    .split(Platform.pathSeparator)
                    .last
                    .startsWith('.linyue_part_') &&
                !e.path.split(Platform.pathSeparator).last.contains('.part.') &&
                isCompletedReceivedName(
                  e.path.split(Platform.pathSeparator).last,
                ),
          )
          .cast<File>()
          .toList();
      entries.sort((a, b) => b.path.compareTo(a.path));
      if (mounted) {
        setState(() {
          received
            ..clear()
            ..addAll(entries);
        });
      }
    }
  }

  Future<bool> _confirmReceipt(
    FileOffer offer, {
    bool encrypted = false,
    String? verifiedFingerprint,
  }) async {
    final decision = receiveGuard.check(offer.remoteIp);
    if (decision != ReceiveDecision.prompt) {
      if (mounted) setState(() {});
      return false;
    }
    if (!mounted || _incomingDialogOpen) return false;
    _incomingDialogOpen = true;
    final offerAuto =
        encrypted &&
        verifiedFingerprint != null &&
        _autoReceivePolicy.ready &&
        _autoReceivePolicy.enabled &&
        _pairIdentity.entries.any(
          (entry) => entry.fingerprint == verifiedFingerprint,
        );
    try {
      final choice = await showDialog<_ReceiveApproval>(
        context: context,
        barrierDismissible: false,
        builder: (dialog) => AlertDialog(
          backgroundColor: const Color(0xFF112B35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text('接收文件请求'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoLine('设备', offer.senderName),
              const SizedBox(height: 8),
              _infoLine('来源 IP', offer.remoteIp),
              const SizedBox(height: 8),
              _infoLine('文件', offer.name),
              const SizedBox(height: 8),
              _infoLine('大小', formatBytes(offer.size)),
              const SizedBox(height: 14),
              Text(
                offerAuto
                    ? '身份已验证。允许此设备自动接收后续文件后，不会再逐次弹出接收确认；可随时在设置中关闭或清除授权。'
                    : encrypted
                    ? '设备已通过身份验证，本次文件使用加密传输。'
                    : '安全提示：旧版明文请求已被新版应用停用。',
                style: TextStyle(
                  color: encrypted
                      ? const Color(0xFF7DE1C4)
                      : const Color(0xFFF2B84B),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, _ReceiveApproval.block),
              child: const Text('屏蔽10分钟'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, _ReceiveApproval.decline),
              child: const Text('拒绝'),
            ),
            if (offerAuto)
              TextButton(
                onPressed: () => Navigator.pop(dialog, _ReceiveApproval.once),
                child: const Text('仅本次接收'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialog,
                offerAuto ? _ReceiveApproval.auto : _ReceiveApproval.once,
              ),
              child: Text(offerAuto ? '接收并允许后续自动接收' : '接收'),
            ),
          ],
        ),
      );
      if (choice == _ReceiveApproval.block) {
        receiveGuard.block(offer.remoteIp);
      } else if (choice == _ReceiveApproval.once ||
          choice == _ReceiveApproval.auto) {
        if (choice == _ReceiveApproval.auto && verifiedFingerprint != null) {
          try {
            await _autoReceivePolicy.grant(verifiedFingerprint);
          } catch (e) {
            _toast('自动接收授权保存失败，当前文件仍可接收：$e');
          }
        }
        receiveGuard.noteAccepted(offer.remoteIp);
      } else {
        receiveGuard.noteDecline(offer.remoteIp);
      }
      if (mounted) setState(() {});
      return choice == _ReceiveApproval.once || choice == _ReceiveApproval.auto;
    } finally {
      _incomingDialogOpen = false;
    }
  }

  Widget _receiveGuardSettings() {
    final blocked = receiveGuard.blockedCount;
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '接收安全控制',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许接收文件请求'),
            subtitle: Text(
              receiveGuard.receivingEnabled
                  ? '开启：未授权设备需确认，已授权设备可自动接收'
                  : '已暂停接收：仍可发现设备并向对方发送',
            ),
            value: receiveGuard.receivingEnabled,
            onChanged: (value) {
              setState(() => receiveGuard.receivingEnabled = value);
            },
          ),
          const Divider(),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('已授权设备自动接收后续文件'),
            subtitle: Text(
              _autoReceiveLoadError != null
                  ? '授权记录无法安全读取：本次仅能手动确认'
                  : '首次文件确认授权后，后续同设备不再重复询问；身份验证与磁盘检查照常执行',
            ),
            value: _autoReceivePolicy.enabled && _autoReceivePolicy.ready,
            onChanged: !_autoReceivePolicy.ready
                ? null
                : (value) async {
                    try {
                      await _autoReceivePolicy.setEnabled(value);
                      if (mounted) setState(() {});
                    } catch (e) {
                      _toast('自动接收设置保存失败：$e');
                    }
                  },
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '已授权自动接收：${_autoReceivePolicy.authorizedCount} 台',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFA9C0C3),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed:
                    _autoReceivePolicy.ready &&
                        _autoReceivePolicy.authorizedCount > 0
                    ? () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('清除自动接收授权？'),
                            content: const Text(
                              '清除后，已配对设备的下次新文件仍会要求你选择是否接收；不会解除加密配对。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('清除授权'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        try {
                          await _autoReceivePolicy.revokeAll();
                          if (mounted) setState(() {});
                        } catch (e) {
                          _toast('清除授权失败：$e');
                        }
                      }
                    : null,
                icon: const Icon(Icons.lock_reset_rounded, size: 18),
                label: const Text('清除授权'),
              ),
            ],
          ),
          const Divider(),
          Text(
            '临时屏蔽：$blocked 个来源地址（最多10分钟）',
            style: const TextStyle(color: Color(0xFFA9C0C3)),
          ),
          if (blocked > 0) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('解除全部临时屏蔽'),
              onPressed: () => setState(receiveGuard.clearBlocks),
            ),
          ],
          const SizedBox(height: 10),
          const ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('接收规则说明', style: TextStyle(fontSize: 12)),
            children: [
              Text(
                '同一来源在10分钟内连续拒绝3次，将临时屏蔽10分钟。暂停接收和屏蔽列表重启后重置；自动接收授权会保留，且每次仍需身份认证。文件不会自动打开。',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFFA9C0C3),
                  height: 1.6,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _onSendQueueChanged() {
    if (!mounted) return;
    setState(() {
      sending = _sendQueue.isSending;
      _activeTransferName = _sendQueue.current?.name;
    });
    for (final entry in _sendQueue.items) {
      final record = entry.payload.resume;
      if (record != null &&
          entry.state == SendQueueState.cancelled &&
          _enqueuedResumeIds.remove(record.taskId)) {
        _attemptedResumesThisRun.add(record.taskId);
        unawaited(_forgetResume(record));
      }
    }
  }

  Future<void> _reloadResumeList() async {
    final controller = _outboundController;
    if (controller == null) return;
    final values = await controller.load();
    final audit = await OutboundConsistencyAudit(
      journal: controller.journal,
      sourcesDirectory: controller.sourcesDirectory,
    ).inspect(activeTaskIds: {..._enqueuedResumeIds});
    final blocked = <String>{
      for (final issue in audit.issues)
        if (issue.taskId != null) issue.taskId!,
    };
    final globalUnsafe =
        audit.has(OutboundAuditCode.unsafeStagingRoot) ||
        audit.has(OutboundAuditCode.stagingRootMissing) ||
        audit.has(OutboundAuditCode.journalUnreadable);
    if (mounted)
      setState(
        () => _pendingRestores = [
          for (final record in values)
            if (!globalUnsafe &&
                !blocked.contains(record.taskId) &&
                record.status != OutboundResumeStatus.cleanupPending)
              record,
        ],
      );
  }

  Future<void> _forgetResume(OutboundResumeRecord record) async {
    final controller = _outboundController;
    if (controller == null) return;
    try {
      await controller.forget(record);
      await _reloadResumeList();
    } catch (e) {
      _toast('恢复任务清理失败，记录将保留以供核对：$e');
    }
  }

  Future<String> _diskSpaceText(String path) async {
    final free = await _diskCapacityGuard.availableBytes(path);
    if (free == null) return '无法取得（未假定空间充足）';
    return '${(free / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB 可用';
  }

  // DEV13D2E8: a read-only accounting view with one deliberately narrow,
  // opt-in cleanup: old, unreferenced generated thumbnail PNGs only.
  // Gallery MediaStore files and received originals are never removed here.
  bool get _mayCleanOrphanThumbnails =>
      _historyLoadedForCleanup &&
      !_sendQueue.isSending &&
      _sendQueue.pendingCount == 0 &&
      _preparingBatches == 0 &&
      !_resumeCleanupRunning &&
      !_resumeChecking;

  Future<void> _showLocalStorageOverview() async {
    if (_storageOverviewBusy) return;
    setState(() => _storageOverviewBusy = true);
    try {
      final support = await getApplicationSupportDirectory();
      final appDocs = await getApplicationDocumentsDirectory();
      final root =
          _receiveDirectory ??
          _defaultReceiveDirectory ??
          Directory('${appDocs.path}${Platform.pathSeparator}NearLinkReceived');
      final snapshot = await LocalStorageOverview.inspect(
        receivedDirectory: root,
        supportDirectory: support,
      );
      if (!mounted) return;
      final freeBytes = await _diskCapacityGuard.availableBytes(root.path);
      if (!mounted) return;
      final lines = <String>[
        for (final part in snapshot.buckets)
          '${part.label}：${formatBytes(part.bytes)} / ${part.fileCount} 个文件'
              '${part.complete ? '' : '（扫描不完整，不代表总量）'}',
        '',
        '以上为邻跃本地文件扫描结果，不包含系统相册的公共副本，'
            '也不包含断点续传临时目录；它们不能简单合计为全部存储占用。',
        '接收目录磁盘可用：${await _diskSpaceText(root.path)}',
        if (freeBytes != null && freeBytes < 1024 * 1024 * 1024)
          '空间提醒：接收目录可用空间不足 1 GiB，请避免继续接收大文件。',
        if (!snapshot.complete) '有无法读取或超出扫描上限的内容，数据仅作参考。',
        '',
        '可清理范围仅限超过 24 小时、且未被传输历史引用的生成缩略图。'
            '图库中照片/视频、接收原件、待发送副本、快捷分享副本和断点续传文件均不会在此删除。',
      ];
      if (!mounted) return;
      final requested = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('存储空间 · 安全管理'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: SelectableText(
                lines.join('\n\n'),
                style: const TextStyle(fontSize: 13, height: 1.55),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('关闭'),
            ),
            TextButton(
              onPressed:
                  _mayCleanOrphanThumbnails && snapshot.buckets.last.complete
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('清理无引用缩略图'),
            ),
          ],
        ),
      );
      if (requested != true || !mounted) return;
      if (!_mayCleanOrphanThumbnails || !snapshot.buckets.last.complete) {
        _toast('历史、缩略图扫描或传输状态不满足安全条件，清理已取消');
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认清理旧缩略图？'),
          content: const Text(
            '只删除超过 24 小时且未被本机传输历史引用的邻跃生成缩略图。'
            '不会清理发送原图、相册、接收文件、选取媒体副本或断点续传数据。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认清理'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      if (!_mayCleanOrphanThumbnails) {
        _toast('传输状态已变化，取消清理');
        return;
      }
      final folder = Directory(
        '${support.path}${Platform.pathSeparator}'
        '${LocalStorageOverview.thumbnailDirectoryName}',
      );
      final referenced = historyStore.records
          .where((record) => record.thumbnailPath != null)
          .map((record) => record.thumbnailPath!)
          .toSet();
      final result = await LocalStorageOverview.pruneOrphanThumbnails(
        thumbnailDirectory: folder,
        retainedPaths: referenced,
      );
      if (mounted)
        _toast(
          '已清理 ${result.filesDeleted} 个旧缩略图，释放约 '
          '${formatBytes(result.bytesFreed)}；接收原件和系统相册未修改',
        );
    } catch (e) {
      if (mounted) _toast('存储检查或清理未完成（未执行其他清理）：$e');
    } finally {
      if (mounted) setState(() => _storageOverviewBusy = false);
    }
  }

  // DEV13D2E10: read-only audit including all records on durable resume
  // journal, not just the filtered in-memory restore list. No file deletes.
  Future<void> _showMediaCopyAudit() async {
    if (_mediaCopyAuditBusy) return;
    if (!Platform.isAndroid) {
      _toast('媒体副本预检仅在 Android 端提供');
      return;
    }
    if (!_historyLoadedForCleanup ||
        _resumeChecking ||
        _resumeJournalError != null ||
        _outboundController == null) {
      _toast('历史或恢复日志尚未完整加载，请稍后再做只读预检');
      return;
    }
    if (_sendQueue.isSending ||
        _sendQueue.pendingCount > 0 ||
        _preparingBatches > 0 ||
        _resumeCleanupRunning) {
      _toast('有发送任务或恢复任务正在处理，请待队列空闲后再检查');
      return;
    }
    setState(() => _mediaCopyAuditBusy = true);
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(
        '${support.path}${Platform.pathSeparator}'
        '${LocalStorageOverview.pickedMediaDirectoryName}',
      );
      // Re-read the entire persistent journal. _pendingRestores intentionally
      // filters unsafe/cleanup-pending records; those still protect paths.
      final durableRecords = await _outboundController!.load();
      final referenced = <String>{
        for (final resume in durableRecords) resume.sourcePath,
        for (final item in historyStore.records)
          if (item.sourcePath != null) item.sourcePath!,
        for (final item in _sendQueue.items)
          if (item.payload.selected?.path != null) item.payload.selected!.path!,
        for (final resume in _pendingRestores) resume.sourcePath,
      };
      final receiptRoot = Directory(
        '${support.path}${Platform.pathSeparator}'
        '${MobileMediaSourcePolicy.receiptDirectoryName}',
      );
      final report = await MediaCopyAudit.inspect(
        pickedMediaDirectory: dir,
        referencedPaths: referenced,
        receiptDirectory: receiptRoot,
      );
      // E12: independent read-only receipt health check. No file changes.
      final receiptHealth = await MediaReceiptHealth.inspect(
        pickedMediaDirectory: dir,
        receiptDirectory: receiptRoot,
      );
      if (!mounted) return;
      final detailLines = report.complete
          ? <String>[
              for (final item in report.reviewDetails)
                '• ${item.provenanceVerified ? '[已登记] ' : '[旧版/未登记] '}'
                    '${item.name} · ${formatBytes(item.bytes)} · '
                    '修改于 ${item.modified.toLocal().toString().split('.').first}',
              if (report.reviewDetailsTruncated) '…其余候选未逐项显示',
            ]
          : <String>['扫描未完成，不展示候选明细'];
      final description = [
        '图库／相机私有发送副本：${report.totalFiles} 个，'
            '${formatBytes(report.totalBytes)}',
        '本机已知历史／当前队列／恢复列表引用：'
            '${report.referencedFiles} 个，${formatBytes(report.referencedBytes)}',
        '未见上述引用且已超过 7 天：'
            '${report.reviewFiles} 个，${formatBytes(report.reviewBytes)}',
        '来源登记覆盖的媒体副本：${report.registeredFiles} 个，'
            '${formatBytes(report.registeredBytes)}（含近期和已引用）',
        if (receiptHealth.complete) ...[
          '来源登记健康检查：有效 ${receiptHealth.intactReceipts} 个、'
              '对应媒体副本缺失 ${receiptHealth.orphanReceipts} 个、'
              '登记异常 ${receiptHealth.invalidReceipts} 个',
          '有效登记对应的媒体副本：${formatBytes(receiptHealth.intactBytes)}',
        ] else
          '来源登记健康检查未完成：存在无法安全读取的目录／条目或超出扫描上限。'
              '请先保留现有文件，切勿清理。',
        '本版来源登记可核实的旧候选：${report.registeredReviewFiles} 个，'
            '${formatBytes(report.registeredReviewBytes)}（仍不允许删除）',
        '近期生成：${report.recentFiles} 个；'
            '命名无法识别：${report.otherFiles} 个',
        '',
        '待人工复核明细（按大小排序，最多 12 项）：',
        if (detailLines.isEmpty) '无',
        ...detailLines,
        if (!report.complete) '注意：文件扫描未完成，以上仅为部分统计，不代表全部空间。',
        '',
        '来源登记仅从 E11 新选入的图库/相机媒体开始记录。'
            '旧文件不会补写猜测性的来源记录。',
        '这是只读预检：虽已复核全部持久化恢复日志，'
            '但传输历史可能已轮换，无法证明候选文件可安全删除。',
        '本版不提供删除媒体副本按钮；不删除图库照片、视频、'
            '接收原件、发送原图或断点数据。',
      ].join('\n\n');
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('媒体副本占用预检 · 只读'),
          content: SizedBox(
            width: 470,
            child: SingleChildScrollView(
              child: SelectableText(
                description,
                style: const TextStyle(fontSize: 13, height: 1.55),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _toast('媒体副本预检未完成：$e');
    } finally {
      if (mounted) setState(() => _mediaCopyAuditBusy = false);
    }
  }

  /// Read-only storage inspection; never auto-deletes or repairs data.
  Future<void> _inspectOutboundStorage() async {
    final controller = _outboundController;
    if (controller == null ||
        _storageHealthScanning ||
        _resumeCleanupRunning ||
        _sendQueue.isSending ||
        _sendQueue.pendingCount > 0 ||
        _preparingBatches > 0 ||
        _resumeChecking) {
      _toast('请等待发送、恢复检查或清理任务结束后再体检');
      return;
    }
    setState(() => _storageHealthScanning = true);
    try {
      final health = await OutboundStorageHealthInspector(controller).inspect();
      if (!mounted) return;
      final mib = (int n) => (n / (1024 * 1024)).toStringAsFixed(1);
      final lines = <String>[
        '恢复日志任务：${health.recordedTasks} 项（过期 ${health.expiredTasks} 项）',
        '日志记录的待恢复数据：${mib(health.recordedBytes)} MiB',
        '扫描可见的暂存文件：${mib(health.measuredStagingBytes)} MiB',
        '应用暂存配额：${mib(health.stagingQuotaBytes)} MiB',
        '以下为当前实际磁盘容量快照（并非邻跃暂存配额）：',
        '发送暂存所在磁盘：${await _diskSpaceText(controller.sourcesDirectory.parent.path)}',
        '接收目录所在磁盘：${await _diskSpaceText((_receiveDirectory ?? _defaultReceiveDirectory!).path)}',
        '无对应日志的候选目录：${health.orphanFolders} 个，约 ${mib(health.orphanBytes)} MiB',
        '文件缺失：${health.missingSources} 项；大小异常：${health.sizeMismatchSources} 项',
        '异常引用：${health.unsafeReferences} 项；未知目录条目：${health.unknownEntries} 项',
        if (!health.scanComplete) '注意：目录数量过多或无法读取，本次检查不完整。',
        if (health.nearingQuota) '提示：已接近邻跃暂存配额，请先完成或检查旧任务。',
        '上述磁盘剩余容量是实时快照，不保证上传过程中空间不会变化。体检不会删除或修改文件。',
        if (health.orphanFolders > 0) '无日志目录仅标记待人工核对，不能据此认定可安全删除。',
      ];
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(health.hasProblems ? '存储体检 · 发现需核对项目' : '存储体检 · 未发现明显异常'),
          content: SingleChildScrollView(child: Text(lines.join('\n\n'))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('存储体检未完成'),
          content: Text(
            '恢复日志或存储目录无法安全读取：$e\n'
            '没有删除任何暂存文件，也不会重写损坏的恢复记录。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _storageHealthScanning = false);
    }
  }

  Future<void> _clearExpiredResumeSources() async {
    final controller = _outboundController;
    if (controller == null ||
        _resumeCleanupRunning ||
        _sendQueue.isSending ||
        _sendQueue.pendingCount > 0 ||
        _preparingBatches > 0) {
      _toast('正在发送或准备文件，请等待队列空闲后再清理');
      return;
    }
    final expired = _pendingRestores
        .where(
          (r) =>
              DateTime.now().toUtc().difference(r.createdUtc) >
              controller.journal.maxAge,
        )
        .toList();
    if (expired.isEmpty) {
      _toast('没有需要清理的过期恢复任务');
      return;
    }
    final bytes = expired.fold<int>(0, (total, r) => total + r.fileBytes);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理过期的临时文件？'),
        content: Text(
          '检测到 ${expired.length} 个超过24小时的恢复任务，'
          '对应的暂存源文件约 ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB。'
          '\n只清理邻跃私有目录中的过期副本，不删除原文件。'
          '\n清理后，这些过期任务无法继续断点续传。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    if (_sendQueue.isSending ||
        _sendQueue.pendingCount > 0 ||
        _preparingBatches > 0 ||
        _resumeCleanupRunning) {
      _toast('队列已开始工作，请稍后清理');
      return;
    }
    setState(() => _resumeCleanupRunning = true);
    try {
      final report = await controller.cleanupExpired(
        protectedTaskIds: {
          ..._enqueuedResumeIds,
          for (final item in _sendQueue.items)
            if (item.payload.resume != null &&
                (item.state == SendQueueState.pending ||
                    item.state == SendQueueState.sending))
              item.payload.resume!.taskId,
        },
      );
      await _reloadResumeList();
      _toast(
        '清理 ${report.removedTasks} 项，释放约 '
        '${(report.freedBytes / (1024 * 1024)).toStringAsFixed(1)} MiB'
        '${report.skippedTasks > 0 ? '；${report.skippedTasks} 项为安全起见保留' : ''}',
      );
    } catch (e) {
      _toast('清理未完成，请保留原有记录并检查：$e');
    } finally {
      if (mounted) setState(() => _resumeCleanupRunning = false);
    }
  }

  // Poll only when unfinished records exist. Signed DEV8 resume proves the
  // exact registered identity; discovery name, peer ID and IP are NOT trust.
  Future<void> _restorePending() async {
    if (_resumeCleanupRunning ||
        _resumeChecking ||
        !mounted ||
        !_secureReady ||
        _pairing == null ||
        _outboundController == null ||
        _pendingRestores.isEmpty ||
        _preparingBatches > 0)
      return;
    _resumeChecking = true;
    try {
      final candidates = _pendingRestores
          .where(
            (record) =>
                !_enqueuedResumeIds.contains(record.taskId) &&
                !_attemptedResumesThisRun.contains(record.taskId),
          )
          .toList();
      for (final record in candidates) {
        if (!mounted) break;
        if (DateTime.now().toUtc().difference(record.createdUtc) >
            const Duration(hours: 24))
          continue;
        for (final peer in service.peers) {
          if (peer.isStale) continue;
          final proved = await _pairing!.tryResume(remoteIp: peer.ip);
          if (proved == null ||
              proved.fingerprint != record.peerFingerprint ||
              !_pairIdentity.entries.any(
                (r) => r.fingerprint == proved.fingerprint,
              )) {
            continue;
          }
          // No prompt, no fallback, no switching to another peer later.
          service.recordDiscoverySignature(
            peer.ip,
            'pending_transfer_signed_resume',
          );
          _attemptedResumesThisRun.add(record.taskId);
          _enqueuedResumeIds.add(record.taskId);
          _sendQueue.enqueue([
            ((peer: peer, selected: null, resume: record), record.fileName),
          ]);
          _toast('已安全找回未完成任务：${record.fileName}');
          break;
        }
      }
    } catch (e) {
      _toast('恢复待发送任务暂不可用：$e');
    } finally {
      _resumeChecking = false;
    }
  }

  void _queueFiles(NearPeer peer, List<PlatformFile> files) {
    if (files.isEmpty) return;
    unawaited(_enqueueNewFiles(peer, files));
  }

  Future<void> _enqueueNewFiles(NearPeer peer, List<PlatformFile> files) async {
    _preparingBatches++;
    final controller = _outboundController;
    final addedRecords = <OutboundResumeRecord>[];
    try {
      if (_sendQueue.pendingCount + files.length > _sendQueue.maxPending) {
        throw StateError('排队任务数量超过限制');
      }
      final jobs = <(_SecureSendJob, String)>[];
      for (final file in files) {
        final size = await _checkedFileLength(file);
        if (size > secureStreamPilotMaxBytes) {
          throw StateError('单文件最大 1 GiB');
        }
        if (size <= secureFileMaxBytes) {
          jobs.add(((peer: peer, selected: file, resume: null), file.name));
        } else {
          if (controller == null) {
            throw StateError('恢复记录不可用：${_resumeJournalError ?? '尚未初始化'}');
          }
          _toast('正在准备可恢复的大文件：${file.name}');
          final fingerprint = await _ensureSecureIdentity(peer);
          // Persistent resume makes a second source copy in the app's private folder.
          final appSupport = await getApplicationSupportDirectory();
          await _diskCapacityGuard.requireRoom(
            destinationPath: appSupport.path,
            fileBytes: size,
          );
          final record = await controller.prepare(
            source: file.readAsByteStream(),
            expectedBytes: size,
            name: file.name,
            peerFingerprint: fingerprint,
          );
          addedRecords.add(record);
          jobs.add(((peer: peer, selected: null, resume: record), file.name));
        }
      }
      for (final record in addedRecords) {
        _enqueuedResumeIds.add(record.taskId);
        _attemptedResumesThisRun.add(record.taskId);
      }
      _sendQueue.enqueue(jobs);
      await _reloadResumeList();
      _toast('已加入发送队列：${files.length} 个文件');
    } catch (e) {
      // Do not leave staged tasks waiting to auto-send after user was told
      // their enqueue failed. Already active queue items are not touched.
      for (final record in addedRecords) {
        _enqueuedResumeIds.remove(record.taskId);
        await _forgetResume(record);
      }
      _toast('无法加入发送队列：$e');
    }
  }

  Future<void> _pickFilesForActivePeer() async {
    final peer = _activePeer;
    if (peer == null) {
      _toast('请先选择一台在线设备');
      return;
    }
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files == null || files.isEmpty) return;
      _queueFiles(peer, files);
    } catch (e) {
      _toast('选择文件失败：$e');
    }
  }

  Future<void> _showAndroidAddFileSources() async {
    if (!Platform.isAndroid) {
      await _pickFilesForActivePeer();
      return;
    }
    if (_activePeer == null) {
      _toast('请先选择一台在线设备');
      return;
    }
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF102B35),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '添加文件',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _sourceTile(
                      sheetContext,
                      icon: Icons.photo_library_outlined,
                      label: '相册',
                      value: 'gallery',
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _sourceTile(
                      sheetContext,
                      icon: Icons.folder_open_rounded,
                      label: '文件夹',
                      value: 'files',
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _sourceTile(
                      sheetContext,
                      icon: Icons.photo_camera_outlined,
                      label: '相机',
                      value: 'camera',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || source == null) return;
    if (source == 'files') {
      await _pickFilesForActivePeer();
    } else if (source == 'gallery') {
      await _pickMobilePhotos();
    } else if (source == 'camera') {
      await _captureMobilePhoto();
    }
  }

  Widget _sourceTile(
    BuildContext sheetContext, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return InkWell(
      key: ValueKey<String>('dev13d2e6_source_$value'),
      onTap: () => Navigator.of(sheetContext).pop(value),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF173C45),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x8857CFC8)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 29, color: const Color(0xFF78DED6)),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 13.5)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickMobilePhotos() async {
    if (!Platform.isAndroid) return;
    List<String> temporaryGalleryPaths = <String>[];
    try {
      // DEV13D2E6 FIX2: the Android gallery picker requests images AND
      // videos. Both media types retain their original bytes; the gallery
      // URIs are copied to private cache before crossing this channel.
      temporaryGalleryPaths =
          await _fileChannel.invokeListMethod<String>(
            'pickFromDeviceGallery',
          ) ??
          <String>[];
      if (temporaryGalleryPaths.isEmpty) return;
      await _enqueuePickedMobileMedia(<XFile>[
        for (final path in temporaryGalleryPaths) XFile(path),
      ]);
    } catch (e) {
      if (mounted) _toast('选择相册图片或视频失败：$e');
    } finally {
      // The existing staging policy has made durable copies before enqueue.
      // Only clean temporary files provided by our private Android bridge.
      for (final path in temporaryGalleryPaths) {
        try {
          final tempFile = File(path);
          final cache = await getTemporaryDirectory();
          final cacheCanonical = await cache.resolveSymbolicLinks();
          final allowed =
              '$cacheCanonical${Platform.pathSeparator}LinYueGalleryPicker';
          final canonical = await tempFile.resolveSymbolicLinks();
          if (!canonical.startsWith('$allowed${Platform.pathSeparator}')) {
            continue;
          }
          if (await tempFile.exists()) await tempFile.delete();
          final dir = tempFile.parent;
          if (await dir.exists() && await dir.list().isEmpty) {
            await dir.delete();
          }
        } catch (_) {
          // Android OS also reclaims app cache if a gallery operation exits.
        }
      }
    }
  }

  Future<void> _captureMobilePhoto() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        requestFullMetadata: false,
      );
      if (picked == null) return;
      await _enqueuePickedMobileMedia(<XFile>[picked]);
    } catch (e) {
      if (mounted) _toast('拍照添加文件失败：$e');
    }
  }

  Future<void> _enqueuePickedMobileMedia(List<XFile> mediaFiles) async {
    final peer = _activePeer;
    if (!mounted || peer == null) {
      _toast('接收设备已经离线，请重新选择');
      return;
    }
    final prepared = <PlatformFile>[];
    final newPaths = <String>[];
    Directory? receiptRoot;
    try {
      final support = await getApplicationSupportDirectory();
      // Preserve the existing staging location for already-created image tasks.
      // It now also holds video originals selected from the gallery.
      final stagingRoot = Directory(
        '${support.path}${Platform.pathSeparator}LinYuePickedImages',
      );
      receiptRoot = Directory(
        '${support.path}${Platform.pathSeparator}'
        '${MobileMediaSourcePolicy.receiptDirectoryName}',
      );
      for (final media in mediaFiles) {
        final originalName = MobileMediaSourcePolicy.safeName(media.name);
        final staged = await MobileMediaSourcePolicy.stageFile(
          source: File(media.path),
          stagingRoot: stagingRoot,
          displayName: originalName,
          receiptDirectory: receiptRoot,
        );
        newPaths.add(staged.path);
        prepared.add(_MobileStagedMediaFile(staged, originalName));
      }
      // Durable originals also support opening media from sent history.
      _queueFiles(peer, prepared);
    } catch (e) {
      if (receiptRoot != null) {
        for (final path in newPaths) {
          final transientCopy = File(path);
          await MobileMediaSourcePolicy.discardUnqueuedStage(
            staged: transientCopy,
            receiptDirectory: receiptRoot,
          );
        }
      }
      if (mounted) _toast('添加媒体文件失败：$e');
    }
  }

  // Local filesystem drops only; folders will have an explicit workflow later.
  Future<void> _handleDroppedFiles(List<DropItem> dropItems) async {
    final peer = _activePeer;
    if (peer == null) {
      _toast('请先选择接收设备');
      return;
    }
    final files = <PlatformFile>[];
    var skipped = 0;
    for (final item in dropItems) {
      if (item is! DropItemFile) {
        skipped++;
        continue;
      }
      final path = item.path;
      if (path.isEmpty || !await File(path).exists()) {
        skipped++;
        continue;
      }
      try {
        final bytes = await File(path).length();
        files.add(_DroppedPlatformFile(item, bytes));
      } catch (_) {
        skipped++;
      }
    }
    if (skipped > 0) _toast('有 $skipped 项无法读取或不是普通文件，已跳过');
    _queueFiles(peer, files);
  }

  // File-picker metadata is not treated as authoritative when a real local
  // filesystem path is available. A mismatched zero-byte report must not
  // become a misleading "sent successfully" entry in history.
  Future<int> _checkedFileLength(PlatformFile selected) async {
    final declared = selected.lengthSync() ?? await selected.length();
    if (declared == null || declared < 0) {
      throw StateError('无法确定文件大小，请重新选择本地文件');
    }
    final path = selected.path;
    if (path != null && path.isNotEmpty) {
      final local = File(path);
      if (await local.exists()) {
        final actual = await local.length();
        if (declared != actual) {
          throw StateError('文件大小信息不一致（报告 $declared B，实际 $actual B），已停止发送');
        }
      }
    }
    return declared;
  }

  // FilePicker 13.x can return content-backed files with no local path.
  // Stage one bounded file in the app cache using its original safe filename.
  // Large files are encoded as bounded authenticated chunks (1 GiB pilot).
  Future<(File, Directory?)> _stageSecureFile(
    PlatformFile selected,
    int expected,
  ) async {
    if (expected > secureStreamPilotMaxBytes) {
      throw StateError('DEV12-D2 试运行单文件暂时不能超过 1 GiB');
    }
    final localPath = selected.path;
    if (localPath != null && localPath.isNotEmpty) {
      final existing = File(localPath);
      if (await existing.exists() && await existing.length() == expected) {
        return (existing, null); // Never delete a user's original file.
      }
    }
    final root = await getTemporaryDirectory();
    await _diskCapacityGuard.requireRoom(
      destinationPath: root.path,
      fileBytes: expected,
    );
    final dir = await Directory(
      '${root.path}${Platform.pathSeparator}linyue_sec_${DateTime.now().microsecondsSinceEpoch}_${math.Random.secure().nextInt(0x7fffffff)}',
    ).create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}${sanitizeFileName(selected.name)}',
    );
    try {
      var written = 0;
      final sink = file.openWrite();
      try {
        await for (final part in selected.readAsByteStream()) {
          written += part.length;
          if (written > secureStreamPilotMaxBytes)
            throw StateError('文件超过 1 GiB');
          sink.add(part);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (written != expected) throw StateError('文件长度变化，已停止发送');
      return (file, dir);
    } catch (_) {
      await dir.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _sendQueuedFile(SendQueueItem<_SecureSendJob> job) async {
    final peer = job.payload.peer;
    final selected = job.payload.selected;
    final resume = job.payload.resume;
    final name = job.name;
    var size = 0;
    Directory? staged;
    String? shareSourcePath;
    var managedShareCopy = false;
    try {
      // Never trust an IP/name from the journal. Prove the actual peer again.
      final String fingerprint;
      if (resume != null) {
        // Automatic restore must never start a fresh first-time pairing flow.
        final proof = await _pairing?.tryResume(remoteIp: peer.ip);
        if (proof == null ||
            proof.fingerprint != resume.peerFingerprint ||
            !_pairIdentity.entries.any(
              (e) => e.fingerprint == proof.fingerprint,
            )) {
          throw StateError('无法验证原始接收设备，自动续传已停止');
        }
        fingerprint = proof.fingerprint;
        SamePlatformLiveConnection.authorizeSignedIdentity(
          remoteIp: peer.ip,
          localFingerprint: _pairIdentity.local.fingerprint,
          registeredFingerprint: resume.peerFingerprint,
          signedFingerprint: fingerprint,
          secureChannelReady: _secureReady && _secureChannel != null,
        );
      } else {
        fingerprint = await _ensureSecureIdentity(peer);
      }
      final channel = _secureChannel;
      if (channel == null) throw StateError('加密发送服务未启动');
      if (mounted)
        setState(
          () => _outgoingProgress = TransferProgressInfo(
            name: name,
            direction: 'send',
            phase: TransferProgressPhase.preparing,
            totalBytes: 0,
            transferredBytes: 0,
            elapsed: Duration.zero,
          ),
        );
      late final File file;
      if (resume != null) {
        final controller = _outboundController;
        if (controller == null) throw StateError('持久任务管理器未启动');
        final validation = await controller.verify(
          resume,
          authenticatedFingerprint: fingerprint,
        );
        if (validation != OutboundRestoreCheck.ready) {
          throw StateError('恢复前文件或设备身份校验失败：${validation.name}');
        }
        file = File(resume.sourcePath);
        size = resume.fileBytes;
        await controller.mark(resume, OutboundResumeStatus.sending);
        await _reloadResumeList();
      } else {
        if (selected == null) throw StateError('发送文件源为空');
        size = await _checkedFileLength(selected);
        final selectedPath = selected.path;
        // DEV13D2E5 FIX2: Windows must also persist its original selected
        // image path. Otherwise every desktop sent-history image falls back to
        // the 256 px conversation thumbnail despite byte-exact transfer.
        // Persist only a verified, non-temporary ordinary file. Never keep a
        // staging/cache path that may be deleted when this send completes.
        if (Platform.isAndroid || Platform.isWindows) {
          try {
            shareSourcePath = await SentOriginalSourcePolicy.resolve(
              candidatePath: selectedPath,
              temporaryDirectory: await getTemporaryDirectory(),
              expectedBytes: size,
            );
          } catch (_) {
            // Optional preview metadata must never fail a file transfer.
          }
        }
        final (prepared, temporary) = await _stageSecureFile(selected, size);
        file = prepared;
        staged = temporary;
      }
      void onUpdate(TransferProgressInfo update) {
        if (!mounted) return;
        final now = DateTime.now();
        if (_lastProgressRenderAt == null ||
            now.difference(_lastProgressRenderAt!).inMilliseconds >= 150 ||
            update.phase != _outgoingProgress?.phase ||
            update.transferredBytes == update.totalBytes) {
          _lastProgressRenderAt = now;
          setState(() => _outgoingProgress = update);
        }
      }

      if (size <= secureFileMaxBytes) {
        await channel.sendFile(
          ip: peer.ip,
          port: secureFilePort,
          remoteFingerprint: fingerprint,
          file: file,
          onProgress: onUpdate,
        );
      } else {
        await channel.sendStreamFile(
          ip: peer.ip,
          port: secureFilePort,
          remoteFingerprint: fingerprint,
          file: file,
          onProgress: onUpdate,
          resumeTaskId: resume?.taskId,
          expectedSha256: resume?.fileSha256,
        );
      }
      // Sent chat bubbles need the original local file for direct sharing,
      // not the small display-only image thumbnail. For content-backed picks
      // and resumable tasks, retain a managed private copy before staging is
      // cleaned up or the resume source is forgotten. Failure to retain this
      // optional convenience must never turn a successful transfer into a fail.
      if (Platform.isAndroid && (resume != null || shareSourcePath == null)) {
        try {
          final retained = await _retainOutgoingShareCopy(
            source: file,
            fileName: name,
            expectedBytes: size,
          );
          shareSourcePath = retained.path;
          managedShareCopy = true;
        } catch (e) {
          if (mounted) _toast('文件已发送，但未能保留快捷分享源：$e');
        }
      }
      // DEV13C2: Capture only a small local thumbnail after authenticated
      // encrypted send succeeds, BEFORE a temporary source is cleaned up.
      // This cache is display-only, and failures never fail the transfer.
      final sentPreview = await SentImagePreviewStore.createForFile(
        source: file,
        fileName: name,
      );
      await _recordTransfer(
        TransferRecord(
          name: name,
          peerName: peer.name,
          direction: 'send',
          status: 'success',
          bytes: size,
          timestamp: DateTime.now(),
          thumbnailPath: sentPreview,
          sourcePath: shareSourcePath,
          managedShareCopy: managedShareCopy,
        ),
      );
      if (resume != null) {
        await _forgetResume(resume);
      }
    } catch (e) {
      if (mounted)
        setState(
          () => _outgoingProgress = TransferProgressInfo(
            name: name,
            direction: 'send',
            phase: TransferProgressPhase.failed,
            totalBytes: size,
            transferredBytes: _outgoingProgress?.name == name
                ? _outgoingProgress!.safeBytes
                : 0,
            elapsed: _outgoingProgress?.elapsed ?? Duration.zero,
          ),
        );
      await _recordTransfer(
        TransferRecord(
          name: name,
          peerName: peer.name,
          direction: 'send',
          status: 'failed',
          bytes: size,
          timestamp: DateTime.now(),
        ),
      );
      if (resume != null && _outboundController != null) {
        // After failed crypto, refusal or changed source, do NOT re-offer
        // automatically. Only temporary network exhaustion keeps the task.
        if ('$e'.contains('重连超时') ||
            e is SocketException ||
            e is TimeoutException ||
            e is HttpException) {
          try {
            await _outboundController!.mark(
              resume,
              OutboundResumeStatus.interrupted,
            );
            await _reloadResumeList();
          } catch (journalError) {
            _toast('断点记录保存失败：$journalError');
          }
        } else {
          await _forgetResume(resume);
        }
      }
      _toast('$name 发送失败：$e');
      rethrow;
    } finally {
      if (resume != null) _enqueuedResumeIds.remove(resume.taskId);
      if (staged != null && await staged.exists()) {
        try {
          await staged.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<File> _retainOutgoingShareCopy({
    required File source,
    required String fileName,
    required int expectedBytes,
  }) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}NearLinkOutboundShareCache',
    );
    await directory.create(recursive: true);
    await _diskCapacityGuard.requireRoom(
      destinationPath: directory.path,
      fileBytes: expectedBytes,
    );
    final retained = await ReceivedFileActions.saveCopyToDirectory(
      source,
      directory,
      fileName: sanitizeFileName(fileName),
    );
    if (await retained.length() != expectedBytes) {
      try {
        await retained.delete();
      } catch (_) {}
      throw FileSystemException('快捷分享副本长度校验失败', retained.path);
    }
    return retained;
  }

  /// Prunes only files LINYUE owns in its private outbound-share cache.
  /// Unreferenced copies get a 24-hour grace period for an OS share handoff.
  Future<void> _pruneOutboundShareCache() async {
    if (!Platform.isAndroid) return;
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory(
        '${support.path}${Platform.pathSeparator}NearLinkOutboundShareCache',
      );
      if (!await directory.exists()) return;
      final referenced = historyStore.records
          .where((entry) => entry.managedShareCopy && entry.sourcePath != null)
          .map((entry) => File(entry.sourcePath!).absolute.path)
          .toSet();
      final now = DateTime.now();
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File || referenced.contains(entity.absolute.path))
          continue;
        final stat = await entity.stat();
        if (now.difference(stat.modified) >= const Duration(hours: 24)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      // Cache maintenance is best-effort and must not block transfers.
    }
  }

  // E19-B: this status is NOT authorization. Before enqueue, the real
  // authenticated peer proof and durable source checksum are verified again.
  Widget _resumeTaskRow(OutboundResumeRecord record) {
    final controller = _outboundController;
    final busy =
        _sendQueue.isSending ||
        _sendQueue.pendingCount > 0 ||
        _preparingBatches > 0 ||
        _resumeChecking;
    final view = _resumeTaskPresentation.assess(
      record: record,
      nowUtc: DateTime.now().toUtc(),
      maxAge: controller?.journal.maxAge ?? const Duration(hours: 24),
      journalHealthy: controller != null && _resumeJournalError == null,
      cleanupInProgress: _resumeCleanupRunning,
      alreadyQueued: _enqueuedResumeIds.contains(record.taskId),
      queueBusy: busy,
      hasOnlineCandidate:
          _secureReady &&
          _pairing != null &&
          service.peers.any((peer) => !peer.isStale),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0x281D4C50),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x3347AAA4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              record.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              view.message,
              style: const TextStyle(color: Color(0xFFA9C0C3), fontSize: 10.5),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: view.canCheckAndRetry
                    ? () => unawaited(_retryOneResumeSafely(record))
                    : null,
                icon: const Icon(Icons.restart_alt_rounded, size: 17),
                label: const Text('校验并继续'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Manual single-task retry. Neither the cached peer label/IP nor a prior
  // verified UI badge is sufficient to grant permission. This method retains
  // the original task ID and existing secure send queue & stream protocol.
  Future<void> _retryOneResumeSafely(OutboundResumeRecord record) async {
    final controller = _outboundController;
    final pairing = _pairing;
    if (!mounted ||
        controller == null ||
        pairing == null ||
        !_secureReady ||
        _resumeChecking ||
        _resumeCleanupRunning ||
        _resumeJournalError != null ||
        _preparingBatches > 0 ||
        _sendQueue.isSending ||
        _sendQueue.pendingCount > 0 ||
        _enqueuedResumeIds.contains(record.taskId)) {
      _toast('目前不能开始恢复校验：请确认日志正常、无清理或发送任务');
      return;
    }
    if (!_pendingRestores.any(
      (task) =>
          task.taskId == record.taskId &&
          task.peerFingerprint == record.peerFingerprint &&
          task.fileSha256 == record.fileSha256,
    )) {
      _toast('任务已变化，请刷新恢复列表再操作');
      return;
    }
    setState(() => _resumeChecking = true);
    try {
      final peers = service.peers.where((peer) => !peer.isStale).toList();
      for (final peer in peers) {
        final proof = await pairing.tryResume(remoteIp: peer.ip);
        if (proof == null ||
            proof.fingerprint != record.peerFingerprint ||
            !_pairIdentity.entries.any(
              (e) => e.fingerprint == proof.fingerprint,
            )) {
          continue;
        }
        final check = await controller.verify(
          record,
          authenticatedFingerprint: proof.fingerprint,
        );
        final verdict = _outboundRetryPolicy.assess(
          OutboundRetryContext(
            record: record,
            nowUtc: DateTime.now().toUtc(),
            maxAge: controller.journal.maxAge,
            journalHealthy: _resumeJournalError == null,
            cleanupInProgress: _resumeCleanupRunning,
            alreadyQueued: _enqueuedResumeIds.contains(record.taskId),
            queueBusy:
                _sendQueue.isSending ||
                _sendQueue.pendingCount > 0 ||
                _preparingBatches > 0,
            authenticatedFingerprint: proof.fingerprint,
            sourceCheck: check,
            attemptedAutomaticallyThisRun: _attemptedResumesThisRun.contains(
              record.taskId,
            ),
            userInitiated: true,
          ),
        );
        if (!verdict.canOfferRetry) {
          _toast(verdict.userMessage);
          return;
        }
        // Read the full journal/audit again after asynchronous verification;
        // an unsafe or removed record must never be re-queued from stale UI.
        await _reloadResumeList();
        if (!mounted ||
            !_pendingRestores.any(
              (task) =>
                  task.taskId == record.taskId &&
                  task.peerFingerprint == record.peerFingerprint &&
                  task.fileSha256 == record.fileSha256,
            )) {
          _toast('恢复日志已发生变化或源文件异常，已停止重试');
          return;
        }
        if (_enqueuedResumeIds.contains(record.taskId) ||
            _sendQueue.isSending ||
            _sendQueue.pendingCount > 0 ||
            _preparingBatches > 0 ||
            _resumeCleanupRunning) {
          _toast('发送队列已有任务或清理操作，请稍后再试');
          return;
        }
        // Mark before enqueue to prevent double clicks; the existing worker
        // will verify identity and source AGAIN before network transmission.
        _enqueuedResumeIds.add(record.taskId);
        _attemptedResumesThisRun.add(record.taskId);
        try {
          _sendQueue.enqueue([
            ((peer: peer, selected: null, resume: record), record.fileName),
          ]);
        } catch (_) {
          _enqueuedResumeIds.remove(record.taskId);
          rethrow;
        }
        _toast('已经认证并校验原文件，正在继续：${record.fileName}');
        return;
      }
      _toast('尚未找到完成加密身份认证的原接收设备；未创建重试任务');
    } catch (e) {
      _toast('恢复校验失败，未创建新的发送任务：$e');
    } finally {
      if (mounted) setState(() => _resumeChecking = false);
    }
  }

  Widget _queueStatusPanel({bool compact = false, bool embedded = false}) {
    final entries = _sendQueue.items.reversed.take(compact ? 4 : 6).toList();
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.queue_rounded, size: 18, color: Color(0xFF74D9D2)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '待发送 ${_sendQueue.pendingCount} 项',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (_sendQueue.pendingCount > 0)
              TextButton(
                onPressed: () {
                  final count = _sendQueue.cancelAllPending();
                  _toast('已取消 $count 项尚未开始的文件');
                },
                child: const Text('取消待发送'),
              ),
          ],
        ),
        if (_pendingRestores.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(
              '待核对的大文件恢复任务：${_pendingRestores.length} 项',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFB8DAD9),
              ),
            ),
          ),
          for (final record in _pendingRestores.take(
            _showAllResumeTasks ? 30 : (compact ? 3 : 8),
          ))
            _resumeTaskRow(record),
          if (_pendingRestores.length > (compact ? 3 : 8))
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    setState(() => _showAllResumeTasks = !_showAllResumeTasks),
                child: Text(_showAllResumeTasks ? '收起恢复任务' : '展开逐项查看'),
              ),
            ),
          if (_showAllResumeTasks && _pendingRestores.length > 30)
            const Text(
              '最多展示前30项，其他任务保留在恢复记录中；请先处理当前任务',
              style: TextStyle(fontSize: 10.5, color: Color(0xFFA9C0C3)),
            ),
        ],
        if (_outboundController != null &&
            _pendingRestores.any(
              (r) =>
                  DateTime.now().toUtc().difference(r.createdUtc) >
                  _outboundController!.journal.maxAge,
            ))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '存在过期的暂存源文件，占用应用存储空间',
                    style: TextStyle(fontSize: 11, color: Color(0xFFF2B84B)),
                  ),
                ),
                TextButton(
                  onPressed:
                      _resumeCleanupRunning ||
                          _sendQueue.isSending ||
                          _sendQueue.pendingCount > 0 ||
                          _preparingBatches > 0
                      ? null
                      : _clearExpiredResumeSources,
                  child: Text(_resumeCleanupRunning ? '清理中' : '清理过期'),
                ),
              ],
            ),
          ),
        if (_outboundController != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.health_and_safety_outlined, size: 16),
              label: Text(_storageHealthScanning ? '检查中…' : '存储体检'),
              onPressed:
                  _storageHealthScanning ||
                      _resumeCleanupRunning ||
                      _resumeChecking ||
                      _sendQueue.isSending ||
                      _sendQueue.pendingCount > 0 ||
                      _preparingBatches > 0
                  ? null
                  : _inspectOutboundStorage,
            ),
          ),
        if (_resumeJournalError != null)
          Text(
            '恢复记录异常，请保留日志：$_resumeJournalError',
            style: const TextStyle(fontSize: 11, color: Color(0xFFF2B84B)),
          ),
        if (entries.isEmpty)
          const Text(
            '暂无排队文件',
            style: TextStyle(color: Color(0xFFA9C0C3), fontSize: 12),
          ),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  switch (entry.state) {
                    SendQueueState.pending => '排队中',
                    SendQueueState.sending => '加密发送中',
                    SendQueueState.succeeded => '成功',
                    SendQueueState.failed => '失败',
                    SendQueueState.cancelled => '已取消',
                  },
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFA9C0C3),
                  ),
                ),
                if (Platform.isAndroid &&
                    (entry.state == SendQueueState.pending ||
                        entry.state == SendQueueState.sending))
                  IconButton(
                    tooltip: '直接分享此文件',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _shareQueuedFile(entry.payload),
                    icon: const Icon(Icons.share_outlined, size: 17),
                  ),
                if (entry.state == SendQueueState.pending)
                  IconButton(
                    tooltip: '取消这项待发送文件',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _sendQueue.cancelPending(entry.id),
                    icon: const Icon(Icons.close_rounded, size: 17),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        const Text(
          '仅可取消未开始的任务',
          style: TextStyle(color: Color(0xFFA9C0C3), fontSize: 10),
        ),
      ],
    );
    return embedded ? content : _glassCard(child: content);
  }

  void _addIp() {
    try {
      final ip = ipController.text.trim();
      if (!SamePlatformConnectionPolicy.isPlausibleLanAddress(ip)) {
        throw const FormatException(
          '请输入对方在同一局域网中的私有 IPv4 地址（10.x、172.16–31.x 或 192.168.x）',
        );
      }
      final alreadyKnownAtIp = service.peers.any((peer) => peer.ip == ip);
      if (!alreadyKnownAtIp) service.addManualPeer(ip);
      _manualPeerTargetIps.add(ip);
      unawaited(_persistManualPeerTargets());
      ipController.clear();
      final matches = service.peers.where((p) => p.ip == ip).toList();
      if (matches.isNotEmpty) _choosePeer(matches.last);
      _toast('手动目标已保存并选中；尚不代表已连接。首次使用需核对六位配对码，已配对设备可直接尝试发送。');
    } catch (e) {
      _toast('$e');
    }
  }

  String _deviceRowKey(NearPeer peer) => '${peer.id}|${peer.ip}';

  Future<void> _reconnectManagedPeer(NearPeer peer) async {
    final key = _deviceRowKey(peer);
    if (_reconnectingKeys.contains(key) || _pairingBusy) {
      _toast('已有设备认证操作正在进行，请等待');
      return;
    }
    final pairing = _pairing;
    if (!_secureReady || pairing == null) {
      _toast('加密服务尚未就绪，不能确认设备已连接');
      return;
    }
    setState(() => _reconnectingKeys.add(key));
    _toast('正在核验 ${peer.name} 的签名身份，请稍候…');
    service.logDiagnostic('设备重连：开始签名验证 ${peer.ip}（不是仅保存 IP）');
    try {
      // A peer label/IP or an earlier in-memory pairing cache is NOT a
      // connected session. Require a FRESH signed handshake on each retry.
      final resumed = await pairing.tryResume(remoteIp: peer.ip);
      if (resumed != null) {
        if (resumed.remoteIp != peer.ip ||
            resumed.fingerprint == _pairIdentity.local.fingerprint ||
            !_pairIdentity.entries.any(
              (e) => e.fingerprint == resumed.fingerprint,
            )) {
          throw StateError('对端签名身份与已登记设备不匹配');
        }
        if (!mounted) return;
        // The entry may have been removed while the network call was pending.
        if (!service.peers.any((p) => p.id == peer.id && p.ip == peer.ip)) {
          throw StateError('设备条目已经移除，请重新选择');
        }
        setState(() {
          _pairedPeerIds.add(peer.id);
          _verifiedFingerprints[_peerKey(peer)] = resumed.fingerprint;
          _failedReconnectKeys.remove(key);
        });
        await _loadPeerTextHistory(resumed.fingerprint);
        service.recordDiscoverySignature(peer.ip, 'explicit_signed_reconnect');
        service.logDiagnostic('设备重连：签名验证成功 ${peer.ip}');
        if (mounted) _toast('签名身份验证成功，可以进行加密通信');
      } else {
        // An unknown peer still requires the original six-digit double
        // confirmation. This must never promote a saved IP into trust.
        if (_pairedPeerIds.contains(peer.id) ||
            _verifiedFingerprints.containsKey(_peerKey(peer))) {
          throw StateError('未能重新确认原设备的签名身份，请检查对方地址和网络');
        }
        await _ensureSecureIdentity(peer);
        if (mounted) setState(() => _failedReconnectKeys.remove(key));
        service.logDiagnostic('设备重连：首次双端确认完成 ${peer.ip}');
        if (mounted) _toast('首次配对与身份确认完成');
      }
    } catch (e) {
      service.logDiagnostic('设备重连：签名验证失败 ${peer.ip}：$e');
      if (mounted) {
        setState(() => _failedReconnectKeys.add(key));
        _toast('重连失败（未授权发送）：$e');
      }
    } finally {
      if (mounted) setState(() => _reconnectingKeys.remove(key));
    }
  }

  Future<void> _removeManagedPeer(NearPeer peer) async {
    final key = _deviceRowKey(peer);
    final isManualAddress = peer.isManual;
    // The ghost manual-address row below handles a saved IP that also has
    // an automatically discovered non-manual entry.
    if (!PeerManagementPolicy.canRemoveFromList(
      isManual: isManualAddress,
      isStale: peer.isStale,
      lastReconnectFailed: _failedReconnectKeys.contains(key),
    )) {
      _toast('在线自动发现设备不能直接移除，可断开后再管理');
      return;
    }
    if (sending ||
        _sendQueue.pendingCount > 0 ||
        _textTrialBusy.value ||
        _pairingBusy ||
        _reconnectingKeys.isNotEmpty) {
      _toast('正在发送或认证，请结束当前任务后再管理设备');
      return;
    }
    final label = isManualAddress ? '删除手动 IP 快捷入口' : '从当前列表移除失联设备';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(label),
        content: Text(
          '${peer.name}\n${peer.ip}\n\n'
          '仅移除本机设备列表或保存的手动地址。'
          '不会撤销加密配对授权、删除聊天记录、接收文件或对方数据。'
          '自动发现的设备以后仍可能重新出现。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (isManualAddress && _manualPeerTargetIps.contains(peer.ip)) {
        // Commit the new locator list BEFORE changing UI state. Failed writes
        // must not produce a disappearing/reappearing entry on next startup.
        final updated = Set<String>.of(_manualPeerTargetIps)..remove(peer.ip);
        final store = await _ensureManualPeerTargetStore();
        await store.save(updated);
        _manualPeerTargetIps
          ..clear()
          ..addAll(updated);
      }
      if (!mounted) return;
      final removed = service.removeDisplayedPeer(
        peerId: peer.id,
        ip: peer.ip,
        allowFailedConnection: _failedReconnectKeys.contains(key),
      );
      if (removed) {
        setState(() {
          if (_activePeerId == peer.id) _activePeerId = null;
          _verifiedFingerprints.remove(_peerKey(peer));
          _pairedPeerIds.remove(peer.id);
          _failedReconnectKeys.remove(key);
        });
      }
      _toast(removed ? '设备快捷入口已移除，配对授权与记录保留' : '条目已变更，请刷新设备列表');
    } catch (e) {
      if (mounted) _toast('移除失败：本机记录未清空：$e');
    }
  }

  Future<void> _showDeviceManager() async {
    final selected = await showDialog<_DeviceManagerSelection>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择局域网设备'),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        content: SizedBox(
          width: 520,
          height: 380,
          child: AnimatedBuilder(
            animation: service,
            builder: (context, _) {
              final peers = service.peers;
              final ghostManualIps = _manualPeerTargetIps
                  .where((ip) => !peers.any((p) => p.ip == ip && p.isManual))
                  .toList();
              if (peers.isEmpty && ghostManualIps.isEmpty) {
                return const Center(child: Text('暂无设备，可等待自动发现或手动添加 IP'));
              }
              return ListView(
                children: [
                  for (final peer in peers)
                    ListTile(
                      onTap: () => Navigator.of(dialogContext).pop(
                        _DeviceManagerSelection(
                          action: 'select',
                          peerId: peer.id,
                          peerIp: peer.ip,
                        ),
                      ),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      leading: Icon(
                        peer.isManual
                            ? Icons.link_rounded
                            : Icons.devices_rounded,
                      ),
                      title: Text(
                        peer.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Reachability and signed identity are different facts.
                      // Prior code always said "still needs signature" even
                      // after this session had verified and sent successfully.
                      subtitle: Text(
                        '${peer.ip} · '
                        '${_failedReconnectKeys.contains(_deviceRowKey(peer))
                            ? '最近重新认证失败 · 请检查网络和身份'
                            : peer.isStale
                            ? '自动发现 · 暂时离线'
                            : (_verifiedFingerprints[_peerKey(peer)] != null && _pairIdentity.entries.any((entry) => entry.fingerprint == _verifiedFingerprints[_peerKey(peer)]))
                            ? '本次已通过签名验证 · 发送时仍会复核'
                            : PeerManagementPolicy.displayStatus(isManual: peer.isManual, isStale: peer.isStale, lastReconnectFailed: false)}',
                        maxLines: 2,
                      ),
                      // D2 FIX1: Direct action avoids nested popup-route timing
                      // and makes authentication retry visibly accessible.
                      // It only launches the existing signed handshake; it
                      // NEVER trusts a peer based on the displayed IP/name.
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                              ),
                              minimumSize: const Size(0, 34),
                            ),
                            onPressed: () => Navigator.of(dialogContext).pop(
                              _DeviceManagerSelection(
                                action: 'reconnect',
                                peerId: peer.id,
                                peerIp: peer.ip,
                              ),
                            ),
                            child: const Text(
                              '重新认证',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: '更多设备操作',
                            icon: const Icon(Icons.more_horiz_rounded),
                            itemBuilder: (context) => [
                              if (!peer.isManual &&
                                  !_manualPeerTargetIps.contains(peer.ip))
                                const PopupMenuItem<String>(
                                  value: 'keep',
                                  child: Text('保存地址以备重连'),
                                ),
                              if (PeerManagementPolicy.canRemoveFromList(
                                isManual: peer.isManual,
                                isStale: peer.isStale,
                                lastReconnectFailed: _failedReconnectKeys
                                    .contains(_deviceRowKey(peer)),
                              ))
                                const PopupMenuItem<String>(
                                  value: 'remove',
                                  child: Text('从本机列表移除'),
                                ),
                            ],
                            onSelected: (action) {
                              // Wait for the nested popup route to finish dismissing
                              // before popping its parent device-manager dialog.
                              // A direct retry button is available alongside this
                              // menu if the platform delays popup callbacks.
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!dialogContext.mounted) return;
                                Navigator.of(dialogContext).pop(
                                  _DeviceManagerSelection(
                                    action: action,
                                    peerId: peer.id,
                                    peerIp: peer.ip,
                                  ),
                                );
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  for (final ip in ghostManualIps)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.link_off_rounded),
                      title: Text('已保存的手动 IP $ip'),
                      subtitle: const Text('已有自动发现条目，但此快捷地址仍保存在本机'),
                      trailing: IconButton(
                        tooltip: '删除保存的手动地址',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () {
                          Navigator.of(dialogContext).pop(
                            _DeviceManagerSelection(
                              action: 'removeSaved',
                              peerId: null,
                              peerIp: ip,
                            ),
                          );
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              const _DeviceManagerSelection(
                action: 'identity',
                peerId: null,
                peerIp: '',
              ),
            ),
            child: const Text('身份详情'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              const _DeviceManagerSelection(
                action: 'manual',
                peerId: null,
                peerIp: '',
              ),
            ),
            child: const Text('手动地址（备用）'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    if (selected.action == 'identity') {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('身份详情'),
          content: SingleChildScrollView(child: _desktopSessionSidebarCard()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('返回'),
            ),
          ],
        ),
      );
      return;
    }
    if (selected.action == 'manual') {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('手动连接（备用）'),
          content: SingleChildScrollView(
            child: _manualConnectSection(compact: true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('返回'),
            ),
          ],
        ),
      );
      return;
    }
    service.logDiagnostic('设备管理：已选择 ${selected.action} ${selected.peerIp}');
    if (selected.action == 'removeSaved') {
      await _removeSavedAddressOnly(selected.peerIp);
      return;
    }
    // Resolve again: a device may expire/change while the menu is open.
    final matches = service.peers
        .where(
          (peer) => peer.id == selected.peerId && peer.ip == selected.peerIp,
        )
        .toList();
    if (matches.isEmpty) {
      _toast('设备已失联或地址改变，请刷新后再操作');
      return;
    }
    final peer = matches.first;
    if (selected.action == 'select') {
      _choosePeer(peer);
    } else if (selected.action == 'reconnect') {
      await _reconnectManagedPeer(peer);
    } else if (selected.action == 'keep') {
      await _keepDiscoveredPeerAddress(peer);
    } else if (selected.action == 'remove') {
      await _removeManagedPeer(peer);
    }
  }

  Future<void> _keepDiscoveredPeerAddress(NearPeer peer) async {
    if (peer.isManual ||
        !SamePlatformConnectionPolicy.isPlausibleLanAddress(peer.ip)) {
      _toast('只能保存局域网内的有效 IPv4 地址');
      return;
    }
    try {
      final updated = Set<String>.of(_manualPeerTargetIps)..add(peer.ip);
      await (await _ensureManualPeerTargetStore()).save(updated);
      if (!mounted) return;
      setState(
        () => _manualPeerTargetIps
          ..clear()
          ..addAll(updated),
      );
      _toast('已保存地址以备重连；仍需签名认证，不能凭 IP 直接发送');
    } catch (e) {
      if (mounted) _toast('保存设备快捷地址失败：$e');
    }
  }

  Future<void> _removeSavedAddressOnly(String ip) async {
    if (sending ||
        _sendQueue.pendingCount > 0 ||
        _pairingBusy ||
        _textTrialBusy.value ||
        _reconnectingKeys.isNotEmpty) {
      _toast('当前有任务进行中，稍后再删除地址');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除已保存的手动地址'),
        content: Text('$ip\n\n仅移除本机保存的地址快捷入口，不会撤销加密授权。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = Set<String>.of(_manualPeerTargetIps)..remove(ip);
      await (await _ensureManualPeerTargetStore()).save(updated);
      if (!mounted) return;
      setState(
        () => _manualPeerTargetIps
          ..clear()
          ..addAll(updated),
      );
      _toast('手动地址已删除，自动发现设备与配对授权均保留');
    } catch (e) {
      if (mounted) _toast('地址保存失败，未移除：$e');
    }
  }

  Future<ManualPeerTargetStore> _ensureManualPeerTargetStore() async {
    final current = _manualPeerTargetStore;
    if (current != null) return current;
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}LinYueManualPeerTargets',
    );
    final store = ManualPeerTargetStore(directory: directory);
    _manualPeerTargetStore = store;
    return store;
  }

  Future<void> _restoreManualPeerTargets() async {
    try {
      final store = await _ensureManualPeerTargetStore();
      final addresses = await store.load();
      _manualPeerTargetIps.addAll(addresses);
      var added = 0;
      for (final ip in addresses) {
        if (service.peers.any((peer) => peer.ip == ip)) continue;
        try {
          service.addManualPeer(ip);
          added++;
        } catch (e) {
          service.logDiagnostic('忽略无法恢复的手动连接目标：$e');
        }
      }
      if (addresses.isNotEmpty) {
        service.logDiagnostic(
          '已恢复 ${addresses.length} 个手动连接目标（仅地址，不代表已认证）；本次新增 $added 个候选',
        );
      }
    } catch (e) {
      // A damaged locator file must not clear or rewrite identities, keys or chat history.
      service.logDiagnostic('手动连接目标恢复失败（未修改身份和密钥）：$e');
    }
  }

  Future<void> _persistManualPeerTargets() async {
    try {
      final store = await _ensureManualPeerTargetStore();
      await store.save(_manualPeerTargetIps);
    } catch (e) {
      service.logDiagnostic('手动连接目标保存失败（不影响身份和聊天历史）：$e');
    }
  }

  Future<void> _selectWindowsReceiveDirectory() async {
    if (!Platform.isWindows) return;
    if (_bluetoothReceiveRootChanging ||
        _connectionSheetOpen ||
        _bluetoothConnection?.transport.active == true) {
      _toast('更改接收文件夹前请先结束蓝牙连接');
      return;
    }
    _bluetoothReceiveRootChanging = true;
    try {
      final selection = await FilePicker.getDirectoryPath(
        dialogTitle: '选择邻跃默认接收文件夹',
      );
      if (selection == null || selection.isEmpty) return;
      final directory = Directory(selection);
      final channel = _secureChannel;
      if (channel == null) throw StateError('安全接收服务尚未就绪');
      // Reject changes during an active encrypted upload or pending offer.
      final previous = channel.targetDirectory;
      await channel.updateReceiveDirectory(directory);
      try {
        await _receiveDirectoryPreference.save(directory);
      } catch (_) {
        await channel.updateReceiveDirectory(previous);
        rethrow;
      }
      if (_bluetoothConnection != null) {
        _bluetoothConnection!.transport.fileStore = _windowsBluetoothFileStore(
          directory,
        );
      }
      if (mounted) setState(() => _receiveDirectory = directory);
      await _reloadReceivedFiles();
      _toast('默认接收位置已保存，后续新文件自动保存到此文件夹');
    } catch (e) {
      _toast('设置接收文件夹失败：$e');
    } finally {
      _bluetoothReceiveRootChanging = false;
    }
  }

  Widget _windowsReceiveDirectorySettings() {
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '默认接收位置',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          SelectableText(
            _receiveDirectory?.path ?? '应用默认接收目录',
            style: const TextStyle(color: Color(0xFFA9C0C3), fontSize: 12),
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _selectWindowsReceiveDirectory,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('更改文件夹'),
              ),
              TextButton(
                onPressed: _openReceivedFolder,
                child: const Text('打开当前目录'),
              ),
            ],
          ),
          const Text(
            '保存一次长期使用；切换目录不会移动已经接收的旧文件。',
            style: TextStyle(color: Color(0xFFA9C0C3), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Future<void> _openReceivedFolder() async {
    if (!Platform.isWindows) {
      if (mounted) setState(() => mobileTab = MobileTab.transfer);
      return;
    }
    try {
      final folder = _receiveDirectory ?? _defaultReceiveDirectory!;
      await folder.create(recursive: true);
      await Process.start('explorer.exe', [folder.path]);
    } catch (e) {
      _toast('打开接收文件夹失败：$e');
    }
  }

  Future<void> _shareReceivedFileWithSystem(File file) async {
    try {
      final directory = _receiveDirectory ?? _defaultReceiveDirectory;
      if (directory == null) {
        _toast('接收目录尚未准备好，请稍后重试');
        return;
      }
      await AndroidReceivedShare.shareFile(
        file: file,
        receiveDirectory: directory,
      );
    } catch (e) {
      if (mounted) _toast('分享失败：$e');
    }
  }

  Future<void> _shareLocalFileWithSystem(File file) async {
    try {
      await AndroidReceivedShare.shareLocalFile(file);
    } catch (e) {
      if (mounted) _toast('分享失败：$e');
    }
  }

  Future<void> _shareConversationEntry(TransferRecord entry) async {
    if (!Platform.isAndroid || entry.status != 'success') return;
    if (entry.direction == 'receive') {
      final path = entry.localPath;
      if (path == null || path.isEmpty) {
        _toast('此接收历史没有可用的本地文件路径');
        return;
      }
      await _shareReceivedFileWithSystem(File(path));
      return;
    }
    final path = entry.sourcePath;
    if (path == null || path.isEmpty) {
      _toast('此旧发送记录没有保留原文件，请重新选择文件后分享');
      return;
    }
    await _shareLocalFileWithSystem(File(path));
  }

  Future<void> _shareQueuedFile(_SecureSendJob payload) async {
    if (!Platform.isAndroid) return;
    try {
      File? file;
      final resume = payload.resume;
      if (resume != null) {
        // A resumable source may be deleted as soon as the transfer completes.
        // Give the system share sheet its own managed copy.
        file = await _retainOutgoingShareCopy(
          source: File(resume.sourcePath),
          fileName: resume.fileName,
          expectedBytes: resume.fileBytes,
        );
      } else {
        final selected = payload.selected;
        if (selected == null) throw StateError('待发送文件源不可用');
        final path = selected.path;
        if (path != null && path.isNotEmpty && await File(path).exists()) {
          file = File(path);
        } else {
          final size = await _checkedFileLength(selected);
          final (staged, temporary) = await _stageSecureFile(selected, size);
          try {
            file = await _retainOutgoingShareCopy(
              source: staged,
              fileName: selected.name,
              expectedBytes: size,
            );
          } finally {
            if (temporary != null && await temporary.exists()) {
              try {
                await temporary.delete(recursive: true);
              } catch (_) {}
            }
          }
        }
      }
      final selectedFile = file;
      if (selectedFile == null) throw StateError('待分享文件不可用');
      await AndroidReceivedShare.shareLocalFile(selectedFile);
    } catch (e) {
      if (mounted) _toast('无法分享待发送文件：$e');
    }
  }

  /// V0.1.1: Let Android's system document picker export one received file.
  /// The original file remains in the private application directory.
  Future<void> _saveReceivedToPublicFolder(File file) async {
    try {
      if (!await file.exists()) {
        _toast('文件已不存在，请重新接收');
        return;
      }
      if (Platform.isAndroid) {
        // Preserve the previously tested SAF export channel on Android.
        final savedUri = await _fileChannel.invokeMethod<String>(
          'exportReceivedFile',
          {'path': file.path},
        );
        if (!mounted) return;
        _toast(savedUri == null ? '已取消保存' : '已保存到选择的位置');
      } else if (Platform.isWindows) {
        // FilePicker 13 saveFile requires all bytes in RAM; this copy is
        // streamed instead so even a 1 GiB received file remains practical.
        final targetFolder = await FilePicker.getDirectoryPath(
          dialogTitle: '选择另存文件夹',
        );
        if (targetFolder == null || targetFolder.isEmpty) return;
        final saved = await ReceivedFileActions.saveCopyToDirectory(
          file,
          Directory(targetFolder),
        );
        if (!mounted) return;
        _toast('文件已另存为：${saved.uri.pathSegments.last}');
      } else {
        _toast('当前平台暂不支持此操作');
      }
    } catch (e) {
      _toast('另存失败：$e');
    }
  }

  // E13: export an already-received original to a public folder in ONE tap.
  // No network transfers, bitmap decoding, recompression or changes to the
  // received original. Sent history retains its separate share/open actions.
  Future<void> _quickSaveReceived(File file, {bool quiet = false}) async {
    final path = file.path;
    if (_quickSavingReceivedPaths.contains(path) ||
        _autoArchivingMediaPaths.contains(path)) {
      if (!quiet) _toast('文件正在保存，请稍候');
      return;
    }
    if (!_quickSavingReceivedPaths.add(path)) return;
    if (mounted) setState(() {});
    try {
      final receiveRoot = _receiveDirectory ?? _defaultReceiveDirectory;
      if (receiveRoot == null) throw StateError('接收目录尚未准备好');
      final source = await QuickReceivedSavePolicy.validateSource(
        file,
        receiveRoot,
      );
      final name = source.uri.pathSegments.last;
      final category = QuickReceivedSavePolicy.category(name);
      if (Platform.isAndroid) {
        final result = await AndroidQuickReceivedSave.save(source, receiveRoot);
        if (mounted) {
          setState(() => _quickSavedReceivedPaths.add(path));
          if (!quiet) _toast(result.message);
        }
      } else if (Platform.isWindows) {
        final downloads = await getDownloadsDirectory();
        if (downloads == null || !await downloads.exists()) {
          throw StateError('无法找到 Windows 默认下载目录');
        }
        var folder = QuickReceivedSavePolicy.windowsFolder(
          Platform.environment,
          category,
          downloads,
        );
        if (!await folder.exists()) folder = downloads;
        _windowsQuickSaveIndex ??= await QuickReceivedSaveIndex.inAppSupport();
        final previous = await _windowsQuickSaveIndex!.lookup(source);
        final saved = await QuickReceivedSaveIndex.saveWindows(
          source,
          folder,
          _windowsQuickSaveIndex!,
        );
        if (mounted) {
          setState(() => _quickSavedReceivedPaths.add(path));
          if (!quiet)
            _toast(
              previous != null
                  ? '已保存：${saved.uri.pathSegments.last}（无需重复下载）'
                  : '已保存：${saved.uri.pathSegments.last} → ${saved.parent.path}',
            );
        }
      } else {
        if (!quiet) _toast('当前平台暂不支持一键保存');
      }
    } catch (e) {
      if (mounted && !quiet) _toast('快捷保存失败：$e');
    } finally {
      _quickSavingReceivedPaths.remove(path);
      if (mounted) setState(() {});
    }
  }

  // E15: all selection is from our local successfully received-file listing.
  // A peer name or a sent thumbnail is never accepted as a batch save source.
  void _toggleBatchReceivedSelection(File file) {
    if (!Platform.isAndroid || !_batchSelectionMode || _batchSaveBusy) return;
    final available = ReceivedBatchSavePolicy.candidates(received);
    final path = file.path;
    if (!available.any((candidate) => candidate.path == path)) return;
    if (!_batchSelectedReceivedPaths.contains(path) &&
        _batchSelectedReceivedPaths.length >=
            ReceivedBatchSavePolicy.maxBatch) {
      _toast('最多选择 ${ReceivedBatchSavePolicy.maxBatch} 个文件');
      return;
    }
    setState(() {
      if (!_batchSelectedReceivedPaths.remove(path)) {
        _batchSelectedReceivedPaths.add(path);
      }
    });
  }

  void _batchSelectVisible(List<File> visible) {
    if (!Platform.isAndroid || _batchSaveBusy) return;
    final list = ReceivedBatchSavePolicy.candidates(visible);
    setState(() {
      _batchSelectedReceivedPaths
        ..clear()
        ..addAll(list.map((item) => item.path));
    });
    if (visible.length > list.length) {
      _toast('已选择当前列表可用的前 ${list.length} 个文件');
    }
  }

  Future<void> _batchSaveSelectedReceived() async {
    if (!Platform.isAndroid || !_batchSelectionMode || _batchSaveBusy) return;
    final files = ReceivedBatchSavePolicy.resolve(
      received,
      _batchSelectedReceivedPaths,
    );
    if (files.isEmpty) {
      _toast('请先选择要下载的接收文件');
      return;
    }
    // Frozen snapshot: selection, fresh receives or UI navigation cannot
    // swap a batch item after starting the save operation.
    setState(() {
      _batchSaveBusy = true;
      _batchSaveTotal = files.length;
      _batchSaveCompleted = 0;
    });
    var saved = 0;
    var already = 0;
    final failed = <String>[];
    try {
      for (final file in files) {
        if (!mounted) break;
        final path = file.path;
        final existed =
            _quickSavedReceivedPaths.contains(path) ||
            _autoArchivedMediaPaths.contains(path);
        try {
          // Reuse E13 native MediaStore/Download logic. It verifies file
          // presence and deduplicates previously exported destinations.
          await _quickSaveReceived(file, quiet: true);
          final complete =
              _quickSavedReceivedPaths.contains(path) ||
              _autoArchivedMediaPaths.contains(path);
          if (!complete) {
            failed.add(file.uri.pathSegments.last);
          } else if (existed) {
            already++;
          } else {
            saved++;
          }
        } catch (_) {
          failed.add(file.uri.pathSegments.last);
        } finally {
          if (mounted) setState(() => _batchSaveCompleted++);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _batchSaveBusy = false;
          _batchSelectionMode = false;
          _batchSelectedReceivedPaths.clear();
        });
        final failedNames = failed.isEmpty
            ? ''
            : '\n\n失败文件：\n${failed.join('\n')}';
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('批量保存结果'),
            content: SingleChildScrollView(
              child: Text(
                '成功处理：$saved 个\n本次跳过已保存：$already 个\n失败：${failed.length} 个'
                '$failedNames'
                '\n\n图片、视频保存到系统图库；其他文件保存到下载/LinYue。',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          ),
        );
      }
    }
  }

  Widget _batchReceivedToolbar(List<File> visible) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final checked = ReceivedBatchSavePolicy.resolve(
      received,
      _batchSelectedReceivedPaths,
    ).length;
    if (!_batchSelectionMode) {
      return TextButton.icon(
        onPressed: received.isEmpty
            ? null
            : () => setState(() {
                _batchSelectionMode = true;
                _batchSelectedReceivedPaths.clear();
              }),
        icon: const Icon(Icons.checklist_rounded, size: 18),
        label: const Text('批量下载'),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        alignment: WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          OutlinedButton(
            onPressed: _batchSaveBusy
                ? null
                : () => _batchSelectVisible(visible),
            child: const Text('全选当前列表'),
          ),
          FilledButton.icon(
            onPressed: _batchSaveBusy || checked == 0
                ? null
                : _batchSaveSelectedReceived,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(
              _batchSaveBusy
                  ? '保存中 $_batchSaveCompleted/$_batchSaveTotal'
                  : '下载 $checked 项',
            ),
          ),
          TextButton(
            onPressed: _batchSaveBusy
                ? null
                : () => setState(() {
                    _batchSelectionMode = false;
                    _batchSelectedReceivedPaths.clear();
                  }),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _conversationDownloadButton(TransferRecord entry) {
    final path = entry.localPath;
    final isSaving = path != null && _quickSavingReceivedPaths.contains(path);
    final isSaved =
        path != null &&
        (_quickSavedReceivedPaths.contains(path) ||
            _autoArchivedMediaPaths.contains(path));
    return IconButton(
      tooltip: isSaving
          ? '正在保存'
          : isSaved
          ? '已保存到本机'
          : '一键下载到本机',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      onPressed: path == null || isSaving
          ? null
          : () => _quickSaveReceived(File(path)),
      icon: Icon(
        isSaving
            ? Icons.hourglass_top_rounded
            : isSaved
            ? Icons.download_done_rounded
            : Icons.download_rounded,
        size: 18,
        color: const Color(0xFFBDFBF2),
      ),
    );
  }

  Future<void> _openReceivedFileLocation(File file) async {
    if (!Platform.isWindows) return;
    try {
      if (!await file.exists()) {
        _toast('文件已不存在');
        return;
      }
      // Explorer selection, never execute the target file.
      await Process.start('explorer.exe', ['/select,${file.absolute.path}']);
    } catch (e) {
      _toast('定位文件失败：$e');
    }
  }

  // E16: only a user-initiated document-open action can bypass the extra
  // confirmation dialog. If Android has no handler, offer a safe local save;
  // never execute the file ourselves or automatically install another app.
  Future<void> _explainMissingDocumentApp(
    File file, {
    required bool received,
  }) async {
    if (!mounted) return;
    final isDocument = SmartFileOpenPolicy.isQuickDocument(
      file.uri.pathSegments.last,
    );
    final action = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('没有找到可以打开文件的应用'),
        content: Text(
          isDocument
              ? 'Android 未找到可打开此文件的应用。可先安装 WPS 或其他兼容的文档应用，再重新点击打开。'
              : 'Android 未找到可以处理这种文件格式的应用。请先确认手机是否安装兼容应用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('知道了'),
          ),
          if (received)
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.download_rounded),
              label: const Text('保存到本机'),
            ),
        ],
      ),
    );
    if (action == true && received && mounted) {
      await _quickSaveReceived(file);
    }
  }

  Future<void> _openReceivedWithDefaultApp(File file) async {
    final isAndroid = Platform.isAndroid;
    if (!isAndroid && !Platform.isWindows) return;
    final fileName = file.uri.pathSegments.last;
    if (!ReceivedFileActions.mayOpenWithSystem(
      fileName,
      allowUnknown: isAndroid,
    )) {
      _toast('为安全起见，此类型不支持直接打开');
      return;
    }
    if (!await file.exists()) {
      _toast('文件已不存在');
      return;
    }

    Directory? androidReceiveRoot;
    String? validatedAndroidPath;
    if (isAndroid) {
      androidReceiveRoot = _receiveDirectory ?? _defaultReceiveDirectory;
      if (androidReceiveRoot == null) {
        _toast('接收目录尚未准备好，请稍后重试');
        return;
      }
      try {
        validatedAndroidPath = await AndroidReceivedOpen.validateFile(
          file: file,
          receiveDirectory: androidReceiveRoot,
        );
      } catch (e) {
        if (mounted) _toast('无法打开此接收文件：$e');
        return;
      }
    }

    if (!mounted) return;
    final quickDocument = SmartFileOpenPolicy.isQuickDocument(fileName);
    if (!quickDocument) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(isAndroid ? '用其他应用打开？' : '使用默认应用打开？'),
          content: const Text('请确认文件来自可信来源。打开文件将交给系统中的其他应用处理；邻跃不会自动运行安装包或脚本。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('打开'),
            ),
          ],
        ),
      );
      if (approved != true) return;
    }
    try {
      if (!await file.exists()) throw FileSystemException('文件已不存在', file.path);
      if (isAndroid) {
        final result = await AndroidReceivedOpen.openFile(
          file: File(validatedAndroidPath!),
          receiveDirectory: androidReceiveRoot!,
        );
        if (!mounted) return;
        if (result.type == ResultType.done) {
          _toast('已请求系统应用打开文件');
        } else if (result.type == ResultType.noAppToOpen) {
          await _explainMissingDocumentApp(file, received: true);
        } else if (result.type == ResultType.fileNotFound) {
          _toast('文件已不存在，请重新接收');
        } else if (result.type == ResultType.permissionDenied) {
          _toast('系统未授予目标应用读取文件的权限');
        } else {
          _toast('打开失败：${result.message}');
        }
        return;
      }
      // Pass one absolute argument directly: do not concatenate a command
      // or route through cmd.exe / PowerShell, avoiding command injection.
      await Process.start('explorer.exe', [file.absolute.path]);
    } catch (e) {
      if (mounted) _toast('系统打开失败：$e');
    }
  }

  Future<void> _openSentFileWithOtherApp(File file) async {
    if (!Platform.isAndroid) return;
    String canonical;
    try {
      canonical = await AndroidReceivedOpen.validateLocalFile(file: file);
    } catch (e) {
      if (mounted) _toast('无法打开此文件：$e');
      return;
    }
    if (!mounted) return;
    if (!SmartFileOpenPolicy.isQuickDocument(file.uri.pathSegments.last)) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('用其他应用打开？'),
          content: const Text(
            '将所选原文件交给手机上的其他应用处理。请确认文件可信；安装包、可执行文件和脚本不会通过此入口打开。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('打开'),
            ),
          ],
        ),
      );
      if (approved != true) return;
    }
    try {
      final result = await AndroidReceivedOpen.openLocalFile(File(canonical));
      if (!mounted) return;
      if (result.type == ResultType.done) {
        _toast('已请求系统应用打开文件');
      } else if (result.type == ResultType.noAppToOpen) {
        await _explainMissingDocumentApp(file, received: false);
      } else if (result.type == ResultType.fileNotFound) {
        _toast('文件已不存在，请重新选择');
      } else if (result.type == ResultType.permissionDenied) {
        _toast('系统未授予目标应用读取文件的权限');
      } else {
        _toast('打开失败：${result.message}');
      }
    } catch (e) {
      if (mounted) _toast('系统打开失败：$e');
    }
  }

  Future<void> _openConversationEntryWithOtherApp(TransferRecord entry) async {
    if (!Platform.isAndroid || entry.status != 'success') return;
    if (entry.direction == 'receive') {
      final path = entry.localPath;
      if (path == null || path.isEmpty) {
        _toast('此接收历史没有可用的本地文件路径');
        return;
      }
      await _openReceivedWithDefaultApp(File(path));
      return;
    }
    final path = entry.sourcePath;
    if (path == null || path.isEmpty) {
      _toast('此旧发送记录没有保留原文件，请重新选择文件后打开');
      return;
    }
    await _openSentFileWithOtherApp(File(path));
  }

  Future<void> _showReceivedDetails(File file) async {
    final exists = await file.exists();
    final size = exists ? await file.length() : null;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('文件详情'),
        content: SelectableText(
          '文件名：${file.uri.pathSegments.last}\n'
          '大小：${size == null ? '文件已不存在' : formatBytes(size)}\n'
          '应用内路径：${file.path}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // E14: the viewer works on a bounded, validated set of local image sources.
  // Sent records prefer the original and never offer "download original" when
  // only a thumbnail survives. Received originals reuse E13 one-click save.
  Future<void> _openImagePreview(
    File file, {
    String? displayName,
    bool sentThumbnail = false,
    bool receivedOriginal = true,
    List<ImagePreviewItem>? images,
    int initialIndex = 0,
  }) async {
    final name = displayName ?? file.uri.pathSegments.last;
    if (!await mayPreviewLocalImage(name, file.path)) {
      _toast('图片不存在、不受支持或过大，暂时无法预览');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ReceivedImagePreviewPage(
          file: file,
          displayName: name,
          isSentThumbnail: sentThumbnail,
          saveLabel: Platform.isAndroid ? '下载到相册' : '下载原图',
          onSave: receivedOriginal && !sentThumbnail
              ? () => unawaited(_quickSaveReceived(file))
              : null,
          items: images,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  void _openConversationEntry(TransferRecord entry) {
    unawaited(_openConversationEntryAsync(entry));
  }

  Future<void> _openConversationEntryAsync(TransferRecord entry) async {
    final success = entry.status == 'success';
    final outgoing = entry.direction == 'send';
    if (success && supportsInlineThumbnail(entry.name)) {
      final selected = await ConversationImageSource.resolve(entry);
      if (selected != null) {
        // Never show other peers' images inside this conversation album.
        final candidates = ImageCarouselPolicy.forPeer(history, entry);
        final images = <ImagePreviewItem>[];
        var initialIndex = 0;
        for (final record in candidates) {
          final resolved = identical(record, entry)
              ? selected
              : await ConversationImageSource.resolve(record);
          if (resolved == null) continue; // File moved/deleted/too large.
          if (identical(record, entry)) initialIndex = images.length;
          final imageFile = resolved.file;
          images.add(
            ImagePreviewItem(
              file: imageFile,
              displayName: record.name,
              isSentThumbnail: resolved.isSentThumbnail,
              onSave: record.direction == 'receive' && !resolved.isSentThumbnail
                  ? () => unawaited(_quickSaveReceived(imageFile))
                  : null,
            ),
          );
        }
        // A record can be opened immediately after receipt before the local
        // history list has been refreshed. Preserve the selected source.
        if (images.isEmpty) {
          images.add(
            ImagePreviewItem(
              file: selected.file,
              displayName: entry.name,
              isSentThumbnail: selected.isSentThumbnail,
              onSave: !outgoing && !selected.isSentThumbnail
                  ? () => unawaited(_quickSaveReceived(selected.file))
                  : null,
            ),
          );
        }
        await _openImagePreview(
          selected.file,
          displayName: entry.name,
          sentThumbnail: selected.isSentThumbnail,
          receivedOriginal: !outgoing,
          images: images,
          initialIndex: initialIndex,
        );
        return;
      }
    }
    if (success && !outgoing && entry.localPath != null) {
      _showReceivedActions(File(entry.localPath!));
    } else {
      if (success &&
          outgoing &&
          supportsInlineThumbnail(entry.name) &&
          mounted) {
        _toast('原图和缩略图均不可用，传输历史仍保留');
      }
      _showHistoryDetails(entry);
    }
  }

  void _openReceivedFileFromList(File file) {
    if (supportsInlineThumbnail(file.uri.pathSegments.last)) {
      unawaited(_openReceivedGallery(file));
    } else {
      _showReceivedActions(file);
    }
  }

  Future<void> _openReceivedGallery(File selected) async {
    if (!await mayPreviewLocalImage(
      selected.uri.pathSegments.last,
      selected.path,
    )) {
      _toast('图片不存在、不受支持或过大，暂时无法预览');
      return;
    }
    final files = received
        .where((file) => supportsInlineThumbnail(file.uri.pathSegments.last))
        .toList();
    final pos = files.indexWhere((file) => file.path == selected.path);
    if (pos < 0) files.add(selected);
    final at = pos < 0 ? files.length - 1 : pos;
    const maxImages = 80;
    final first = files.length > maxImages
        ? (at - maxImages ~/ 2).clamp(0, files.length - maxImages).toInt()
        : 0;
    final bounded = files.skip(first).take(maxImages);
    final images = <ImagePreviewItem>[];
    var initialIndex = 0;
    for (final file in bounded) {
      final name = file.uri.pathSegments.last;
      if (!await mayPreviewLocalImage(name, file.path)) continue;
      if (file.path == selected.path) initialIndex = images.length;
      images.add(
        ImagePreviewItem(
          file: file,
          displayName: name,
          onSave: () => unawaited(_quickSaveReceived(file)),
        ),
      );
    }
    if (images.isEmpty) {
      _toast('图片不存在、不受支持或过大，暂时无法预览');
      return;
    }
    await _openImagePreview(
      selected,
      images: images,
      initialIndex: initialIndex,
    );
  }

  Future<void> _renameReceivedFile(File file) async {
    final receiveDirectory = _receiveDirectory ?? _defaultReceiveDirectory;
    if (receiveDirectory == null) {
      _toast('接收目录尚未准备好，请稍后重试');
      return;
    }
    final oldName = file.uri.pathSegments.last;
    final controller = TextEditingController(text: oldName);
    try {
      final newName = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('重命名本地文件'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 240,
            decoration: const InputDecoration(
              labelText: '文件名',
              helperText: '只修改手机本地文件，不影响发送设备上的原文件',
            ),
            onSubmitted: (value) => Navigator.pop(dialogContext, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('重命名'),
            ),
          ],
        ),
      );
      if (newName == null || !mounted) return;
      if (newName.trim() == oldName) return;
      final renamed = await LocalReceivedFileManager.renameReceivedFile(
        file: file,
        receiveDirectory: receiveDirectory,
        newName: newName,
      );
      try {
        await historyStore.renameReceivedFilePath(
          oldPath: file.path,
          newPath: renamed.path,
          newName: renamed.uri.pathSegments.last,
        );
        if (mounted) setState(() => history = historyStore.records);
      } catch (e) {
        var reverted = false;
        try {
          await LocalReceivedFileManager.renameReceivedFile(
            file: renamed,
            receiveDirectory: receiveDirectory,
            newName: oldName,
          );
          reverted = true;
        } catch (_) {
          // Keep the verified new copy if compensation cannot complete.
        }
        await _reloadReceivedFiles();
        if (mounted) {
          _toast(
            reverted ? '历史记录保存失败，已撤销重命名：$e' : '文件已重命名，但历史记录更新失败，请检查本地历史：$e',
          );
        }
        return;
      }
      await _reloadReceivedFiles();
      if (mounted) _toast('已重命名为：${renamed.uri.pathSegments.last}');
    } catch (e) {
      if (mounted) _toast('重命名失败：$e');
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteReceivedFile(File file) async {
    final receiveDirectory = _receiveDirectory ?? _defaultReceiveDirectory;
    if (receiveDirectory == null) {
      _toast('接收目录尚未准备好，请稍后重试');
      return;
    }
    final name = file.uri.pathSegments.last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(Platform.isWindows ? '删除电脑本地接收文件？' : '删除手机本地接收文件？'),
        content: Text(
          '将删除邻跃当前接收目录中的本地文件：\n$name\n\n'
          '不会删除发送端原件、对方设备、系统相册或已另存的副本；'
          '传输历史仍保留，但本条记录将无法再打开本地文件。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB94F59),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除本地副本'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await LocalReceivedFileManager.deleteReceivedFile(
        file: file,
        receiveDirectory: receiveDirectory,
      );
      await _reloadReceivedFiles();
      if (mounted) _toast('已删除本机接收文件；传输历史已保留');
    } catch (e) {
      if (mounted) _toast('删除失败：$e');
    }
  }

  Future<void> _showReceivedActions(File file) async {
    if (!await file.exists()) {
      if (mounted) _toast('本地文件已不存在，传输历史仍保留');
      return;
    }
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Text(
                  file.uri.pathSegments.last,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              if (supportsInlineThumbnail(file.uri.pathSegments.last))
                ListTile(
                  leading: const Icon(Icons.zoom_out_map_rounded),
                  title: const Text('预览图片'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openImagePreview(file);
                  },
                ),
              if ((Platform.isAndroid &&
                      ReceivedFileActions.mayOpenWithSystem(
                        file.uri.pathSegments.last,
                        allowUnknown: true,
                      )) ||
                  (Platform.isWindows &&
                      ReceivedFileActions.mayOpenWithSystem(
                        file.uri.pathSegments.last,
                      )))
                ListTile(
                  leading: const Icon(Icons.open_in_new_rounded),
                  title: Text(
                    SmartFileOpenPolicy.actionLabel(
                      file.uri.pathSegments.last,
                      isAndroid: Platform.isAndroid,
                    ),
                  ),
                  subtitle: Text(
                    SmartFileOpenPolicy.isQuickDocument(
                          file.uri.pathSegments.last,
                        )
                        ? '由系统默认文档应用打开；若有多个应用，系统可让你选择'
                        : (Platform.isAndroid
                              ? '未知格式需要确认；系统将尝试寻找兼容应用'
                              : '仅支持常见文件类型，打开前需要确认'),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openReceivedWithDefaultApp(file);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('一键保存到本机'),
                subtitle: Text(
                  Platform.isAndroid
                      ? (QuickReceivedSavePolicy.category(
                                  file.uri.pathSegments.last,
                                ) ==
                                'document'
                            ? '直接保存到系统下载/LinYue'
                            : '图片、视频直接保存到系统相册')
                      : '直接保存到默认图片、视频或下载文件夹',
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _quickSaveReceived(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.save_alt_rounded),
                title: Text(Platform.isAndroid ? '另存到手机文件夹' : '另存到指定文件夹'),
                subtitle: Platform.isAndroid
                    ? const Text('通过系统文件选择器保存到下载或其他位置')
                    : const Text('流式复制，不覆盖同名文件'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _saveReceivedToPublicFolder(file);
                },
              ),
              if (Platform.isAndroid)
                ListTile(
                  leading: const Icon(Icons.share_rounded),
                  title: const Text('分享给其他应用'),
                  subtitle: const Text('通过 Android 系统分享面板发送所选文件'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _shareReceivedFileWithSystem(file);
                  },
                ),
              if (Platform.isWindows)
                ListTile(
                  leading: const Icon(Icons.folder_open_rounded),
                  title: const Text('打开文件所在位置'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openReceivedFileLocation(file);
                  },
                ),
              if (Platform.isAndroid)
                ListTile(
                  leading: const Icon(Icons.drive_file_rename_outline_rounded),
                  title: const Text('重命名本地文件'),
                  subtitle: const Text('只修改手机上的接收副本'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _renameReceivedFile(file);
                  },
                ),
              if (Platform.isAndroid)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline_rounded,
                    color: Color(0xFFFF9C9C),
                  ),
                  title: const Text('删除本地副本'),
                  subtitle: const Text('保留传输历史，不影响发送设备原文件'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _deleteReceivedFile(file);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制文件名'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await Clipboard.setData(
                    ClipboardData(text: file.uri.pathSegments.last),
                  );
                  _toast('文件名已复制');
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('查看文件详情'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showReceivedDetails(file);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyText(String text, {String? hint}) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast(hint ?? '已复制');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
      );
  }

  @override
  void dispose() {
    _bluetoothConnection?.removeListener(_bluetoothStateChanged);
    _bluetoothConnection?.dispose();
    final pairing = _pairing;
    if (pairing != null) unawaited(pairing.stop());
    final channel = _secureChannel;
    if (channel != null) unawaited(channel.stop());
    _restoreTimer?.cancel();
    _miniPositionPoll?.cancel();
    _sendQueue.removeListener(_onSendQueueChanged);
    _sendQueue.dispose();
    _textTrialItems.dispose();
    _textTrialBusy.dispose();
    _textTrialDraft.dispose();
    _miniCoordinator.dispose();
    _conversationInputFocus.dispose();
    ipController.dispose();
    service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        // Diagnostic observation after a frame, not proof of human visibility.
        if (service.hasPendingDiscoveryUiEvidence) {
          final snapshot = service.peers;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) service.recordDiscoveryUiFrame(snapshot);
          });
        }
        if (Platform.isWindows && _miniCoordinator.visible) {
          return _buildWindowsMiniShell();
        }
        return isDesktop ? _buildDesktopShell() : _buildMobileShell();
      },
    );
  }

  // E21-B Windows mini chat. The existing native HWND is resized; this does
  // not create another FlutterViewController, network listener, or database.
  MiniChatOwnerSnapshot _miniOwnerSnapshot() {
    final peer = _activePeer;
    final fingerprint = peer == null
        ? null
        : _verifiedFingerprints[_peerKey(peer)];
    final enrolled =
        fingerprint != null &&
        _pairIdentity.entries.any((e) => e.fingerprint == fingerprint);
    return MiniChatOwnerSnapshot(
      peerId: peer?.id,
      peerLabel: peer?.name,
      authenticatedFingerprint: fingerprint,
      peerDiscovered: peer != null && !peer.isStale,
      encryptedChannelReady:
          _secureReady && _secureChannel != null && !_pairingBusy,
      identityEnrolled: enrolled,
      textHistoryAvailable:
          _textHistoryRuntime != null &&
          fingerprint != null &&
          !_blockedTextHistoryFingerprints.contains(fingerprint) &&
          !_acknowledgedAwaitingLocalSave.containsKey(fingerprint),
      textSendBusy: _textTrialBusy.value,
      queuedFileCount: _sendQueue.pendingCount,
    );
  }

  void _refreshMiniIdentity() {
    _miniCoordinator.publishOwnerSnapshot(_miniOwnerSnapshot());
  }

  Future<void> _enterWindowsMiniChat() async {
    if (!Platform.isWindows || _miniCoordinator.visible) return;
    await _miniPreferencesReady;
    if (!mounted) return;
    final preference = _miniStoredPreference;
    final resized = await _miniWindow.enterMini(
      preset: preference.preset,
      saved: preference.saved,
    );
    if (!mounted) return;
    if (!resized) {
      _toast('无法切换迷你窗口，请检查 Windows 原生桥接');
      return;
    }
    _miniCoordinator.open(isWindows: true);
    _refreshMiniIdentity();
    var pinned = false;
    if (preference.pinned) {
      pinned = await _miniWindow.setTopmost(true);
    }
    if (!mounted) return;
    setState(() {
      _miniSizePreset = preference.preset;
      _miniWindowPinned = pinned;
    });
    _miniPositionPoll?.cancel();
    _miniPositionPoll = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_persistWindowsMiniPlacement());
    });
    await _persistWindowsMiniPlacement();
  }

  Future<void> _restoreWindowsMainChat() async {
    if (!Platform.isWindows || !_miniCoordinator.visible) return;
    // Capture current physical HWND bounds BEFORE returning to main placement.
    await _persistWindowsMiniPlacement();
    final restored = await _miniWindow.restoreMain();
    if (!mounted) return;
    if (!restored) {
      _toast('窗口恢复失败，请从标题栏重新尝试');
      return;
    }
    _miniPositionPoll?.cancel();
    _miniCoordinator.close();
    setState(() => _miniWindowPinned = false);
  }

  Future<void> _toggleMiniTopmost() async {
    if (!_miniCoordinator.visible) return;
    final requested = !_miniWindowPinned;
    if (await _miniWindow.setTopmost(requested)) {
      if (!mounted) return;
      setState(() => _miniWindowPinned = requested);
      await _persistWindowsMiniPlacement();
    } else if (mounted) {
      _toast('Windows 置顶操作没有成功');
    }
  }

  Future<void> _sendWindowsMiniText() async {
    if (_useBluetoothText) {
      _toast('蓝牙文字请在完整聊天窗口发送');
      return;
    }
    _refreshMiniIdentity();
    final ticket = _miniCoordinator.issueTextTicket();
    final peer = _activePeer;
    if (ticket == null ||
        peer == null ||
        !_miniCoordinator.validateTextTicket(ticket)) {
      _toast('请先在完整窗口完成设备配对并确认本机加密历史可用');
      return;
    }
    // E17-B2/E18-B already enforce authenticated peer identity, ACK before
    // sent state, and durable local save. Never create a second send path.
    await _sendInlineText(peer);
  }

  Future<void> _pickWindowsMiniFile() async {
    _refreshMiniIdentity();
    final ticket = _miniCoordinator.issueFileTicket();
    final peer = _activePeer;
    if (ticket == null ||
        peer == null ||
        !_miniCoordinator.validateFileTicket(ticket)) {
      _toast('请先在完整窗口完成设备配对');
      return;
    }
    try {
      final selected = await FilePicker.pickFiles(type: FileType.any);
      if (!mounted || selected == null || selected.isEmpty) return;
      // Picker has an async gap. Reject if recipient changed or a reconnect
      // invalidated the authenticated fingerprint; never silently retarget.
      _refreshMiniIdentity();
      if (!_miniCoordinator.validateFileTicket(ticket) ||
          _activePeer?.id != peer.id) {
        _toast('设备会话已改变，文件未加入发送队列；请重新选择');
        return;
      }
      _queueFiles(peer, selected);
    } catch (e) {
      if (mounted) _toast('文件选择失败：$e');
    }
  }

  Widget _windowsMiniComposer(NearPeer? peer) {
    final owner = _miniOwnerSnapshot();
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
      decoration: BoxDecoration(
        color: const Color(0xCC102C36),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: const Color(0x775BC7C3)),
      ),
      child: Row(
        children: [
          IconButton.filledTonal(
            tooltip: '添加文件',
            onPressed: owner.canAddFile ? _pickWindowsMiniFile : null,
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: _textTrialDraft,
              focusNode: _conversationInputFocus,
              autofocus: false,
              onTapOutside: (_) => _conversationInputFocus.unfocus(),
              enabled: owner.canSendText,
              maxLines: 3,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: owner.canSendText ? '输入文字（回车换行）' : '请返回主窗口验证设备',
                isDense: true,
                filled: true,
                fillColor: const Color(0x66102833),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          ValueListenableBuilder<bool>(
            valueListenable: _textTrialBusy,
            builder: (_, busy, __) => IconButton.filled(
              tooltip: busy ? '正在等待接收确认' : '发送文字',
              onPressed: owner.canSendText && !busy
                  ? _sendWindowsMiniText
                  : null,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWindowsMiniShell() {
    final peer = _activePeer;
    final owner = _miniOwnerSnapshot();
    final files = peer == null
        ? <TransferRecord>[]
        : recentConversationEntries(history, peerName: peer.name);
    return TechBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              children: [
                // E21-B FIX1: one compact status/action row.  The status is
                // derived from the same authenticated owner as mini sending;
                // there is no duplicate title or separate status heading.
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 2, 5),
                  child: SizedBox(
                    height: 34,
                    child: Row(
                      children: [
                        Icon(
                          owner.hasAuthenticatedRecipient
                              ? Icons.verified_user_outlined
                              : Icons.lock_outline_rounded,
                          color: owner.hasAuthenticatedRecipient
                              ? const Color(0xFF78D6C9)
                              : const Color(0xFFF3C47D),
                          size: 16,
                        ),
                        const SizedBox(width: 7),
                        // Click the device status to choose a window size;
                        // preserve only two dedicated top-right buttons.
                        Expanded(
                          child: PopupMenuButton<String>(
                            tooltip: '迷你窗口尺寸',
                            onSelected: _resizeWindowsMiniChat,
                            itemBuilder: (_) => [
                              CheckedPopupMenuItem(
                                value: 'small',
                                checked: _miniSizePreset == 'small',
                                child: const Text('小窗口'),
                              ),
                              CheckedPopupMenuItem(
                                value: 'medium',
                                checked: _miniSizePreset == 'medium',
                                child: const Text('中窗口'),
                              ),
                              CheckedPopupMenuItem(
                                value: 'large',
                                checked: _miniSizePreset == 'large',
                                child: const Text('大窗口'),
                              ),
                            ],
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    peer == null
                                        ? '未选择设备 · 请返回主窗口'
                                        : '${peer.name} · ${owner.hasAuthenticatedRecipient ? '已配对，发送前验证' : '需要身份验证'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFFB4C9CA),
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.arrow_drop_down_rounded,
                                  size: 16,
                                ),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: _miniWindowPinned ? '取消置顶' : '窗口置顶',
                          onPressed: _toggleMiniTopmost,
                          icon: Icon(
                            _miniWindowPinned
                                ? Icons.push_pin_rounded
                                : Icons.push_pin_outlined,
                            size: 19,
                          ),
                          constraints: const BoxConstraints.tightFor(
                            width: 35,
                            height: 34,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                        IconButton(
                          tooltip: '返回完整窗口',
                          onPressed: _restoreWindowsMainChat,
                          icon: const Icon(
                            Icons.open_in_full_rounded,
                            size: 19,
                          ),
                          constraints: const BoxConstraints.tightFor(
                            width: 35,
                            height: 34,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _glassCard(
                    radius: 18,
                    padding: const EdgeInsets.all(5),
                    focus: true,
                    deepenBlankBackground: true,
                    child: _mixedConversationItems(
                      peer: peer,
                      mobile: false,
                      files: files,
                      live: _conversationLiveProgressEntries(),
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                _windowsMiniComposer(peer),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Android home is always the conversation. History and settings remain
  // one-tap overlays in this shell; there is no device-list-to-chat route.
  Widget _buildMobileShell() {
    final atHome = mobileTab == MobileTab.nearby;
    Widget page;
    switch (mobileTab) {
      case MobileTab.nearby:
        page = _buildMobileNearbyPage();
        break;
      case MobileTab.transfer:
        page = _buildMobileTransferPage();
        break;
      case MobileTab.settings:
        page = _buildMobileSettingsPage();
        break;
    }
    return TechBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          titleSpacing: 12,
          leading: atHome
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: '返回传输对话',
                  onPressed: () => setState(() => mobileTab = MobileTab.nearby),
                ),
          title: atHome
              ? _brandTitle(compact: true)
              : Text(
                  mobileTab == MobileTab.transfer ? '传输记录' : '设置',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
          actions: atHome
              ? [
                  if (!_useBluetoothText)
                    IconButton(
                      tooltip: '刷新附近设备',
                      onPressed: service.refreshPeers,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  IconButton(
                    tooltip: '全部历史',
                    onPressed: () =>
                        setState(() => mobileTab = MobileTab.transfer),
                    icon: const Icon(Icons.history_rounded),
                  ),
                  IconButton(
                    tooltip: '设置',
                    onPressed: () =>
                        setState(() => mobileTab = MobileTab.settings),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ]
              : [],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: page,
          ),
        ),
      ),
    );
  }

  // DEV13B1: move secondary controls to the right panel to enlarge the central conversation area
  // or disabling interactions. The conversation surface stays unfiltered.
  Widget _quietPeriphery(Widget child) => ColorFiltered(
    colorFilter: const ColorFilter.matrix(<double>[
      0.644,
      0.269,
      0.027,
      0,
      0,
      0.080,
      0.833,
      0.027,
      0,
      0,
      0.080,
      0.269,
      0.591,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]),
    child: child,
  );

  Widget _buildDesktopShell() {
    return TechBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _glassCard(
              radius: 28,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _quietPeriphery(_desktopTitleBar()),
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(
                          width: 200,
                          child: _quietPeriphery(_desktopSidebar()),
                        ),
                        Container(width: 1, color: const Color(0x332A4A55)),
                        Expanded(child: _desktopMainArea()),
                        Container(width: 1, color: const Color(0x332A4A55)),
                        SizedBox(
                          width: 268,
                          child: _quietPeriphery(_desktopRightPanel()),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopTitleBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
      child: Row(
        children: [
          const SizedBox(width: 4),
          Text(
            '邻跃 LINYUE · v0.5.65 DEV13D2E38',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: const Color(0xFFB4C9CA),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _enterWindowsMiniChat,
            icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 17),
            label: const Text('迷你聊天', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          const Text(
            '开发验证版',
            style: TextStyle(color: Color(0xFFA9C0C3), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _desktopSidebar() {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const GlassLogo(size: 48),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    '邻跃',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'LINYUE',
                    style: TextStyle(
                      color: Color(0xFFA9C0C3),
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),
          _navButton(
            active: desktopTab == DesktopTab.nearby,
            icon: Icons.radar_rounded,
            label: '聊天',
            onTap: () => setState(() => desktopTab = DesktopTab.nearby),
          ),
          const SizedBox(height: 12),
          _navButton(
            active: desktopTab == DesktopTab.transfer,
            icon: Icons.swap_horiz_rounded,
            label: '传输记录',
            onTap: () => setState(() => desktopTab = DesktopTab.transfer),
          ),
          const SizedBox(height: 12),
          _navButton(
            active: desktopTab == DesktopTab.files,
            icon: Icons.folder_copy_outlined,
            label: '接收文件',
            onTap: () => setState(() => desktopTab = DesktopTab.files),
          ),
          const SizedBox(height: 12),
          _navButton(
            active: desktopTab == DesktopTab.settings,
            icon: Icons.settings_rounded,
            label: '设置',
            onTap: () => setState(() => desktopTab = DesktopTab.settings),
          ),
          const Spacer(),
          const Text(
            '首页顶部连接设备 · ＋选择文件',
            style: TextStyle(fontSize: 11, color: Color(0xFFA9C0C3)),
          ),
        ],
      ),
    );
  }

  Widget _navButton({
    required bool active,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: active
              ? const LinearGradient(
                  colors: [Color(0xAA4BD1C6), Color(0x5536A39E)],
                )
              : const LinearGradient(
                  colors: [Color(0x161C404D), Color(0x0E152F39)],
                ),
          border: Border.all(
            color: active ? const Color(0x66BFF6F3) : const Color(0x332A4A55),
          ),
          boxShadow: active
              ? [
                  const BoxShadow(
                    color: Color(0x3335F1E8),
                    blurRadius: 22,
                    spreadRadius: -6,
                    offset: Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: active ? const Color(0xFFE9F4F2) : const Color(0xFFA9C0C3),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: active
                    ? const Color(0xFFE8F2F0)
                    : const Color(0xFFC9DCDB),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktopMainArea() {
    switch (desktopTab) {
      case DesktopTab.nearby:
        return _desktopNearbyPage();
      case DesktopTab.transfer:
        return _desktopTransferPage();
      case DesktopTab.files:
        return _desktopFilesPage();
      case DesktopTab.settings:
        return _desktopSettingsPage();
    }
  }

  Widget _progressDetails(TransferProgressInfo entry, {bool compact = false}) {
    final isError = entry.phase == TransferProgressPhase.failed;
    final isDone = entry.phase == TransferProgressPhase.completed;
    final progress = entry.fraction;
    final speed = entry.speedBytesPerSecond;
    final eta = entry.eta;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry.direction == 'send' ? '↑ ${entry.name}' : '↓ ${entry.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          entry.phaseLabel,
          style: TextStyle(
            fontSize: 11.5,
            color: isError
                ? const Color(0xFFFFB39E)
                : isDone
                ? const Color(0xFF95EAD0)
                : const Color(0xFFB4D4D1),
          ),
        ),
        const SizedBox(height: 7),
        if (entry.isBytePhase && progress != null) ...[
          LinearProgressIndicator(
            value: progress,
            minHeight: compact ? 5 : 6,
            color: const Color(0xFF74D9D2),
            backgroundColor: const Color(0x442D6570),
          ),
          const SizedBox(height: 5),
          Text(
            '${entry.percent}% · ${formatBytes(entry.safeBytes)} / ${formatBytes(entry.totalBytes)}',
            style: const TextStyle(fontSize: 11, color: Color(0xFFC7E0DD)),
          ),
          if (speed != null && entry.safeBytes < entry.totalBytes)
            Text(
              '${formatBytes(speed.round())}/s${eta == null ? '' : ' · 预计约 ${eta.inSeconds + 1} 秒'}',
              style: const TextStyle(fontSize: 10.5, color: Color(0xFFA9C0C3)),
            ),
        ] else if (!isDone && !isError) ...[
          const LinearProgressIndicator(minHeight: 4, color: Color(0xFF74D9D2)),
        ],
        if (isDone)
          const Text(
            '已收到并验证加密回执 / 已验证并保存',
            style: TextStyle(fontSize: 10.5, color: Color(0xFFA9C0C3)),
          ),
      ],
    );
  }

  // DEV13C3: this same compact/expandable status widget is shared by
  // Windows and Android conversation layouts. No transport state is changed.
  Widget _conversationProgressBar() {
    final entries = <TransferProgressInfo>[
      if (_outgoingProgress != null) _outgoingProgress!,
      if (_incomingProgress != null) _incomingProgress!,
    ];
    return CollapsibleTransferStatus(
      entries: entries,
      detailsBuilder: (entry) => _progressDetails(entry, compact: true),
    );
  }

  // The right sidebar keeps urgent information visible but folds low-priority
  // controls into a one-line preview. Every strip is keyboard/touch accessible.
  Widget _sidebarPreviewStrip({
    required String title,
    required String summary,
    required IconData icon,
    required bool expanded,
    required ValueChanged<bool> onChanged,
    required Widget details,
    bool forceExpanded = false,
  }) {
    final isOpen = expanded || forceExpanded;
    return _glassCard(
      radius: 17,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: forceExpanded ? null : () => onChanged(!expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 17, color: const Color(0xFF8CD5D0)),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFE2EEEC),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFFA9C0C3),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 5),
                    Icon(
                      isOpen
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: const Color(0xFF91C5C4),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: details,
            ),
        ],
      ),
    );
  }

  Widget _desktopRightPanel() {
    final hasProgress = _outgoingProgress != null || _incomingProgress != null;
    final activeOrFailedProgress = [
      _outgoingProgress,
      _incomingProgress,
    ].any((p) => p != null && p.phase != TransferProgressPhase.completed);
    final hasPendingRestore = _pendingRestores.isNotEmpty;
    final hasQueueIssue = _resumeJournalError != null || hasPendingRestore;
    final queueBusy =
        _sendQueue.isSending ||
        _sendQueue.pendingCount > 0 ||
        _preparingBatches > 0 ||
        _resumeChecking ||
        _resumeCleanupRunning;
    final mustShowQueue = hasQueueIssue || queueBusy;
    final statusSummary = activeOrFailedProgress
        ? '正在处理传输或需要检查'
        : hasProgress
        ? '最近传输已完成'
        : '暂无任务';
    final queueSummary = hasQueueIssue
        ? '有待恢复任务或记录异常'
        : queueBusy
        ? '待发送 ${_sendQueue.pendingCount} 项 · 进行中'
        : '待发送 0 项 · 可展开查看存储体检';
    final latestName = received.isEmpty
        ? '暂无文件'
        : compactRecentFileName(received.first.uri.pathSegments.last);
    return Padding(
      padding: const EdgeInsets.all(18),
      child: ListView(
        children: [
          _sidebarPreviewStrip(
            title: '传输状态',
            summary: statusSummary,
            icon: Icons.sync_alt_rounded,
            expanded: _rightIdleStatusOpen,
            forceExpanded: activeOrFailedProgress,
            onChanged: (value) => setState(() => _rightIdleStatusOpen = value),
            details: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_outgoingProgress != null)
                  _progressDetails(_outgoingProgress!),
                if (_outgoingProgress != null && _incomingProgress != null)
                  const SizedBox(height: 14),
                if (_incomingProgress != null)
                  _progressDetails(_incomingProgress!),
                if (!hasProgress)
                  const Text(
                    '暂无任务',
                    style: TextStyle(fontSize: 11, color: Color(0xFFA9C0C3)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _sidebarPreviewStrip(
            title: '发送队列',
            summary: queueSummary,
            icon: Icons.queue_rounded,
            expanded: _rightQueueOpen,
            forceExpanded: mustShowQueue,
            onChanged: (value) => setState(() => _rightQueueOpen = value),
            details: _queueStatusPanel(compact: true, embedded: true),
          ),
          const SizedBox(height: 10),
          _sidebarPreviewStrip(
            title: '最近接收 · ${received.length}',
            summary: latestName,
            icon: Icons.folder_outlined,
            expanded: _rightRecentOpen,
            onChanged: (value) => setState(() => _rightRecentOpen = value),
            details: received.isEmpty
                ? const Text(
                    '暂无文件',
                    style: TextStyle(fontSize: 11, color: Color(0xFFA9C0C3)),
                  )
                : Column(
                    children: received
                        .take(3)
                        .map((file) => _simpleFileRow(file))
                        .toList(),
                  ),
          ),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: Text(
              '仅使用加密传输 · 开发验证版',
              style: TextStyle(color: Color(0xFF9BB4B5), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopSessionSidebarCard() {
    final peer = _activePeer;
    final pairState = peer == null
        ? '等待选择设备'
        : (peer.isManual
              ? '手动连接'
              : peer.isStale
              ? '暂时失联'
              : '最近可达');
    final pairHint = peer == null
        ? '从左侧选择设备后，文件会直接进入中间对话区。'
        : (peer.isStale
              ? '正在自动重连 · 可稍后继续发送'
              : (_secureReady ? '加密通道已启动 · 发前验证身份' : '加密服务未就绪'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer?.name ?? '快速投送',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    pairHint,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFFA9C0C3),
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '重新发现设备',
              onPressed: service.refreshPeers,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              peer == null ? Icons.radar_rounded : Icons.verified_user_outlined,
              size: 18,
              color: peer == null
                  ? const Color(0xFFA9C0C3)
                  : peer.isStale
                  ? const Color(0xFFF2B84B)
                  : const Color(0xFF6EF0C7),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                pairState,
                style: const TextStyle(fontSize: 12, color: Color(0xFFD2E8E5)),
              ),
            ),
          ],
        ),
        if (peer != null) ...[
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _pairControl(peer)),
        ],
      ],
    );
  }

  List<TransferProgressInfo> _conversationLiveProgressEntries() {
    final entries = <TransferProgressInfo>[];
    final outgoing = _outgoingProgress;
    final incoming = _incomingProgress;
    if (outgoing != null && outgoing.phase != TransferProgressPhase.completed) {
      entries.add(outgoing);
    }
    if (incoming != null && incoming.phase != TransferProgressPhase.completed) {
      entries.add(incoming);
    }
    return entries;
  }

  // DEV13-D2C: presentation-only message cards. The transfer identity,
  // history and encrypted streaming code are intentionally unchanged.
  String _conversationProgressHeader(TransferProgressInfo entry) {
    final outgoing = entry.direction == 'send';
    final failed = entry.phase == TransferProgressPhase.failed;
    final done = entry.phase == TransferProgressPhase.completed;
    if (failed) return outgoing ? '发送失败' : '接收失败';
    if (done) return outgoing ? '发送完成' : '接收完成';
    if (entry.isBytePhase && entry.fraction != null) {
      return '${outgoing ? '发送中' : '接收中'} · ${entry.percent}%';
    }
    return outgoing ? '准备发送' : '准备接收';
  }

  Widget _conversationImageCard(String imagePath, {required bool mobile}) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final maxWidth = ChatMediaSizing.imageWidth(
      mobile: mobile,
      viewportWidth: viewportWidth,
    );
    final maxHeight = ChatMediaSizing.imageHeight(
      mobile: mobile,
      viewportWidth: viewportWidth,
    );
    // Unlike a fixed SizedBox, RenderImage uses the decoded intrinsic aspect
    // ratio inside these constraints. Portrait, square and wide photos no
    // longer occupy the same empty rectangular frame.
    return ClipRRect(
      borderRadius: BorderRadius.circular(13),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Image.file(
          File(imagePath),
          cacheWidth: mobile ? 440 : 520,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => SizedBox(
            width: math.min(maxWidth, 180),
            height: 100,
            child: const Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 30,
                color: Color(0xFF9FCFD0),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _conversationFileCard({
    required String fileName,
    required String? localPath,
    required bool mobile,
    String? secondary,
    Widget? trailing,
  }) {
    // Single-layer card: the outer message bubble owns the background/border.
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: mobile ? 168 : 205,
        maxWidth: ChatMediaSizing.fileMaxWidth(
          mobile: mobile,
          viewportWidth: MediaQuery.sizeOf(context).width,
        ),
        minHeight: mobile ? 50 : 54,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FileVisualBadge(
            fileName: fileName,
            localPath: localPath,
            size: mobile ? 40 : 44,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: mobile ? 12.8 : 13.1,
                    height: 1.35,
                  ),
                ),
                if (secondary != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    secondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.7,
                      color: Color(0xFFB0D4D1),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }

  Widget _techProgressRing(TransferProgressInfo entry, {double size = 48}) {
    final failed = entry.phase == TransferProgressPhase.failed;
    final done = entry.phase == TransferProgressPhase.completed;
    final color = failed
        ? const Color(0xFFFFA990)
        : done
        ? const Color(0xFF8DF0D1)
        : const Color(0xFF7AF4E4);
    // A failed transfer retains the actual partial fraction. Filling the ring
    // on failure incorrectly implied that the entire file was delivered.
    final value = done
        ? 1.0
        : failed
        ? (entry.fraction ?? 0.0)
        : entry.isBytePhase
        ? entry.fraction
        : null;
    final centerLabel = failed
        ? '!'
        : done
        ? '✓'
        : entry.isBytePhase && entry.fraction != null
        ? '${entry.percent}'
        : '··';
    return Semantics(
      label:
          '${_conversationProgressHeader(entry)}，${entry.isBytePhase ? '${entry.percent}%' : entry.phaseLabel}',
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: size - 8,
              height: size - 8,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x405DD5C9), Color(0x14112831)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x2A65E9DF),
                    blurRadius: 14,
                    spreadRadius: -5,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 3.6,
                backgroundColor: const Color(0x3678CBC7),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            if (entry.isBytePhase && !failed && !done && entry.fraction != null)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    centerLabel,
                    style: TextStyle(
                      fontSize: size < 48 ? 11 : 12,
                      fontWeight: FontWeight.w700,
                      color: color,
                      height: 1,
                    ),
                  ),
                  const Text(
                    '%',
                    style: TextStyle(
                      fontSize: 8,
                      color: Color(0xFFBDEBE6),
                      height: 1,
                    ),
                  ),
                ],
              )
            else
              Text(
                centerLabel,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _conversationLiveBubble(
    TransferProgressInfo entry, {
    required bool mobile,
    String error = '',
    bool cancelled = false,
  }) {
    final outgoing = entry.direction == 'send';
    final failed = entry.phase == TransferProgressPhase.failed;
    final color = outgoing ? const Color(0x5647BEB7) : const Color(0x502F5562);
    final border = failed
        ? const Color(0x88FFB39E)
        : outgoing
        ? const Color(0x886FE7DE)
        : const Color(0x667EB2B9);
    final speed = entry.speedBytesPerSecond;
    final status = cancelled
        ? '已取消 · 未确认完成'
        : _conversationProgressHeader(entry);
    final secondary = entry.isBytePhase
        ? '$status · ${formatBytes(entry.safeBytes)} / ${formatBytes(entry.totalBytes)}'
        : status;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: mobile ? MediaQuery.sizeOf(context).width * 0.81 : 440,
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: 10,
            left: outgoing ? (mobile ? 26 : 30) : 0,
            right: outgoing ? 0 : (mobile ? 26 : 30),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _conversationFileCard(
                  fileName: entry.name,
                  localPath: null,
                  mobile: mobile,
                  secondary: secondary,
                  trailing: _techProgressRing(entry, size: mobile ? 40 : 44),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      error,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFFFB39E),
                      ),
                    ),
                  ),
                if (entry.isBytePhase &&
                    speed != null &&
                    speed > 0 &&
                    !failed) ...[
                  const SizedBox(height: 5),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${formatBytes(speed.round())}/s',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Color(0xFFB6DAD6),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // E20-C2: record deletion intentionally never touches any physical
  // file, outgoing source, sent-thumbnail, gallery or remote device.
  Future<void> _deleteConversationFileRecord(TransferRecord entry) async {
    if (!ConversationDeletionPolicy.canRemoveLocalRecord(
          direction: entry.direction,
          status: entry.status,
        ) ||
        !historyStore.records.any((e) => identical(e, entry))) {
      _toast('该会话记录已变化，请刷新后重试');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条文件会话记录？'),
        content: Text(
          '文件：${entry.name}\n\n'
          '只从本机聊天和传输历史中移除此条记录。'
          '不删除任何接收文件、发送源文件、系统图库或对方设备的内容。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除会话记录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final removed = await historyStore.removeRecord(entry);
      if (mounted) setState(() => history = historyStore.records);
      if (mounted) _toast(removed ? '本机会话记录已删除，原文件未删除' : '此记录已不存在，无需重复删除');
    } catch (e) {
      if (mounted) _toast('删除记录失败，已保留原记录：$e');
    }
  }

  // E20-C2: one Chinese file-action sheet on both platforms.
  // Incoming-file deletion is restricted to the current receive root.
  Future<void> _showConversationFileActions(TransferRecord entry) async {
    if (!mounted) return;
    final canOpenOrShare = entry.status == 'success';
    final canDeleteReceived = ConversationDeletionPolicy.canDeleteReceivedCopy(
      direction: entry.direction,
      status: entry.status,
      localPath: entry.localPath,
    );
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: const Text('文件操作'),
              ),
              if (canOpenOrShare)
                ListTile(
                  leading: const Icon(Icons.open_in_new_rounded),
                  title: Text(
                    Platform.isAndroid
                        ? '用其他应用打开'
                        : entry.direction == 'receive'
                        ? '打开／预览文件'
                        : '查看文件详情',
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (Platform.isAndroid) {
                      unawaited(_openConversationEntryWithOtherApp(entry));
                    } else {
                      _openConversationEntry(entry);
                    }
                  },
                ),
              if (canOpenOrShare && Platform.isAndroid)
                ListTile(
                  leading: const Icon(Icons.share_rounded),
                  title: const Text('分享给其他应用'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_shareConversationEntry(entry));
                  },
                ),
              if (canDeleteReceived)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline_rounded,
                    color: Color(0xFFFF9C9C),
                  ),
                  title: const Text('删除本机接收文件'),
                  subtitle: const Text('保留会话记录，不删除对方文件或图库副本'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_deleteReceivedFile(File(entry.localPath!)));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline_rounded),
                title: const Text('删除会话记录'),
                subtitle: const Text('不删除实际文件'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_deleteConversationFileRecord(entry));
                },
              ),
              ListTile(
                leading: const Icon(Icons.close_rounded),
                title: const Text('取消'),
                onTap: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _conversationFileActionsButton(TransferRecord entry) {
    return IconButton(
      tooltip: '文件操作',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      onPressed: () => unawaited(_showConversationFileActions(entry)),
      icon: const Icon(
        Icons.more_horiz_rounded,
        size: 20,
        color: Color(0xFFBDFBF2),
      ),
    );
  }

  // DEV13D2E20-B: Windows OLE COPY drag only, offered from completed
  // received-file cards. This never moves the app's stored original.
  Future<void> _startConversationReceivedDrag(TransferRecord entry) async {
    if (!Platform.isWindows ||
        entry.direction != 'receive' ||
        entry.status != 'success')
      return;
    final result = await WindowsReceivedDragOut.start(
      record: entry,
      receiveRoot: _receiveDirectory ?? _defaultReceiveDirectory,
    );
    if (!mounted) return;
    switch (result) {
      case ReceivedDragOutResult.offeredToSystem:
        _toast('已交给 Windows 复制处理；同名文件请按系统提示确认');
        break;
      case ReceivedDragOutResult.cancelled:
        break;
      case ReceivedDragOutResult.denied:
        _toast('不能拖出：仅允许当前接收目录中完整且未经改变的接收文件');
        break;
      case ReceivedDragOutResult.unavailable:
        _toast('Windows 拖出组件未启用，请确认运行的是本次新构建的 Windows 程序');
        break;
      case ReceivedDragOutResult.failed:
        _toast('拖出未完成，请重新尝试，接收原件不会被修改');
        break;
    }
  }

  Future<void> _playConversationVideo(TransferRecord entry) async {
    final path = entry.direction == 'receive'
        ? entry.localPath
        : entry.sourcePath;
    if (!ChatCardDisplayPolicy.offerVideoPlay(
          successful: entry.status == 'success',
          videoExtension: MobileMediaSourcePolicy.isVideoName(entry.name),
          originalPath: path,
        ) ||
        !MobileMediaSourcePolicy.isVideoName(path!)) {
      _toast('本机没有可播放的视频原件，记录仍然保留');
      return;
    }
    final file = File(path!);
    if (!await file.exists()) {
      _toast('视频原件已不存在，请重新选择文件');
      return;
    }
    if (entry.direction == 'receive') {
      await _openReceivedWithDefaultApp(file);
    } else if (Platform.isAndroid) {
      await _openSentFileWithOtherApp(file);
    } else if (Platform.isWindows) {
      // Shell association, no cmd or shell-interpolated command line.
      try {
        await Process.start('explorer.exe', [file.absolute.path]);
      } catch (e) {
        if (mounted) _toast('无法调用系统播放器：$e');
      }
    }
  }

  // E20-C3B: read-only frame extraction via Android MediaMetadataRetriever or
  // Windows Shell thumbnails, with a generic poster when codec is unavailable.
  // Neither media original nor transfer bytes are ever modified.
  Widget _conversationVideoPoster(
    TransferRecord entry, {
    required bool mobile,
  }) {
    final originalPath = entry.direction == 'receive'
        ? entry.localPath
        : entry.sourcePath;
    final width = mobile ? 205.0 : 244.0;
    final height = mobile ? 130.0 : 152.0;
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ConversationVideoThumbnail(
            key: ValueKey('video-preview-${entry.name}-$originalPath'),
            path: originalPath,
            width: width,
            height: height,
          ),
          Center(
            child: IconButton.filledTonal(
              tooltip: '播放视频',
              onPressed: () => unawaited(_playConversationVideo(entry)),
              iconSize: 38,
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          ),
          Positioned(
            left: 9,
            right: 9,
            bottom: 8,
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white,
                shadows: [Shadow(color: Colors.black, blurRadius: 5)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _conversationRecordBubble(
    TransferRecord entry, {
    required bool mobile,
  }) {
    final outgoing = entry.direction == 'send';
    final success = entry.status == 'success';
    final color = outgoing ? const Color(0x5647BEB7) : const Color(0x502F5562);
    final border = success
        ? outgoing
              ? const Color(0x886FE7DE)
              : const Color(0x667EB2B9)
        : const Color(0x88FFB39E);
    final path = success
        ? (outgoing ? entry.thumbnailPath : entry.localPath)
        : null;
    final image = path != null && supportsInlineThumbnail(entry.name);
    final isVideo = success && MobileMediaSourcePolicy.isVideoName(entry.name);
    final canDragEntireCard =
        ConversationCardInteractionPolicy.canDragEntireReceivedCard(
          isWindows: Platform.isWindows,
          direction: entry.direction,
          status: entry.status,
          localPath: entry.localPath,
        );
    final allowQuickSave =
        success &&
        QuickReceivedSavePolicy.availableForRecord(
          direction: entry.direction,
          status: entry.status,
          localPath: entry.localPath,
        );
    final contents = image || isVideo
        ? Stack(
            children: [
              image
                  ? _conversationImageCard(path, mobile: mobile)
                  : _conversationVideoPoster(entry, mobile: mobile),
              if (allowQuickSave)
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Color(0xCC0B1C23),
                      shape: BoxShape.circle,
                    ),
                    child: _conversationDownloadButton(entry),
                  ),
                ),
            ],
          )
        : _conversationFileCard(
            fileName: entry.name,
            localPath: path,
            mobile: mobile,
            secondary:
                '${formatBytes(entry.bytes)} · ${success ? '已完成' : '失败'}',
            trailing: allowQuickSave
                ? _conversationDownloadButton(entry)
                : null,
          );
    final fileCard = Material(
      color: Colors.transparent,
      child: GestureDetector(
        onPanStart: canDragEntireCard
            ? (_) => unawaited(_startConversationReceivedDrag(entry))
            : null,
        child: InkWell(
          onTap: isVideo
              ? () => unawaited(_playConversationVideo(entry))
              : () => _openConversationEntry(entry),
          borderRadius: BorderRadius.circular(17),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: image || isVideo ? 5 : 12,
              vertical: image || isVideo ? 5 : 10,
            ),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: border),
            ),
            child: contents,
          ),
        ),
      ),
    );
    final bubbleAndActions = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Outgoing: menu | card | avatar; incoming stays avatar | card | menu.
        if (ChatSelectionAndActionsPolicy.actionsBeforeBubble(
          outbound: outgoing,
        )) ...[
          _conversationFileActionsButton(entry),
          const SizedBox(width: 2),
        ],
        Flexible(child: fileCard),
        if (!ChatSelectionAndActionsPolicy.actionsBeforeBubble(
          outbound: outgoing,
        )) ...[
          const SizedBox(width: 2),
          _conversationFileActionsButton(entry),
        ],
      ],
    );
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: outgoing
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Tooltip(
          message:
              '${entry.name}\n${_historyTimestamp(entry.timestamp)} · '
              '${conversationSizeLabel(entry)}\n'
              '${success ? '传输完成' : '传输失败'}',
          child: bubbleAndActions,
        ),
        if (image || isVideo)
          Text(
            '${entry.name} · ${formatBytes(entry.bytes)} · ${success ? '已完成' : '失败'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Color(0xFFB4C9CA)),
          ),
        _conversationTimeLabel(entry.timestamp, outbound: outgoing),
      ],
    );
    final avatar = _conversationDeviceAvatar(
      outbound: outgoing,
      mobile: mobile,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 5),
      child: Row(
        mainAxisAlignment: outgoing
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!outgoing) ...[avatar, const SizedBox(width: 7)],
          Flexible(child: body),
          if (outgoing) ...[const SizedBox(width: 7), avatar],
        ],
      ),
    );
  }

  Widget _desktopNearbyPage() {
    final peer = _activePeer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _connectionControls(),
          const SizedBox(height: 8),
          Expanded(
            child: _useBluetoothText || peer == null
                ? _glassCard(
                    focus: true,
                    deepenBlankBackground: true,
                    child: _mixedConversationItems(
                      peer: peer,
                      mobile: false,
                      files: const [],
                      live: const [],
                    ),
                  )
                : _conversationHistory(peer),
          ),
          const SizedBox(height: 12),
          if (!_useBluetoothText && peer != null)
            _desktopDropComposer(peer)
          else
            _unifiedTextComposer(peer, mobile: false),
        ],
      ),
    );
  }

  // Keep Windows consistent with Android: sent bubbles on the right, received
  // bubbles on the left. Legacy received-file records have no authenticated
  // sender identity; they must never be attributed to the selected device.
  Widget _conversationHistory(NearPeer peer) {
    final visible = recentConversationEntries(history, peerName: peer.name);
    final live = _conversationLiveProgressEntries();
    return _glassCard(
      focus: true,
      deepenBlankBackground: true,
      padding: const EdgeInsets.all(12),
      child: _mixedConversationItems(
        peer: peer,
        mobile: false,
        files: visible,
        live: live,
      ),
    );
  }

  Widget _desktopDropComposer(NearPeer peer) {
    return DropTarget(
      enable: true,
      onDragDone: (details) async {
        await _handleDroppedFiles(details.files);
      },
      onDragEntered: (_) {
        if (mounted) setState(() => _dropHover = true);
      },
      onDragExited: (_) {
        if (mounted) setState(() => _dropHover = false);
      },
      child: Container(
        decoration: BoxDecoration(
          color: _dropHover ? const Color(0x5056D9CF) : const Color(0x221B5360),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _dropHover
                ? const Color(0xFF9AFFF4)
                : const Color(0x6682C7C5),
            width: 1.6,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _unifiedTextComposer(peer, mobile: false),
            const SizedBox(height: 6),
            Text(
              _dropHover
                  ? '松开即可将文件加入发送队列'
                  : sending
                  ? '文件发送中 · 可继续拖入排队'
                  : '支持拖入文件 · 单文件最大 1 GiB · 本机文字已加密保存',
              style: const TextStyle(color: Color(0xFFA9C0C3), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  String _historyTimestamp(DateTime dt) {
    final d = dt.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${pad(d.month)}-${pad(d.day)} ${pad(d.hour)}:${pad(d.minute)}';
  }

  Future<void> _showHistoryDetails(TransferRecord item) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('传输详情'),
        content: SelectableText(
          '文件：${item.name}\n'
          '方向：${item.direction == 'send' ? '发送' : '接收'}\n'
          '设备：${item.peerName}\n'
          '结果：${item.status == 'success' ? '成功' : '失败'}\n'
          '大小：${conversationSizeLabel(item)}\n'
          '时间：${_historyTimestamp(item.timestamp)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空传输历史？'),
        content: const Text('只清除本机历史记录，不删除任何已接收的文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空历史'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await historyStore.clear();
      if (mounted) setState(() => history = historyStore.records);
      await SentImagePreviewStore.prune(
        const <String>{},
        minAge: Duration.zero,
      );
      _toast('本机传输历史与发送图片缩略图已清空，接收文件未删除');
    } catch (e) {
      _toast('清除历史失败：$e');
    }
  }

  Widget _historyCard(TransferRecord item) {
    final outgoing = item.direction == 'send';
    final success = item.status == 'success';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 2),
      leading: FileVisualBadge(
        fileName: item.name,
        localPath: success
            ? (outgoing ? item.thumbnailPath : item.localPath)
            : null,
        size: 42,
      ),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${outgoing ? '发送到' : '接收自'} ${item.peerName}\n'
        '${_historyTimestamp(item.timestamp)} · ${formatBytes(item.bytes)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFFA9C0C3),
          fontSize: 12,
          height: 1.5,
        ),
      ),
      trailing: Text(
        success ? '成功' : '失败',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: success ? const Color(0xFF6EF0C7) : const Color(0xFFEFA99B),
        ),
      ),
      onTap: () => _openConversationEntry(item),
    );
  }

  Widget _historySection() {
    final displayed = history
        .where(
          (entry) =>
              historyFilter == HistoryFilter.all ||
              (historyFilter == HistoryFilter.sent &&
                  entry.direction == 'send') ||
              (historyFilter == HistoryFilter.received &&
                  entry.direction == 'receive'),
        )
        .take(30)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _sectionHeadline('本地传输历史', '${history.length} 条')),
            if (history.isNotEmpty)
              TextButton(onPressed: _clearHistory, child: const Text('清空')),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: const Text('全部'),
              selected: historyFilter == HistoryFilter.all,
              onSelected: (_) =>
                  setState(() => historyFilter = HistoryFilter.all),
            ),
            ChoiceChip(
              label: const Text('已发送'),
              selected: historyFilter == HistoryFilter.sent,
              onSelected: (_) =>
                  setState(() => historyFilter = HistoryFilter.sent),
            ),
            ChoiceChip(
              label: const Text('已接收'),
              selected: historyFilter == HistoryFilter.received,
              onSelected: (_) =>
                  setState(() => historyFilter = HistoryFilter.received),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _glassCard(
          child: displayed.isEmpty
              ? const Text(
                  '暂无对应历史。只有本版本启动后的真实传输会写入记录。',
                  style: TextStyle(height: 1.5),
                )
              : Column(children: displayed.map(_historyCard).toList()),
        ),
        const SizedBox(height: 8),
        const Text(
          '仅在本机保存最近 200 条记录；旧版文件不会自动补写发送历史。',
          style: TextStyle(color: Color(0xFFA9C0C3), fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _desktopTransferPage() {
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          '传输记录',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        const Text(
          '发送、接收结果保存在本机；当前会话中会直接显示实时进度气泡。',
          style: TextStyle(color: Color(0xFFA9C0C3)),
        ),
        const SizedBox(height: 18),
        _glassCard(
          child: sending
              ? Row(
                  children: const [
                    CircularProgressIndicator(strokeWidth: 2),
                    SizedBox(width: 12),
                    Expanded(child: Text('正在发送文件，请等待完成。')),
                  ],
                )
              : const Text('当前没有正在进行的传输任务。'),
        ),
        const SizedBox(height: 18),
        _historySection(),
        const SizedBox(height: 18),
        _sectionHeadline('运行日志', '最近 ${service.logs.length} 条'),
        const SizedBox(height: 8),
        _glassCard(
          child: SelectableText(
            service.logs.isEmpty ? '暂无日志' : service.logs.join('\n'),
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.7,
              color: Color(0xFFDDEAE9),
            ),
          ),
        ),
      ],
    );
  }

  Widget _desktopFilesPage() {
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '接收文件',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
              ),
            ),
            _glassButton(
              icon: Icons.folder_open_rounded,
              label: '打开接收目录',
              onTap: _openReceivedFolder,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _glassCard(
          child: received.isEmpty
              ? const Text('暂无接收记录。')
              : Column(
                  children: received
                      .take(20)
                      .map((file) => _fileTile(file, desktop: true))
                      .toList(),
                ),
        ),
      ],
    );
  }

  Widget _desktopSettingsPage() {
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          '设置',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 18),
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoLine('版本', '邻跃 LINYUE v0.5.65 DEV13D2E38'),
              const SizedBox(height: 10),
              _infoLine('设备名称', service.deviceName),
              const SizedBox(height: 10),
              _infoLine(
                '局域网发现',
                service.running
                    ? (receiveGuard.receivingEnabled ? '运行中' : '运行中 · 文件接收已暂停')
                    : '未运行',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _windowsReceiveDirectorySettings(),
        const SizedBox(height: 16),
        _receiveGuardSettings(),
        const SizedBox(height: 16),
        const ExpansionTile(
          title: Text('开发者诊断 · 旧身份认证实验（可选）'),
          subtitle: Text(
            '日常传文件不需要填写公钥或指纹',
            style: TextStyle(color: Color(0xFFA9C0C3), fontSize: 12),
          ),
          children: [DeviceIdentityPanel()],
        ),
        const SizedBox(height: 16),
        const ExpansionTile(
          title: Text('连接技术信息'),
          children: [
            ListTile(
              title: Text('局域网端口'),
              subtitle: Text('TCP 46729 / UDP 46728'),
            ),
          ],
        ),
      ],
    );
  }

  // Single-screen mobile conversation: selection stays in the header,
  // and the message list plus send composer are always visible on the home.
  Widget _buildMobileNearbyPage() {
    final peer = _activePeer;
    final peers = service.peers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _mobileRecipientBar(peer, peers),
        const SizedBox(height: 8),
        Expanded(child: _mobileChatTimeline(peer)),
        const SizedBox(height: 8),
        _mobileComposer(peer),
      ],
    );
  }

  // B2: presentation-only entry. LAN selection and business handlers remain unchanged.
  Widget _connectionControls() {
    final peer = _activePeer;
    final fp = peer == null ? null : _verifiedFingerprints[_peerKey(peer)];
    final verified =
        fp != null && _pairIdentity.entries.any((e) => e.fingerprint == fp);
    return ValueListenableBuilder<bool>(
      valueListenable: _textTrialBusy,
      builder: (context, _, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeviceConnectionBar(
            controller: _bluetoothConnection,
            lanLabel: peer?.name ?? '未选择设备',
            lanStatus: peer == null
                ? '未连接'
                : peer.isStale
                ? '连接中断'
                : verified
                ? '已验证身份 · 发送时复核'
                : '待身份验证',
            bluetoothSelected: _useBluetoothText,
            onRouteChanged: _selectWorkbenchRoute,
            routeLocked: _workbenchRouteLocked,
            onConnect: _showConnectionMethods,
          ),
          if (!_useBluetoothText &&
              peer != null &&
              (!verified || _pairingBusy || _pairingError != null))
            Align(
              alignment: Alignment.centerRight,
              child: _pairControl(peer, mobile: Platform.isAndroid),
            ),
        ],
      ),
    );
  }

  Future<void> _showConnectionMethods() async {
    if (_bluetoothReceiveRootChanging) {
      _toast('接收文件夹正在更新，请稍后连接');
      return;
    }
    if (_connectionSheetOpen || _workbenchRouteLocked) return;
    _connectionSheetOpen = true;
    String? result;
    try {
      if (!_useBluetoothText) {
        await _showDeviceManager();
        return;
      }
      result = await showDialog<String>(
        context: context,
        builder: (_) => DeviceConnectionSheet(
          controller: _bluetoothConnection,
          initialBluetooth: true,
          onBluetoothSelected: () {
            if (mounted && !_useBluetoothText)
              setState(() => _useBluetoothText = true);
          },
        ),
      );
    } finally {
      _connectionSheetOpen = false;
      if (_useBluetoothText) _bluetoothConnection?.leaveSheet();
    }
    if (mounted && result == 'lan') {
      setState(() => _useBluetoothText = false);
      await _showDeviceManager();
    }
  }

  Widget _mobileRecipientBar(NearPeer? peer, List<NearPeer> peers) =>
      _glassCard(
        radius: 20,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: _connectionControls(),
      );

  // The legacy receiving protocol does not bind files to authenticated
  // sender identities. Received records therefore remain explicitly labeled
  // as unverified, rather than being falsely attributed to the selected peer.
  Widget _mobileChatTimeline(NearPeer? peer) {
    final visible = recentConversationEntries(history, peerName: peer?.name);
    final live = _conversationLiveProgressEntries();
    return _glassCard(
      focus: true,
      deepenBlankBackground: true,
      radius: 23,
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
      child: _mixedConversationItems(
        peer: peer,
        mobile: true,
        files: visible,
        live: live,
      ),
    );
  }

  Widget _mobileComposer(NearPeer? peer) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: const Color(0x33183543),
            borderRadius: BorderRadius.circular(21),
            border: Border.all(color: const Color(0x8857CFC8), width: 1.3),
          ),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: _unifiedTextComposer(peer, mobile: true),
        ),
        const SizedBox(height: 6),
        if (_sendQueue.pendingCount > 0)
          Text(
            '队列还有 ${_sendQueue.pendingCount} 项',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFA9C0C3), fontSize: 10.5),
          ),
      ],
    );
  }

  Widget _buildMobileTransferPage() {
    return ListView(
      children: [
        _queueStatusPanel(),
        const SizedBox(height: 12),
        _sectionHeadline('传输记录', sending ? '进行中' : '当前无任务'),
        const SizedBox(height: 8),
        _glassCard(
          child: sending
              ? Row(
                  children: const [
                    CircularProgressIndicator(strokeWidth: 2),
                    SizedBox(width: 12),
                    Expanded(child: Text('正在处理发送任务，请等待完成。')),
                  ],
                )
              : const Text('当前没有正在进行的传输任务。'),
        ),
        const SizedBox(height: 16),
        _historySection(),
        const SizedBox(height: 18),
        _sectionHeadline('已接收文件', '${received.length} 个'),
        const SizedBox(height: 8),
        _batchReceivedToolbar(received.take(30).toList()),
        _glassCard(
          child: received.isEmpty
              ? const Text('暂无接收记录')
              : Column(
                  children: received
                      .take(30)
                      .map((file) => _fileTile(file))
                      .toList(),
                ),
        ),
        const SizedBox(height: 16),
        _sectionHeadline('运行日志', '最近 ${service.logs.length} 条'),
        const SizedBox(height: 8),
        _glassCard(
          child: SelectableText(
            service.logs.isEmpty ? '暂无日志' : service.logs.join('\n'),
            style: const TextStyle(fontSize: 12.5, height: 1.65),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileSettingsPage() {
    return ListView(
      children: [
        _glassCard(
          child: Row(
            children: [
              const GlassLogo(size: 54),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    '邻跃',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'LINYUE',
                    style: TextStyle(
                      letterSpacing: 1.6,
                      color: Color(0xFFA9C0C3),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoLine('版本', 'v0.5.65 DEV13D2E38'),
              const SizedBox(height: 10),
              _infoLine('设备名称', service.deviceName),
              const SizedBox(height: 10),
              _infoLine(
                '局域网发现',
                service.running
                    ? (receiveGuard.receivingEnabled ? '运行中' : '运行中 · 文件接收已暂停')
                    : '未运行',
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () => _copyText(service.deviceName, hint: '设备名称已复制'),
                icon: const Icon(Icons.content_copy_rounded, size: 16),
                label: const Text('复制设备名称'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _receiveGuardSettings(),
        const SizedBox(height: 14),
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '存储空间',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '查看接收文件及应用私有副本占用；'
                '只允许手动清理无引用的旧缩略图，绝不清理系统相册。',
                style: TextStyle(color: Color(0xFFA9C0C3), fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              _glassButton(
                icon: Icons.storage_rounded,
                label: _storageOverviewBusy ? '扫描中…' : '存储占用与安全清理',
                onTap: _showLocalStorageOverview,
              ),
              const SizedBox(height: 10),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('高级：媒体副本预检', style: TextStyle(fontSize: 12)),
                children: [
                  _glassButton(
                    icon: Icons.manage_search_rounded,
                    label: _mediaCopyAuditBusy ? '预检中…' : '查看副本明细（只读）',
                    onTap: _showMediaCopyAudit,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const ExpansionTile(
          title: Text('开发者诊断 · 旧身份认证实验（可选）'),
          subtitle: Text(
            '日常传文件不需要填写公钥或指纹',
            style: TextStyle(color: Color(0xFFA9C0C3), fontSize: 12),
          ),
          children: [DeviceIdentityPanel()],
        ),
        const SizedBox(height: 14),
        const ExpansionTile(
          title: Text('连接技术信息'),
          children: [
            ListTile(
              title: Text('局域网端口'),
              subtitle: Text('TCP 46729 / UDP 46728'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _peerCard(NearPeer peer, {bool compact = false}) {
    final isWin = peer.name.toLowerCase().contains('windows');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _choosePeer(peer),
        child: _glassCard(
          radius: 24,
          child: Row(
            children: [
              GlassBadge(
                icon: isWin
                    ? Icons.desktop_windows_rounded
                    : Icons.smartphone_rounded,
                size: compact ? 56 : 60,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${peer.ip}:${peer.port}',
                      style: const TextStyle(color: Color(0xFFA9C0C3)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(
                      Icons.arrow_forward_rounded,
                      size: 28,
                      color: Color(0xFF87F2EA),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _manualConnectSection({required bool compact}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeadline('手动连接', '自动发现失败时使用'),
        const SizedBox(height: 8),
        _glassCard(child: _manualConnectInput(compact: compact)),
      ],
    );
  }

  // DEV13D2E7 FIX1: shared help for the existing Windows/Android manual-IP UI.
  // This is a local dialog only; discovery, pairing, and encryption are unchanged.
  void _showManualIpHelp() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.help_outline_rounded, size: 23),
            SizedBox(width: 9),
            Expanded(child: Text('手动 IP 连接说明')),
          ],
        ),
        content: const SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: SelectableText(
              '第一步｜确认同一局域网\n'
              '电脑和手机应连接同一台路由器下允许相互通信的网络。'
              '电脑用网线、手机用 Wi-Fi 也可以。请关闭可能干扰局域网通信的 VPN，'
              '避免访客 Wi-Fi 或设备隔离网络。\n\n'
              '第二步｜查看 Windows 电脑 IP\n'
              '按 Win + R → 输入 cmd → 运行 ipconfig。'
              '在当前使用的“无线局域网适配器 WLAN”或“以太网适配器”中，'
              '找到“IPv4 地址”，例如 192.168.1.25。'
              '不要选虚拟网卡、VPN、127.0.0.1 或公网 IP。\n\n'
              '第三步｜查看手机 IP\n'
              '手机进入“设置 → WLAN → 当前已连接的 Wi-Fi → 网络详情”，'
              '查看 IPv4 地址（不同系统名称可能略有差异），'
              '例如 192.168.1.36。\n\n'
              '第四步｜输入对方的 IP\n'
              '在电脑邻跃的手动连接处填入手机 IP；'
              '或者在手机邻跃的手动连接处填入电脑 IP。'
              '只输入四段数字地址，不要加 http:// 或端口。'
              '点击“添加”后会生成手动设备条目，'
              '这一步并不代表已完成连接。\n\n'
              '第五步｜完成安全配对\n'
              '选中手动添加的设备，点击“首次配对”，'
              '按两端提示确认安全身份，再测试发送文件。'
              'IP 仅用于定位设备，不会跳过加密或身份验证。\n\n'
              '仍无法连接？\n'
              '确认邻跃双端都在运行；Windows 防火墙允许邻跃在私人网络通信；'
              '路由器未启用 AP/客户端隔离。'
              '可在 Windows PowerShell 测试：\n'
              'Test-NetConnection 192.168.1.36 -Port 46729\n'
              '（将示例 IP 改成手机真实 IP）。'
              'TcpTestSucceeded 为 True 仅表示该端口可访问，不等于已配对。'
              '邻跃还使用 UDP 46728 自动发现、TCP 46731 配对和 TCP 46732 加密传输。',
              style: TextStyle(fontSize: 13.5, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  Widget _manualConnectInput({required bool compact}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: ipController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  isDense: compact,
                  labelText: '输入对方 IPv4 地址',
                  hintText: compact ? null : '例如 192.168.1.25',
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                ),
                onSubmitted: (_) => _addIp(),
              ),
            ),
            const SizedBox(width: 12),
            _glassButton(label: '添加', onTap: _addIp),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _showManualIpHelp,
            icon: const Icon(Icons.help_outline_rounded, size: 16),
            label: const Text('连接说明 · 如何查看双方 IP'),
          ),
        ),
      ],
    );
  }

  Widget _recentReceiveSection({required bool showOpenAll}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _sectionHeadline('最近接收', '${received.length} 个')),
            if (Platform.isAndroid && !_batchSelectionMode)
              _batchReceivedToolbar(received.take(8).toList()),
            if (showOpenAll)
              TextButton(
                onPressed: _openReceivedFolder,
                child: const Text('查看全部 →'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (Platform.isAndroid && _batchSelectionMode)
          _batchReceivedToolbar(received.take(8).toList()),
        _glassCard(
          child: received.isEmpty
              ? const Text('暂无接收记录。开发版文件保存在应用专属目录 NearLinkReceived。')
              : Column(
                  children: received
                      .take(8)
                      .map((file) => _fileTile(file))
                      .toList(),
                ),
        ),
      ],
    );
  }

  Widget _warningFooter() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: const Color(0x20F2B84B),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0x55F2B84B)),
    ),
    child: const Text(
      'DEV12-D2 加密传输试运行版：请仅在可信局域网测试。单文件不超过 1 GiB。',
      style: TextStyle(color: Color(0xFFF6D08A), fontSize: 12.5, height: 1.6),
    ),
  );

  Widget _fileTile(File file, {bool desktop = false}) {
    final selecting = Platform.isAndroid && _batchSelectionMode;
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: FileVisualBadge(
            fileName: file.uri.pathSegments.last,
            localPath: file.path,
            size: 44,
          ),
          title: Text(
            file.uri.pathSegments.last,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            desktop ? file.path : '接收成功 · 点击可另存或查看',
            maxLines: desktop ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFA9C0C3), height: 1.5),
          ),
          trailing: selecting
              ? Checkbox(
                  value: _batchSelectedReceivedPaths.contains(file.path),
                  onChanged: _batchSaveBusy
                      ? null
                      : (_) => _toggleBatchReceivedSelection(file),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _quickSavedReceivedPaths.contains(file.path)
                          ? '已保存'
                          : '一键保存到本机',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        _quickSavedReceivedPaths.contains(file.path)
                            ? Icons.download_done_rounded
                            : Icons.download_rounded,
                        size: 19,
                      ),
                      onPressed: _quickSavingReceivedPaths.contains(file.path)
                          ? null
                          : () => _quickSaveReceived(file),
                    ),
                    if (Platform.isAndroid)
                      IconButton(
                        tooltip: SmartFileOpenPolicy.actionLabel(
                          file.uri.pathSegments.last,
                          isAndroid: true,
                        ),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.open_in_new_rounded, size: 19),
                        onPressed: () => _openReceivedWithDefaultApp(file),
                      ),
                    if (Platform.isAndroid)
                      IconButton(
                        tooltip: '直接分享文件',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.share_outlined, size: 19),
                        onPressed: () => _shareReceivedFileWithSystem(file),
                      ),
                    IconButton(
                      tooltip: '文件操作',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.more_horiz_rounded),
                      onPressed: () => _showReceivedActions(file),
                    ),
                  ],
                ),
          onTap: selecting
              ? () => _toggleBatchReceivedSelection(file)
              : () => _openReceivedFileFromList(file),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _simpleFileRow(File file) {
    final originalName = file.uri.pathSegments.last;
    return InkWell(
      onTap: () => _openReceivedFileFromList(file),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            FileVisualBadge(
              fileName: originalName,
              localPath: file.path,
              size: 31,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Tooltip(
                message: originalName,
                child: Text(
                  compactRecentFileName(originalName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.2,
                    height: 1.15,
                    color: Color(0xFFD1E3E1),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 3),
            const Icon(
              Icons.more_horiz_rounded,
              size: 17,
              color: Color(0xFFA9C0C3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glassButton({
    IconData? icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE0FFFC), Color(0xFF7BE1D9), Color(0xFF51BCBC)],
          ),
          border: Border.all(color: const Color(0xCCD9FFFF), width: 1.2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x553DD8D0),
              blurRadius: 18,
              spreadRadius: -6,
              offset: Offset(0, 8),
            ),
            BoxShadow(
              color: Color(0x55FFFFFF),
              blurRadius: 2,
              spreadRadius: -1,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: const Color(0xFF0B1D26)),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF0B1D26),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _brandTitle({bool compact = false}) {
    return Row(
      children: [
        GlassLogo(size: compact ? 40 : 46),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '邻跃',
              style: TextStyle(
                fontSize: compact ? 24 : 28,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'LINYUE',
              style: TextStyle(
                fontSize: compact ? 12 : 13,
                letterSpacing: 2,
                color: const Color(0xFFA9C0C3),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sectionHeadline(String title, String? trailing) => Row(
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      const Spacer(),
      if (trailing != null)
        Text(
          trailing,
          style: const TextStyle(fontSize: 12, color: Color(0xFFA9C0C3)),
        ),
    ],
  );

  /// FIX2: translucent two-layer edge with a narrow specular highlight.
  /// All layers are pointer-transparent: original file/menu gestures stay intact.
  Widget _glassCard({
    required Widget child,
    double radius = 22,
    bool focus = false,
    bool deepenBlankBackground = false,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0.0, 0.30, 1.0],
          colors: focus
              ? const [Color(0x66365E66), Color(0x3A2B5059), Color(0x211A353E)]
              : const [Color(0x44355562), Color(0x2424414E), Color(0x1213212C)],
        ),
        border: Border.all(
          color: focus ? const Color(0xD5B8F2EE) : const Color(0xA7B8F2EE),
          width: focus ? 1.9 : 1.7,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2C5EF0E8),
            blurRadius: 16,
            spreadRadius: -8,
            offset: Offset(0, 6),
          ),
          BoxShadow(
            color: Color(0x72000409),
            blurRadius: 30,
            spreadRadius: -8,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius - 1.4),
          border: Border.all(color: const Color(0x24F5FFFF), width: 0.7),
          gradient: deepenBlankBackground
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  stops: [0.0, 0.34, 1.0],
                  colors: [
                    Color(0xFF0A1A22),
                    Color(0xFF08161E),
                    Color(0xFF06131A),
                  ],
                )
              : null,
          color: deepenBlankBackground ? const Color(0xFF08161D) : null,
        ),
        padding: padding,
        child: Stack(
          children: [
            Positioned(
              left: 1,
              right: 1,
              top: 0,
              child: IgnorePointer(
                child: Container(
                  height: 12,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(radius - 2),
                    ),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x24EAF7F4), Color(0x00FFFFFF)],
                    ),
                  ),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }

  Widget _infoLine(String label, String value) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 72,
        child: Text(label, style: const TextStyle(color: Color(0xFFA9C0C3))),
      ),
      Expanded(child: Text(value, style: const TextStyle(height: 1.5))),
    ],
  );
}

class GlassBadge extends StatelessWidget {
  const GlassBadge({super.key, required this.icon, this.size = 56});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xE66FD3D0), Color(0x99469CA5), Color(0x6E18525F)],
        ),
        border: Border.all(color: const Color(0xC6D4FFFF), width: 1.15),
        boxShadow: const [
          BoxShadow(
            color: Color(0x7D41DED6),
            blurRadius: 15,
            spreadRadius: -5,
            offset: Offset(0, 7),
          ),
          BoxShadow(
            color: Color(0x22FFFFFF),
            blurRadius: 1,
            offset: Offset(-1, -1),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            left: 5,
            right: 5,
            top: 3,
            child: IgnorePointer(
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size),
                  gradient: const LinearGradient(
                    colors: [Color(0xAAFFFFFF), Color(0x06FFFFFF)],
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Icon(
              icon,
              color: const Color(0xFFEAF6F4),
              size: size * 0.44,
            ),
          ),
        ],
      ),
    );
  }
}

/// The exact two-arc geometry follows approved icon A (1024 design space).
class GlassLogo extends StatelessWidget {
  const GlassLogo({super.key, this.size = 52});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.27),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xEA27717C), Color(0xE1114651), Color(0xEB081F2B)],
        ),
        border: Border.all(color: const Color(0xC4D3FFFF), width: 1.15),
        boxShadow: const [
          BoxShadow(
            color: Color(0x8347DDD4),
            blurRadius: 14,
            spreadRadius: -3,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.25),
        child: CustomPaint(
          painter: const _LinyueMarkPainter(),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _LinyueMarkPainter extends CustomPainter {
  const _LinyueMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.scale(size.width / 1024, size.height / 1024);
    final bounds = const Rect.fromLTWH(0, 0, 1024, 1024);

    // Thin refracted light on the top bevel.
    canvas.drawPath(
      Path()
        ..moveTo(190, 92)
        ..quadraticBezierTo(510, 4, 834, 92),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 22
        ..shader = const LinearGradient(
          colors: [Color(0x03FFFFFF), Color(0x9BFFFFFF), Color(0x03FFFFFF)],
        ).createShader(bounds),
    );

    final leftArc = Path()
      ..moveTo(222, 608)
      ..cubicTo(303, 345, 414, 323, 505, 488);
    final rightArc = Path()
      ..moveTo(800, 416)
      ..cubicTo(717, 678, 606, 699, 519, 536);

    final halo = Paint()
      ..color = const Color(0x885DE9DF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 82
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20);
    canvas.drawPath(leftArc, halo);
    canvas.drawPath(rightArc, halo);

    final ribbon = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFC9FFF7), Color(0xFF7CDDD5), Color(0xFF3ABDB8)],
      ).createShader(bounds)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 70
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(leftArc, ribbon);
    canvas.drawPath(rightArc, ribbon);

    final sheen = Paint()
      ..color = const Color(0x78FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(leftArc.shift(const Offset(0, -12)), sheen);
    canvas.drawPath(rightArc.shift(const Offset(0, -12)), sheen);

    canvas.drawCircle(
      const Offset(222, 608),
      39,
      Paint()..color = const Color(0xFFB3FFF0),
    );
    canvas.drawCircle(
      const Offset(800, 416),
      39,
      Paint()..color = const Color(0xFF55CAC4),
    );
    canvas.drawCircle(
      const Offset(512, 512),
      47,
      Paint()..color = const Color(0xFFE0FFF7),
    );
    canvas.drawCircle(
      const Offset(512, 512),
      24,
      Paint()..color = const Color(0xFF0F424A),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LinyueMarkPainter oldDelegate) => false;
}

/// Dark ink-blue background with understated circuit traces and flowing light paths.
/// No animation, textures, network calls or plugins; cheap to render on both devices.
class TechBackdrop extends StatelessWidget {
  const TechBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _TechBackdropPainter()),
          ),
        ),
        child,
      ],
    );
  }
}

class _TechBackdropPainter extends CustomPainter {
  const _TechBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF06121B), Color(0xFF09212C), Color(0xFF06151E)],
          stops: [0.0, 0.55, 1.0],
        ).createShader(bounds),
    );

    void bloom(Offset center, double radius, Color core) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [core, const Color(0x0006A9A8)],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    bloom(Offset(w * 0.79, h * 0.73), w * 0.68, const Color(0x1730AEBB));
    bloom(Offset(w * 0.17, h * 0.87), w * 0.59, const Color(0x0D32B7B5));
    bloom(Offset(w * 0.65, h * 0.10), w * 0.35, const Color(0x0B16BDBB));

    // Fine scientific grid, deliberately low contrast behind readable text.
    final grid = Paint()
      ..color = const Color(0x078AC7C6)
      ..strokeWidth = 0.65;
    for (double x = 0; x < w; x += 47) {
      canvas.drawLine(Offset(x, 0), Offset(x, h), grid);
    }
    for (double y = 0; y < h; y += 47) {
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }

    // Curving paths: thicker at outer boundaries, restrained behind cards.
    final mobile = w < 720;
    for (var i = 0; i < 12; i++) {
      final t = i / 11.0;
      final offsetY = t * (mobile ? h * 0.16 : h * 0.12);
      final path = Path()
        ..moveTo(-w * 0.13, h * (mobile ? 0.76 : 0.92) + offsetY)
        ..cubicTo(
          w * 0.25,
          h * (mobile ? 0.42 : 0.50) + offsetY,
          w * 0.51,
          h * (mobile ? 1.07 : 0.86) - offsetY * 0.4,
          w * 1.15,
          h * (mobile ? 0.60 : 0.45) + offsetY * 0.25,
        );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = i % 5 == 0 ? 1.2 : 0.55
          ..color = Color.fromARGB(i % 5 == 0 ? 33 : 16, 116, 215, 210),
      );
    }

    // Dense data particles gently fade toward one corner.
    final dots = Paint()..color = const Color(0x2C71D1CB);
    for (var row = 0; row < 13; row++) {
      for (var col = 0; col < 27; col++) {
        final xx = w * (mobile ? 0.10 : 0.62) + col * (mobile ? 8.4 : 12.6);
        final yy =
            h * (mobile ? 0.69 : 0.57) +
            row * 10 +
            10 * math.sin((col + row * 0.5) * 0.3);
        if (xx > w - 12 || yy > h - 10) continue;
        final brightness = (col + row) % 7 == 0 ? 0.75 : 0.34;
        dots.color = Color.fromARGB((brightness * 70).round(), 112, 203, 204);
        canvas.drawCircle(
          Offset(xx, yy),
          (col + row) % 7 == 0 ? 1.4 : 0.75,
          dots,
        );
      }
    }

    // Circuit traces with tiny node points.
    final trace = Paint()
      ..color = const Color(0x187DC7C4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (var i = 0; i < 6; i++) {
      final dx = i * 36.0;
      final p = Path()
        ..moveTo(w * 0.50 + dx, -20)
        ..lineTo(w * 0.50 + dx, h * 0.13 + i * 7)
        ..lineTo(w * 0.65 + dx, h * 0.26 + i * 7)
        ..lineTo(w * 1.05, h * 0.26 + i * 7);
      canvas.drawPath(p, trace);
      canvas.drawCircle(
        Offset(w * 0.65 + dx, h * 0.26 + i * 7),
        1.6,
        Paint()..color = const Color(0x347ACCC8),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TechBackdropPainter oldDelegate) => false;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
