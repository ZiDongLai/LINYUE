import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bluetooth_connection_controller.dart';
import 'bluetooth_debug_page.dart';
import 'bluetooth_peer_catalog.dart';

/// One home connection summary. The explicit route is the only displayed target.
class DeviceConnectionBar extends StatelessWidget {
  const DeviceConnectionBar({
    super.key,
    required this.controller,
    required this.onConnect,
    required this.lanLabel,
    this.debugEnabled = kDebugMode,
    this.bluetoothSelected = false,
    this.onRouteChanged,
    this.routeLocked = false,
    this.lanStatus = '未连接',
  });
  final BluetoothConnectionController? controller;
  final VoidCallback onConnect;
  final String lanLabel, lanStatus;
  final bool debugEnabled, bluetoothSelected, routeLocked;
  final ValueChanged<bool>? onRouteChanged;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller ?? const AlwaysStoppedAnimation(0),
    builder: (context, _) {
      final c = controller;
      final useBluetooth = debugEnabled && c != null && bluetoothSelected;
      final name = useBluetooth
          ? (c.authenticated ? c.peerLabel : '蓝牙设备')
          : lanLabel;
      final status = useBluetooth ? c.label : lanStatus;
      final capability = useBluetooth && c.authenticated
          ? (c.transport.textReady
                ? (c.transport.fileSendReady
                      ? '文字可用 · 可发送文件≤${c.transport.maxFileBytes ~/ (1024*1024)} MiB'
                      : '文字可用 · 文件发送未就绪')
                : '文字通道准备中')
          : '';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                useBluetooth ? Icons.bluetooth : Icons.lan_outlined,
                size: 20,
                color: const Color(0xFF74D9D2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      key: const Key('connection-current-device'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '$status${capability.isEmpty ? '' : ' · $capability'}',
                      key: Key(
                        useBluetooth
                            ? 'bluetooth-header-status'
                            : 'lan-header-status',
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFB4C9CA),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                key: const Key('connect-device'),
                onPressed: routeLocked ? null : onConnect,
                icon: const Icon(Icons.add_link_rounded, size: 18),
                label: Text(
                  useBluetooth &&
                          (c.phase == BluetoothConnectionPhase.failed ||
                              c.phase == BluetoothConnectionPhase.disconnected)
                      ? '重试连接'
                      : '连接设备',
                ),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ],
          ),
          if (debugEnabled && c != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<bool>(
                  key: const Key('connection-route'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('局域网')),
                    ButtonSegment(value: true, label: Text('蓝牙 · 测试版')),
                  ],
                  selected: {useBluetooth},
                  onSelectionChanged: routeLocked || onRouteChanged == null
                      ? null
                      : (values) => onRouteChanged!(values.single),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// One small connection-method sheet. Closing it leaves an active B1 session
/// alive in the home; explicit cancel/stop releases it. No standalone page.
class DeviceConnectionSheet extends StatefulWidget {
  const DeviceConnectionSheet({
    super.key,
    required this.controller,
    this.debugEnabled = kDebugMode,
    this.initialBluetooth = false,
    this.onBluetoothSelected,
  });
  final BluetoothConnectionController? controller;
  final bool debugEnabled, initialBluetooth;
  final VoidCallback? onBluetoothSelected;
  @override
  State<DeviceConnectionSheet> createState() => _DeviceConnectionSheetState();
}

class _DeviceConnectionSheetState extends State<DeviceConnectionSheet>
    with WidgetsBindingObserver {
  bool bluetooth = false;
  final _identityCode = TextEditingController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialBluetooth &&
        widget.debugEnabled &&
        widget.controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _bluetooth();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _identityCode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = widget.controller;
    if (state == AppLifecycleState.resumed &&
        bluetooth &&
        c != null &&
        !c.active &&
        !c.busy) {
      unawaited(c.prepare());
    }
  }

  void _bluetooth() {
    setState(() => bluetooth = true);
    widget.onBluetoothSelected?.call();
    final c = widget.controller!;
    if (!c.active) unawaited(c.prepare(askPermission: true, resumeKnown: true));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Dialog(
      backgroundColor: const Color(0xFF102732),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (bluetooth)
                    IconButton(
                      key: const Key('bluetooth-back'),
                      tooltip: '返回上一级',
                      onPressed: () async {
                        if (c != null &&
                            (c.selectedDeviceId != null ||
                                c.phase ==
                                    BluetoothConnectionPhase.chooseIdentity ||
                                c.phase == BluetoothConnectionPhase.failed)) {
                          _identityCode.clear();
                          await c.backToDevices();
                        } else {
                          c?.leaveSheet();
                          if (mounted && widget.initialBluetooth) {
                            Navigator.pop(context);
                          } else if (mounted) {
                            setState(() => bluetooth = false);
                          }
                        }
                      },
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  Expanded(
                    child: Text(
                      bluetooth ? '蓝牙连接 · 测试版' : '连接设备',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('return-chat'),
                    tooltip: '返回聊天',
                    onPressed: () {
                      c?.leaveSheet();
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: !bluetooth
                      ? Column(
                          children: [
                            ListTile(
                              key: const Key('lan-connection-option'),
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.lan_outlined),
                              title: const Text('局域网连接'),
                              subtitle: const Text('选择附近设备或使用已有连接管理'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => Navigator.pop(context, 'lan'),
                            ),
                            if (widget.debugEnabled && c != null)
                              ListTile(
                                key: const Key('bluetooth-connection-option'),
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.bluetooth),
                                title: Text(
                                  c.android ? '蓝牙 · 等待电脑连接' : '蓝牙连接 · 测试版',
                                ),
                                subtitle: Text(
                                  c.transport.textEnabled
                                      ? '连接后可在首页发送文字；文件以双方能力为准'
                                      : '连接与身份验证测试',
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: _bluetooth,
                              ),
                          ],
                        )
                      : ListenableBuilder(
                          listenable: c!,
                          builder: (context, _) => _content(c),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BluetoothConnectionController c) {
    final blocked =
        !c.active &&
        !c.busy &&
        c.phase != BluetoothConnectionPhase.chooseDevice &&
        c.phase != BluetoothConnectionPhase.chooseIdentity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              c.authenticated ? Icons.verified_user_outlined : Icons.bluetooth,
              color: const Color(0xFF74D9D2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                c.label,
                key: const Key('bluetooth-sheet-status'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          _hint(c),
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFFB4C9CA),
            height: 1.5,
          ),
        ),
        if (c.transport.textEnabled && c.transport.confirmationRequired) ...[
          const SizedBox(height: 12),
          const Text('首次关联：请直接比较电脑与手机屏幕上的全部核对码。两端一致才分别确认；无需复制或用其他软件发送。'),
          SelectableText(
            c.transport.comparisonCode,
            key: const Key('bluetooth-sas'),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('bluetooth-sas-accept'),
                onPressed: () =>
                    unawaited(c.transport.confirmAssociation(true)),
                child: const Text('两端核对码一致'),
              ),
              TextButton(
                key: const Key('bluetooth-sas-reject'),
                onPressed: () =>
                    unawaited(c.transport.confirmAssociation(false)),
                child: const Text('不一致，拒绝关联'),
              ),
            ],
          ),
        ],
        if (c.transport.textEnabled && c.active)
          Text(
            c.transport.textReady
                ? '文字已可用，返回首页即可发送；文件能力单独确认'
                : c.transport.authState.contains(
                    'waiting-for-peer-confirmation',
                  )
                ? '本机已确认，等待对端确认；文字尚不可用'
                : '连接与文字通道分别准备，当前文字尚不可用',
            style: const TextStyle(fontSize: 12),
          ),
        if (c.busy || c.active && !c.authenticated)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        if (c.errorHint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              c.errorHint,
              style: const TextStyle(color: Color(0xFFFFB39E), fontSize: 12),
            ),
          ),
        if (c.radioDetail.startsWith('unknown') && !c.android)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '系统暂未提供蓝牙开关状态，请先在系统设置中确认蓝牙已开启。',
              style: TextStyle(color: Color(0xFFF3C47D), fontSize: 12),
            ),
          ),
        if (c.localBluetoothName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '本机蓝牙名称：${c.localBluetoothName}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        if (c.incompleteDevices > 0)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '部分系统记录缺少可靠地址，未把它们作为新设备列出。请在系统蓝牙设置中核对。',
              style: TextStyle(fontSize: 12, color: Color(0xFFF3C47D)),
            ),
          ),
        if (c.associationHint.isNotEmpty)
          Text(c.associationHint, style: const TextStyle(fontSize: 11)),
        if (!c.active &&
                !c.busy &&
                c.phase != BluetoothConnectionPhase.chooseIdentity ||
            c.phase == BluetoothConnectionPhase.waiting) ...[
          const SizedBox(height: 8),
          Text(
            c.android
                ? '找不到手机？先在两端系统蓝牙设置中配对，再返回邻跃。等待连接不会让手机自动进入系统可发现状态。'
                : '这里只显示已配对设备。找不到手机？先在 Windows 蓝牙设置中配对，再返回刷新。',
            style: const TextStyle(fontSize: 12),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                key: const Key('bluetooth-settings'),
                onPressed: () => unawaited(c.openBluetoothSettings()),
                icon: const Icon(Icons.settings_bluetooth),
                label: Text(c.android ? '打开手机蓝牙设置' : '打开 Windows 蓝牙设置'),
              ),
              if (!c.active)
                TextButton.icon(
                  key: const Key('bluetooth-refresh'),
                  onPressed: () {
                    _identityCode.clear();
                    unawaited(c.prepare());
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新设备列表'),
                ),
            ],
          ),
        ],
        if (c.excludedPeripherals > 0)
          const Text(
            '已排除系统标识的键盘、鼠标等外设；它们不是待连接的手机。',
            style: TextStyle(fontSize: 12),
          ),
        if (c.phase == BluetoothConnectionPhase.chooseIdentity) ...[
          const SizedBox(height: 12),
          Text(
            '正在核对：${c.selectedName}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const Text(
            '首次关联：查看对端本页的“核对本机身份”，输入六组核对码。不会按同名猜测或新增信任。',
            style: TextStyle(fontSize: 12),
          ),
          TextField(
            key: const Key('bluetooth-identity-code'),
            controller: _identityCode,
            decoration: const InputDecoration(
              labelText: '对端当前身份核对码',
              hintText: 'XXXX XXXX XXXX XXXX XXXX XXXX',
            ),
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
          ),
          FilledButton(
            key: const Key('confirm-bluetooth-identity'),
            onPressed: () => unawaited(c.confirmIdentity(_identityCode.text)),
            child: Text(c.android ? '核对并等待电脑连接' : '核对并连接'),
          ),
        ],
        if (c.phase == BluetoothConnectionPhase.chooseDevice) ...[
          Text(
            c.android ? '选择要等待的电脑' : '系统已配对设备',
            style: const TextStyle(fontSize: 12),
          ),
          for (final d in c.devices)
            ListTile(
              key: ValueKey('paired-${d.id}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                d.phone ? Icons.smartphone_outlined : Icons.devices_outlined,
              ),
              title: Text(
                d.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                d.phone
                    ? '已配对 · 点击连接'
                    : '已配对 · 类型未确认，连接前会检查邻跃服务',
                style: const TextStyle(fontSize: 11),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                _identityCode.clear();
                unawaited(c.connectDevice(d.id));
              },
            ),
          const Text(
            '同名设备请核对地址尾号；手机邻跃需保持等待连接。',
            style: TextStyle(fontSize: 11),
          ),
        ],
        if (c.active ||
            c.phase == BluetoothConnectionPhase.failed ||
            c.phase == BluetoothConnectionPhase.disconnected)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '目标：${c.selectedName}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        if (c.errorDetail.isNotEmpty)
          Text(
            '失败阶段：${c.failedStage}',
            style: const TextStyle(fontSize: 12, color: Color(0xFFFFB39E)),
          ),
        if (!c.transport.textEnabled)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('核对本机身份（首次关联用）', style: TextStyle(fontSize: 12)),
            children: [
              const Text(
                '让对端输入本机当前核对码，用于唯一选择已有邻跃登记；仍须签名认证。',
                style: TextStyle(fontSize: 11),
              ),
              SelectableText(
                bluetoothIdentityCode(c.localFingerprint),
                key: const Key('local-bluetooth-identity-code'),
              ),
              TextButton(
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text: bluetoothIdentityCode(c.localFingerprint),
                  ),
                ),
                child: const Text('复制核对码'),
              ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (!c.active &&
                !c.busy &&
                c.selectedDeviceId != null &&
                c.errorDetail.isNotEmpty &&
                c.failedStage == '身份认证')
              TextButton(
                key: const Key('review-bluetooth-identity'),
                onPressed: () => unawaited(c.reviewIdentity()),
                child: const Text('重新核对这台设备'),
              ),
            if (!c.authenticated &&
                c.selectedDeviceId != null &&
                c.phase != BluetoothConnectionPhase.stopping)
              TextButton(
                key: const Key('bluetooth-back-to-devices'),
                onPressed: () async {
                  _identityCode.clear();
                  await c.backToDevices();
                },
                child: const Text('返回设备列表'),
              ),
            if (blocked &&
                c.phase == BluetoothConnectionPhase.permissionRequired)
              FilledButton(
                key: const Key('bluetooth-retry'),
                onPressed: () => unawaited(
                  c.prepare(
                    askPermission:
                        c.phase == BluetoothConnectionPhase.permissionRequired,
                  ),
                ),
                child: Text(
                  c.phase == BluetoothConnectionPhase.permissionRequired
                      ? '授权并继续'
                      : '准备好后重试',
                ),
              ),
            if (c.active || c.busy)
              TextButton(
                key: const Key('bluetooth-cancel'),
                onPressed: c.phase == BluetoothConnectionPhase.stopping
                    ? null
                    : () => unawaited(c.stop()),
                child: Text(
                  c.authenticated
                      ? '断开蓝牙'
                      : c.phase == BluetoothConnectionPhase.waiting
                      ? '停止等待'
                      : '取消连接',
                ),
              ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('测试与诊断', style: TextStyle(fontSize: 12)),
          children: [
            BluetoothDiagnostics(
              transport: c.transport,
              errorDetail: c.errorDetail,
            ),
          ],
        ),
      ],
    );
  }

  String _hint(BluetoothConnectionController c) => switch (c.phase) {
    BluetoothConnectionPhase.permissionRequired ||
    BluetoothConnectionPhase.permissionPending =>
      '请允许“附近设备”的蓝牙连接权限；若已拒绝，可在系统应用权限中允许后重试。',
    BluetoothConnectionPhase.radioOff ||
    BluetoothConnectionPhase.unavailable => '请在系统设置中开启蓝牙，再返回这里重试；不会为你改变系统网络设置。',
    BluetoothConnectionPhase.pairingRequired =>
      c.android
          ? '请先在手机与电脑的系统蓝牙设置中完成配对，再回到这里重试。'
          : '当前没有可尝试的已配对手机。请先在 Windows 蓝牙设置中与手机配对，再刷新。',
    BluetoothConnectionPhase.identityRequired =>
      '系统蓝牙配对不等于邻跃身份认证。请先使用已有身份管理完成可信登记，再重试。',
    BluetoothConnectionPhase.chooseIdentity =>
      '系统设备已选定，但无法安全确定对应哪一条已有邻跃身份。请核对对端当前屏幕，不需要从历史同名列表猜测。',
    BluetoothConnectionPhase.chooseDevice =>
      c.android
          ? '请选择要等待的电脑。首次无法关联时需核对电脑当前身份码。'
          : '请先让手机显示“等待电脑连接”，再选择名称与地址尾号对应的手机。',
    BluetoothConnectionPhase.waiting =>
      '手机已准备好。请在电脑的“连接设备 → 蓝牙连接”中选择这台手机。可以返回聊天继续查看状态。',
    BluetoothConnectionPhase.authenticating =>
      c.transport.textEnabled
          ? (c.transport.confirmationRequired
                ? '临时蓝牙链路已建立，尚未建立可信会话。请在两端直接比较核对码并分别确认。'
                : '正在核验对端签名或等待双方确认；认证及文字能力均就绪后才可发送文字。')
          : '蓝牙链路已建立，正在核验已登记身份。认证完成前不能发送测试消息。',
    BluetoothConnectionPhase.authenticated =>
      c.transport.textEnabled
          ? '已确认${c.peerLabel}的邻跃身份。返回首页即可通信；文件是否可用以首页状态为准。'
          : '已确认${c.peerLabel}的邻跃身份。可以返回聊天查看状态，或展开测试与诊断验证收发。',
    BluetoothConnectionPhase.starting => '正在准备接收电脑连接，无需手动设置连接参数。',
    BluetoothConnectionPhase.connecting => '正在连接手机，成功后将自动验证身份。',
    BluetoothConnectionPhase.checkingService =>
      '正在检查目标是否提供邻跃服务，尚未建立连接或信任。请保持手机邻跃处于等待状态。',
    BluetoothConnectionPhase.cancelled => '已停止本次连接，可重新尝试；身份登记与聊天记录均保留。',
    BluetoothConnectionPhase.disconnected => '连接已断开，可确认对端仍在运行后重试。',
    _ => '保持手机邻跃在前台，确认双方已在系统设置中配对。',
  };
}
