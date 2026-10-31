import 'dart:async';

import 'package:flutter/foundation.dart';

import '../security/device_identity.dart';
import 'bluetooth_transport.dart';
import 'bluetooth_peer_catalog.dart';
export 'bluetooth_peer_catalog.dart' show PairedBluetoothDevice;

enum BluetoothConnectionPhase {
  idle,
  checking,
  permissionRequired,
  permissionPending,
  radioOff,
  unavailable,
  pairingRequired,
  identityRequired,
  chooseIdentity,
  chooseDevice,
  checkingService,
  starting,
  waiting,
  connecting,
  authenticating,
  authenticated,
  disconnected,
  failed,
  stopping,
  cancelled,
}

/// B2 presentation/workflow only. B1 owns RFCOMM, crypto and authorization.
/// A selected OS device is never used to infer a registered LINYUE identity.
class BluetoothConnectionController extends ChangeNotifier {
  BluetoothConnectionController({
    required this.transport,
    BluetoothPeerBindings? bindings,
    this.permissionWait = const Duration(seconds: 20),
    this.refreshInterval = const Duration(milliseconds: 350),
    this.serviceWait = const Duration(seconds: 18),
  }) : bindings = bindings ?? BluetoothPeerBindings(transport.identity) {
    transport.addListener(_transportChanged);
  }

  final BluetoothTransport transport;
  final BluetoothPeerBindings bindings;
  final Duration permissionWait, refreshInterval, serviceWait;
  DeviceIdentityManager get identity => transport.identity;
  bool get android => transport.server;
  BluetoothConnectionPhase phase = BluetoothConnectionPhase.idle;
  List<PairedBluetoothDevice> devices = [];
  String? selectedFingerprint, selectedDeviceId;
  String errorDetail = '', errorHint = '', radioDetail = '';
  String _observedError = '';
  String localBluetoothName = '', associationHint = '';
  int incompleteDevices = 0;
  int excludedPeripherals = 0;
  String? _serviceReadyFor;
  String? _savedBindingFor;
  bool _disposed = false, _preparing = false, _starting = false;
  int _operation = 0;
  bool get preparing => _preparing;
  bool get active => transport.active || _starting;
  bool get authenticated =>
      phase == BluetoothConnectionPhase.authenticated &&
      transport.authenticated;
  bool get busy =>
      _preparing || _starting || phase == BluetoothConnectionPhase.stopping;
  List<RegisteredIdentity> get identities => identity.entries;
  String get localFingerprint {
    try {
      return identity.local.fingerprint;
    } catch (_) {
      return '';
    }
  }

  String get peerLabel {
    if (transport.textEnabled && transport.peerName.isNotEmpty) {
      return transport.peerName;
    }
    final id =
        canonicalBluetoothAddress(transport.connectedDeviceId) ??
        selectedDeviceId;
    final matches = devices.where((d) => d.id == id);
    return matches.isEmpty ? '已验证对端' : matches.first.name;
  }

  String get selectedName {
    final matches = devices.where((d) => d.id == selectedDeviceId);
    return matches.isEmpty ? '对端设备' : matches.first.displayName;
  }

  String get failedStage {
    final text = errorDetail.toLowerCase();
    if (text.contains('target device') ||
        text.contains('target_missing') ||
        text.contains('target_invalid')) {
      return '目标设备解析';
    }
    if (text.contains('paired_enumeration_failed') ||
        text.contains('paired device enumeration')) {
      return '系统配对枚举';
    }
    if (text.contains('windows adapter query') ||
        text.contains('radio_query_failed') ||
        text.contains('radio_access_denied') ||
        text.contains('radio_not_found')) {
      return '蓝牙适配器查询';
    }
    if (text.contains('winsock')) return '系统蓝牙Socket初始化';
    if (text.contains('radio unavailable')) return '蓝牙适配器';
    if (text.contains('unsupported peripheral')) return '设备选择';
    if (text.contains('service discovery') ||
        text.contains('service_discovery')) {
      return '目标服务检查';
    }
    if (text.contains('signature') ||
        text.contains('identity') ||
        text.contains('authentication') ||
        text.contains('registered') ||
        text.contains('trusted')) {
      return '身份认证';
    }
    if (text.contains('os-paired') ||
        text.contains('bond') ||
        text.contains('设备信息')) {
      return '设备选择';
    }
    if (text.contains('ack') || text.contains('test not acknowledged')) {
      return '测试消息确认';
    }
    return '蓝牙建链或连接';
  }

  void _set(BluetoothConnectionPhase value) {
    phase = value;
    if (!_disposed) notifyListeners();
  }

  bool _current(int op) => !_disposed && op == _operation;

  String get label => switch (phase) {
    BluetoothConnectionPhase.idle => '蓝牙未连接',
    BluetoothConnectionPhase.checking => '正在检查蓝牙与已配对设备',
    BluetoothConnectionPhase.permissionRequired => '蓝牙权限未授予',
    BluetoothConnectionPhase.permissionPending => '请允许蓝牙连接权限',
    BluetoothConnectionPhase.radioOff => '蓝牙未开启',
    BluetoothConnectionPhase.unavailable => '蓝牙适配器不可用',
    BluetoothConnectionPhase.pairingRequired => '请先完成系统蓝牙配对',
    BluetoothConnectionPhase.identityRequired => '请先登记对端邻跃身份',
    BluetoothConnectionPhase.chooseIdentity => '首次连接，请核对对端身份',
    BluetoothConnectionPhase.chooseDevice =>
      android ? '选择要等待的电脑' : '选择已配对的候选设备',
    BluetoothConnectionPhase.checkingService => '正在检查手机邻跃服务',
    BluetoothConnectionPhase.starting => '正在准备蓝牙连接',
    BluetoothConnectionPhase.waiting => '等待电脑连接',
    BluetoothConnectionPhase.connecting => '正在建立蓝牙连接',
    BluetoothConnectionPhase.authenticating => '正在验证对端邻跃身份',
    BluetoothConnectionPhase.authenticated => '蓝牙已连接 · 身份认证成功',
    BluetoothConnectionPhase.disconnected => '蓝牙连接已断开',
    BluetoothConnectionPhase.failed => '蓝牙连接失败',
    BluetoothConnectionPhase.stopping => '正在停止蓝牙连接',
    BluetoothConnectionPhase.cancelled => '已取消蓝牙连接',
  };

  void _transportChanged() {
    if (_disposed || _preparing || phase == BluetoothConnectionPhase.stopping) {
      return;
    }
    if (transport.lastError.isNotEmpty &&
        transport.lastError != _observedError) {
      _observedError = transport.lastError;
      errorDetail = transport.lastError;
      errorHint = friendlyBluetoothError(errorDetail);
    }
    if (transport.authenticated) {
      if (transport.textEnabled) {
        selectedFingerprint = transport.peerFingerprint;
      }
      final actual = canonicalBluetoothAddress(transport.connectedDeviceId);
      if (actual != null &&
          selectedDeviceId != null &&
          actual != selectedDeviceId) {
        errorDetail = 'Connected endpoint does not match selected OS device';
        errorHint = '实际连接设备与所选设备不一致，请停止后重新核对。';
        _set(BluetoothConnectionPhase.failed);
        unawaited(transport.disconnect(reason: errorDetail));
        return;
      }
      _set(BluetoothConnectionPhase.authenticated);
      unawaited(_rememberAuthenticatedPeer(actual));
    } else if (transport.state == 'connected') {
      _set(BluetoothConnectionPhase.authenticating);
    } else if (transport.state == 'listening') {
      _set(BluetoothConnectionPhase.waiting);
    } else if (transport.state == 'connecting') {
      _set(
        android
            ? BluetoothConnectionPhase.starting
            : BluetoothConnectionPhase.connecting,
      );
    } else if (transport.state == 'error') {
      final lower = transport.lastError.toLowerCase();
      _set(
        lower.contains('peer disconnected') ||
                lower.contains('10054') ||
                lower.contains('10101')
            ? BluetoothConnectionPhase.disconnected
            : BluetoothConnectionPhase.failed,
      );
    }
  }

  /// Called by the single connection sheet. No scanning or automatic LAN fallback.
  Future<void> prepare({
    bool askPermission = false,
    bool resumeKnown = false,
  }) async {
    if (_disposed || busy || transport.active) return;
    final op = ++_operation;
    _preparing = true;
    errorDetail = '';
    errorHint = '';
    associationHint = '';
    _serviceReadyFor = null;
    devices = [];
    incompleteDevices = 0;
    _set(BluetoothConnectionPhase.checking);
    try {
      if (localFingerprint.isEmpty) throw StateError('设备身份尚未初始化');
      var status = await transport.status();
      if (!_current(op)) return;
      transport.captureNativeDiagnostics(status['diagnostics']);
      if (!android &&
          (status['adapterState'] == 'query-error' ||
              status['adapterState'] == 'access-denied')) {
        throw StateError(
          'Windows adapter query ${status['adapterState']}; Win32=${status['adapterError']}',
        );
      }
      if (status['permission'] != true && askPermission && android) {
        _set(BluetoothConnectionPhase.permissionPending);
        await transport.requestPermission();
        // B1 returns when the dialog is requested, not when a choice is made.
        // Observe the grant; never treat successful invocation as permission.
        final watch = Stopwatch()..start();
        while (_current(op) && watch.elapsed < permissionWait) {
          await Future<void>.delayed(refreshInterval);
          if (!_current(op)) return;
          status = await transport.status();
          if (status['permission'] == true) break;
        }
      }
      if (!_current(op)) return;
      if (status['permission'] != true) {
        devices = [];
        _set(BluetoothConnectionPhase.permissionRequired);
        return;
      }
      if (!android) {
        // Radio.State is queried asynchronously by B1. Do not call its
        // mere adapter enumeration an "enabled" radio.
        for (var attempt = 0; attempt < 5; attempt++) {
          radioDetail =
              await transport.native.invoke<String>('radioStatus') ?? 'unknown';
          if (!_current(op)) return;
          if (radioDetail == 'on' ||
              radioDetail == 'off' ||
              radioDetail == 'disabled') {
            break;
          }
          await Future<void>.delayed(refreshInterval);
        }
      } else {
        radioDetail = status['radio'] == true ? 'on' : 'off';
      }
      if (!_current(op)) return;
      await transport.refreshNativeDiagnostics();
      if (!_current(op)) return;
      if (radioDetail == 'off') {
        devices = [];
        _set(BluetoothConnectionPhase.radioOff);
        return;
      }
      if ((!android && status['radioAvailable'] == false) ||
          radioDetail == 'disabled') {
        devices = [];
        _set(BluetoothConnectionPhase.unavailable);
        return;
      }
      if (status['devicesError'] is String &&
          (status['devicesError'] as String).isNotEmpty) {
        throw StateError('读取系统已配对设备失败：${status['devicesError']}');
      }
      localBluetoothName = status['localName'] is String
          ? status['localName'] as String
          : '';
      transport.localName = localBluetoothName;
      final catalog = BluetoothPeerCatalog.fromSnapshot(status['devices']);
      excludedPeripherals = android
          ? 0
          : catalog.devices.where((d) => d.peripheral).length;
      devices = catalog.devices.where((d) => android || !d.peripheral).toList();
      incompleteDevices = catalog.incompleteEntries;
      if (!devices.any((d) => d.id == selectedDeviceId)) {
        if (selectedDeviceId != null) selectedFingerprint = null;
        selectedDeviceId = null;
      }
      await bindings.load();
      if (!_current(op)) return;
      try {
        await bindings.retainPaired(devices.map((d) => d.id).toSet());
      } catch (_) {
        associationHint = '已验证设备关联暂不可用，本次仍须核对身份。';
      }
      if (!_current(op)) return;
      if (devices.isEmpty) {
        _set(
          incompleteDevices > 0
              ? BluetoothConnectionPhase.unavailable
              : BluetoothConnectionPhase.pairingRequired,
        );
        return;
      }
      if (!android) {
        // Physical OS devices always precede the trust registry. Never display
        // the registry as though each key were a different Bluetooth handset.
        selectedFingerprint = null;
        final known = devices
            .where(
              (d) =>
                  bindings.loadError == null &&
                  bindings.fingerprintFor(d.id) != null,
            )
            .toList();
        if (resumeKnown && transport.textEnabled && known.length == 1) {
          _preparing = false;
          await connectDevice(known.single.id);
        } else {
          _set(BluetoothConnectionPhase.chooseDevice);
        }
        return;
      }
      // Only Android is a server. Windows must select an OS-paired target and
      // complete probeService before any client connect, even in E30 text mode.
      if (transport.textEnabled) {
        _preparing = false;
        selectedFingerprint = null;
        selectedDeviceId = null;
        await _connect(op);
        return;
      }
      if (identities.isEmpty) {
        _set(BluetoothConnectionPhase.identityRequired);
        return;
      }
      final known = devices
          .where((d) => bindings.fingerprintFor(d.id) != null)
          .toList();
      if (known.length == 1) {
        selectedDeviceId = known.single.id;
        selectedFingerprint = bindings.fingerprintFor(known.single.id);
      } else if (identities.length == 1) {
        selectedFingerprint = identities.single.fingerprint;
      } else if (!identities.any((i) => i.fingerprint == selectedFingerprint)) {
        selectedFingerprint = null;
      }
      _preparing = false;
      if (selectedFingerprint != null) {
        await _connect(op);
      } else {
        _set(BluetoothConnectionPhase.chooseDevice);
      }
    } catch (e) {
      if (_current(op)) _failure(e);
    } finally {
      if (_current(op)) {
        _preparing = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<void> selectIdentity(String fingerprint) async {
    if (busy ||
        transport.active ||
        !identities.any((i) => i.fingerprint == fingerprint) ||
        (!android && _serviceReadyFor != selectedDeviceId)) {
      return;
    }
    selectedFingerprint = fingerprint;
    if (android || selectedDeviceId != null) {
      await _connect(++_operation);
    }
  }

  Future<void> connectDevice(String id) async {
    final canonical = canonicalBluetoothAddress(id);
    if (busy ||
        transport.active ||
        canonical == null ||
        !devices.any((d) => d.id == canonical)) {
      return;
    }
    selectedDeviceId = canonical;
    selectedFingerprint = null;
    if (!android) {
      final op = ++_operation;
      _preparing = true;
      errorHint = '';
      errorDetail = '';
      _serviceReadyFor = null;
      _set(BluetoothConnectionPhase.checkingService);
      try {
        final generation = await transport.native.invoke<int>('probeService', {
          'id': canonical,
        });
        if (!_current(op)) return;
        if (generation == null) {
          throw StateError('Service discovery unavailable');
        }
        final watch = Stopwatch()..start();
        while (_current(op)) {
          final result = await transport.native.invoke<Map>('probeStatus');
          if (!_current(op)) return;
          transport.captureNativeDiagnostics(result?['diagnostics']);
          if (result?['generation'] != generation) {
            throw StateError('Service discovery cancelled or stale result');
          }
          final outcome = result?['service'];
          if (outcome == 'ready') {
            _serviceReadyFor = canonical;
            break;
          }
          if (outcome == 'missing') {
            throw StateError(
              'Service discovery: target UUID not found in this query; ${result?['error'] ?? ''}',
            );
          }
          if (outcome == 'timeout' || watch.elapsed >= serviceWait) {
            throw StateError('Service discovery timeout');
          }
          if (outcome != 'checking') {
            throw StateError(
              'Service discovery: ${result?['error'] ?? outcome}',
            );
          }
          await Future<void>.delayed(refreshInterval);
        }
      } catch (e) {
        if (_current(op)) {
          Object failure = e;
          try {
            await transport.native.invoke<void>('stop', {
              'reason': 'controller-probe-failure',
            });
          } catch (stopError) {
            failure = StateError('$e; Native stop failed: $stopError');
          }
          if (_current(op)) _failure(failure);
        }
        return;
      } finally {
        if (_current(op)) {
          _preparing = false;
          if (!_disposed) notifyListeners();
        }
      }
      if (!_current(op)) return;
    }
    selectedFingerprint = bindings.fingerprintFor(canonical);
    if (transport.textEnabled) {
      await _connect(++_operation);
      return;
    }
    if (android && selectedFingerprint == null && identities.length == 1) {
      selectedFingerprint = identities.single.fingerprint;
    }
    if (identities.isEmpty) {
      _set(BluetoothConnectionPhase.identityRequired);
      return;
    }
    if (selectedFingerprint == null) {
      _set(BluetoothConnectionPhase.chooseIdentity);
      return;
    }
    await _connect(++_operation);
  }

  Future<void> confirmIdentity(String code) async {
    if (busy || transport.active || selectedDeviceId == null) return;
    final fingerprint = resolveBluetoothIdentity(
      identities.map((i) => i.fingerprint),
      code,
    );
    if (fingerprint == null) {
      errorHint = '核对码不完整、对应多个登记，或该身份尚未登记。请核对对端当前页面；必要时在诊断中使用完整身份指纹。';
      if (!_disposed) notifyListeners();
      return;
    }
    errorHint = '';
    await selectIdentity(fingerprint);
  }

  Future<void> reviewIdentity() async {
    if (busy || transport.active || selectedDeviceId == null) return;
    final op = ++_operation;
    _preparing = true;
    try {
      await bindings.forget(selectedDeviceId!);
    } catch (_) {
      associationHint = '旧关联无法持久更新，本次可重新核对。';
    }
    if (!_current(op)) return;
    _preparing = false;
    selectedFingerprint = null;
    errorDetail = '';
    errorHint = '';
    if (transport.textEnabled) {
      await _connect(++_operation);
      return;
    }
    _set(BluetoothConnectionPhase.chooseIdentity);
  }

  Future<void> _rememberAuthenticatedPeer(String? actual) async {
    final fp = selectedFingerprint;
    final token = '$_operation:$actual:$fp';
    if (actual == null ||
        fp == null ||
        !transport.authenticated ||
        _savedBindingFor == token) {
      return;
    }
    _savedBindingFor = token;
    try {
      await bindings.remember(actual, fp);
    } catch (_) {
      associationHint = '本次身份已验证，但关联未保存；下次仍需核对。';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _connect(int op) async {
    if (!_current(op) ||
        _starting ||
        transport.active ||
        (!transport.textEnabled && selectedFingerprint == null)) {
      return;
    }
    if (!android &&
        (selectedDeviceId == null || _serviceReadyFor != selectedDeviceId)) {
      _failure(
        StateError('Target device missing or service discovery not completed'),
      );
      return;
    }
    _starting = true;
    _savedBindingFor = null;
    _set(
      android
          ? BluetoothConnectionPhase.starting
          : BluetoothConnectionPhase.connecting,
    );
    try {
      await transport.start(
        expectedFingerprint: selectedFingerprint ?? '',
        deviceId: selectedDeviceId,
      );
      if (!_current(op)) return;
      _observedError = '';
    } catch (e) {
      if (_current(op)) _failure(e);
    } finally {
      if (_current(op)) {
        _starting = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  void _failure(Object e) {
    errorDetail = '$e';
    errorHint = errorDetail.contains('身份尚未初始化')
        ? '本机身份尚未准备好，请稍后重试。'
        : friendlyBluetoothError(errorDetail);
    _set(BluetoothConnectionPhase.failed);
  }

  Future<void> stop() async {
    if (_disposed || phase == BluetoothConnectionPhase.stopping) return;
    ++_operation;
    _preparing = false;
    _starting = false;
    _serviceReadyFor = null;
    selectedDeviceId = null;
    selectedFingerprint = null;
    _set(BluetoothConnectionPhase.stopping);
    await transport.disconnect();
    if (_disposed) return;
    if (transport.lastError.startsWith('Native stop failed:')) {
      _failure(StateError(transport.lastError));
      return;
    }
    errorDetail = '';
    errorHint = '';
    _observedError = '';
    _set(BluetoothConnectionPhase.cancelled);
  }

  /// Dismissing a sheet cancels preparation, but keeps an established/waiting
  /// session owned by the home. Explicit stop always stops the native service.
  void leaveSheet() {
    if (phase == BluetoothConnectionPhase.stopping) return;
    if (phase == BluetoothConnectionPhase.waiting || authenticated) return;
    if (active || phase == BluetoothConnectionPhase.checkingService) {
      unawaited(stop());
      return;
    }
    ++_operation;
    _preparing = false;
    selectedDeviceId = null;
    selectedFingerprint = null;
    _serviceReadyFor = null;
    _set(BluetoothConnectionPhase.cancelled);
  }

  Future<void> backToDevices() async {
    if (active || busy) await stop();
    if (_disposed) return;
    if (transport.lastError.startsWith('Native stop failed:')) return;
    ++_operation;
    selectedDeviceId = null;
    selectedFingerprint = null;
    _serviceReadyFor = null;
    errorDetail = '';
    errorHint = '';
    _set(
      devices.isEmpty
          ? BluetoothConnectionPhase.pairingRequired
          : BluetoothConnectionPhase.chooseDevice,
    );
  }

  Future<void> openBluetoothSettings() async {
    try {
      await transport.native.invoke<void>('openSettings');
    } catch (e) {
      errorDetail = '$e';
      errorHint = '未能打开系统蓝牙设置，请手动打开系统设置中的蓝牙页面。';
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_operation;
    transport.removeListener(_transportChanged);
    transport.dispose();
    super.dispose();
  }
}

String friendlyBluetoothError(String raw) {
  final e = raw.toLowerCase();
  if (e.contains('target device') ||
      e.contains('target_missing') ||
      e.contains('target_invalid')) {
    return '所选手机标识缺失或无效，本次尚未连接。请返回设备列表重新选择，保留诊断。';
  }
  if (e.contains('winsock')) return '系统蓝牙Socket初始化失败，请保留原生初始化错误码；这不等于蓝牙未开启。';
  if (e.contains('paired_enumeration_failed') ||
      e.contains('paired device enumeration')) {
    return '系统已配对设备查询失败，请保留接口错误码，稍后刷新；尚不能认定手机未配对。';
  }
  if (e.contains('target_not_paired')) {
    return '当前系统接口未匹配所选手机。请刷新并核对目标名称及尾号，保留原生匹配结果。';
  }
  if (e.contains('windows adapter query') ||
      e.contains('radio_query_failed') ||
      e.contains('radio_access_denied')) {
    return 'Windows 蓝牙适配器查询失败或访问被拒绝，请保留原始错误码；没有将未知状态当作蓝牙关闭。';
  }
  if (e.contains('radio_not_found')) return '当前经典蓝牙接口未枚举到适配器，请核对系统适配器及驱动，保留诊断。';
  if (e.contains('association protocol incompatible')) {
    return '蓝牙关联版本不兼容，请电脑和手机都使用 E30 测试包，再重新连接。';
  }
  if (e.contains('rejected comparison code') ||
      e.contains('commitment mismatch')) {
    return '首次关联核对未通过，已拒绝建立可信会话。请在两端直接比较全部核对码，不一致时不要确认。';
  }
  if (e.contains('unsupported peripheral')) {
    return '所选设备是系统外设，不能作为待连接手机。请完成手机配对后刷新列表。';
  }
  if (e.contains('service discovery') || e.contains('service_discovery')) {
    if (e.contains('consentrequired') || e.contains('0x80070005')) {
      return 'Windows 蓝牙服务查询需要访问授权或被拒绝。请核对系统权限，并复制原生日志中的访问状态和错误码。';
    }
    if (e.contains('resourceinuse')) {
      return '系统报告蓝牙资源正被占用。请结束其他应用对此手机的蓝牙连接后重试，并保留原生日志。';
    }
    if (e.contains('devicenotconnected')) {
      return '系统服务查询报告对端未连接。请保持手机邻跃前台等待，再重试；尚未进入身份认证。';
    }
    return e.contains('timeout')
        ? '目标服务检查超时，请让手机邻跃保持“等待电脑连接”，再刷新或重试。'
        : '未能确认手机的邻跃蓝牙服务。请确认已完成系统配对、手机已启动等待；键盘和鼠标不能作为目标。';
  }
  if (e.contains('authentication timeout')) {
    return '身份验证超时，请确认手机保持亮屏，且两端选择了正确身份。';
  }
  if (e.contains('permission') || e.contains('securityexception')) {
    return '未获得蓝牙连接权限，请在系统设置中允许后重试。';
  }
  if (e.contains('signature') ||
      e.contains('identity') ||
      e.contains('registered') ||
      e.contains('revoked') ||
      e.contains('trusted')) {
    return '对端身份验证未通过，请确认两端选择了正确的已登记身份。';
  }
  if (e.contains('disabled') || e.contains('radio unavailable')) {
    return '请开启系统蓝牙，并确认适配器可用后重试。';
  }
  if (e.contains('peer disconnected') ||
      e.contains('10054') ||
      e.contains('10101')) {
    return '连接已断开，请确认对端应用仍在运行，再重新连接。';
  }
  if (e.contains('timeout') || e.contains('10060')) {
    return '连接超时，请确认手机正在等待电脑连接，再重试。';
  }
  if (e.contains('bond') || e.contains('os-paired')) {
    return '请先在系统蓝牙设置中将电脑和手机配对，再重试。';
  }
  if (e.contains('10013')) {
    return '系统蓝牙安全连接被拒绝，请检查系统配对状态。';
  }
  return '未能完成蓝牙连接，请确认手机已准备好后重试；详细原因可在诊断中查看。';
}
