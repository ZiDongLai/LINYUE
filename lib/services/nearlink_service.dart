import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'peer_presence.dart';
import 'discovery_warmup_policy.dart';
import 'discovery_active_probe_policy.dart';
import 'discovery_latency_trace.dart';
import 'discovery_probe_batch.dart';
import 'discovery_packet_diagnostics.dart';
import 'discovery_packet_journal.dart';

/// v0.1 LAN testing protocol. IMPORTANT: HTTP is NOT encrypted.
/// Run on a trusted private network only. Never use on public Wi-Fi.
const int discoveryPort = 46728;
const int transferPort = 46729;
const int maxFileBytes = 20 * 1024 * 1024;
const String protocolVersion = 'nearlink/0.1';

String sanitizeFileName(String raw) {
  final name = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim();
  if (name.isEmpty || name == '.' || name == '..') return 'unnamed_file';
  return name.length > 120 ? name.substring(name.length - 120) : name;
}

String randomHex(int byteCount) {
  final rng = Random.secure();
  return List.generate(
    byteCount,
    (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

bool isValidIpv4(String host) {
  final parts = host.trim().split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) {
      return false;
    }
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
  }
  return true;
}

class NearPeer {
  NearPeer({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    DateTime? seenAt,
  }) : seenAt = seenAt ?? DateTime.now();

  final String id;
  final String name;
  final String ip;
  final int port;
  DateTime seenAt;

  // This indicates network freshness only, never a verified/trusted identity.
  bool get isManual => id.startsWith('manual:');
  bool get isStale => !isManual && !peerRecentlySeen(seenAt, DateTime.now());
}

class FileOffer {
  FileOffer({
    required this.name,
    required this.size,
    required this.senderName,
    required this.remoteIp,
  });
  final String name;
  final int size;
  final String senderName;
  final String remoteIp;
}

class _AcceptedOffer {
  _AcceptedOffer({
    required this.name,
    required this.size,
    required this.hash,
    required this.ip,
  }) : expiresAt = DateTime.now().add(const Duration(minutes: 2));

  final String name;
  final int size;
  final String hash;
  final String ip;
  final DateTime expiresAt;
}

class NearLinkService extends ChangeNotifier {
  NearLinkService({required this.deviceName, this.allowLegacyFileTransfer = false}) : deviceId = randomHex(12);

  final String deviceName;
  final bool allowLegacyFileTransfer;
  final String deviceId;
  RawDatagramSocket? _udp;
  HttpServer? _httpServer;
  Timer? _announceTimer;
  final List<Timer> _warmupTimers = [];
  final DiscoveryReplyThrottle _discoveryReplyThrottle = DiscoveryReplyThrottle();
  Stopwatch? _firstDiscoveredPeerClock;
  Stopwatch? _discoveryTraceClock;
  DiscoveryLatencyTrace? _discoveryTrace;
  final List<Timer> _discoveryTraceTimers = [];
  // D4-B3 diagnostics are deliberately bounded and never affect discovery.
  static const int _maxUdpDiagnosticSamples = 10;
  static const int _maxHelloSendDiagnosticSamples = 6;
  static const int _maxHelloReplyDiagnosticSamples = 4;
  int _udpDiagnosticSamples = 0;
  int _helloSendDiagnosticCount = 0;
  int _helloReplyDiagnosticCount = 0;
  bool _firstValidHelloDiagnosticLogged = false;
  final Set<String> _dismissedUdpDiagnosticIdsLogged = {};
  Set<String>? _localDiscoveryAddresses;
  int _networkDiagnosticCount = 0;
  int _udpErrorDiagnosticCount = 0;
  int _sameIdOtherDiagnosticCount = 0;
  int _visibleDiagnosticCount = 0;
  int _socketEventSequence = 0;
  Future<void> _lifecycleOperation = Future<void>.value();
  Timer? _peerTimer;
  Timer? _probeTimer;
  bool _probeInProgress = false;
  Timer? _manualProbeKick;
  bool _manualHealthProbeInProgress = false;
  final Set<String> _alreadyProbedManualIps = {};
  bool _manualProbeNoTargetsLogged = false;
  bool _manualProbeTargetsLogged = false;
  final Set<String> _manualProbeFailureLoggedIps = {};
  final Set<String> _manualProbeSuccessLoggedIps = {};
  HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);
  final Map<String, NearPeer> _peers = {};
  final Set<String> _staleLogged = {};
  // Hidden *discovery display entries* remain suppressed until explicit user
  // refresh or process restart; they are NOT trusted-device revocations.
  final Map<String, String> _dismissedDiscoveredPeers = {};
  final Map<String, _AcceptedOffer> _accepted = {};
  final List<String> _logs = [];
  bool _running = false;
  bool _disposed = false;
  late final _packetJournal = DiscoveryPacketJournal(
    platform: Platform.operatingSystem, deviceId: deviceId, enabled: kDebugMode,
    eventLimit: 512,
    emit: (record) => debugPrintSynchronously(
        '[LINYUE-D4B5] ${jsonEncode(record)}'),
  );

  Future<bool> Function(FileOffer offer)? askReceiver;
  void Function(File file)? receivedFile;

  bool get running => _running;
  List<NearPeer> get peers => List.unmodifiable(_peers.values);
  List<String> get logs => List.unmodifiable(_logs);
  List<Map<String, Object?>> get discoveryPacketEvents => _packetJournal.records;
  bool get hasPendingDiscoveryUiEvidence => _packetJournal.hasPendingUi;
  void recordDiscoveryUiFrame(Iterable<NearPeer> snapshot) {
    if (!_disposed) _packetJournal.uiSnapshot(snapshot.map((p) => p.id).toSet());
  }
  void recordDiscoverySignature(String remoteIp, String via) {
    if (!_disposed) {
      _packetJournal.event('signature_verified', {'remote_ip': remoteIp, 'via': via});
    }
  }

  /// App-level diagnostics, written to the same bounded in-memory log as
  /// discovery and transfer events. This API never changes pairing trust,
  /// network connectivity or message acknowledgement state.
  void logDiagnostic(String message) => _log(message);

  void _log(String message) {
    if (_disposed) return;
    _logs.insert(0, '${DateTime.now().toIso8601String().substring(11, 19)}  $message');
    if (_logs.length > 40) _logs.removeLast();
    // Payload-free discovery evidence is also available through flutter run /
    // adb logcat in debug builds. Never mirror transfer or authentication logs.
    if (kDebugMode && (message.startsWith('D4') ||
        message.startsWith('发现诊断：'))) {
      debugPrintSynchronously('[LINYUE-DISCOVERY] $message');
    }
    notifyListeners();
  }

  String _discoveryIdTag(String id) =>
      sha256.convert(utf8.encode(id)).toString().substring(0, 12);

  Future<void> _recordDiscoveryInterfaces() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: true,
      ).timeout(const Duration(seconds: 2));
      final addresses = interfaces.expand((i) => i.addresses)
          .map((a) => a.address).toSet();
      if (!_running) return;
      final changed = _localDiscoveryAddresses == null ||
          !setEquals(_localDiscoveryAddresses, addresses);
      _localDiscoveryAddresses = addresses;
      if (changed && _networkDiagnosticCount < 4) {
        _networkDiagnosticCount++;
        _packetJournal.event('interfaces', {'interfaces_truncated': interfaces.length > 8,
          'interfaces': interfaces.take(8).map(
          (i) => {'name': i.name.substring(0, min(i.name.length, 80)),
            'index': i.index, 'addresses': i.addresses.take(4).map((a) => a.address).toList(),
            'addresses_truncated': i.addresses.length > 4}
        ).toList()});
        _log('D4C 本机 IPv4：${addresses.join(",")}；'
            '发现 ID 指纹=${_discoveryIdTag(deviceId)}（进程随机 ID，非配对身份）');
      }
    } catch (error) {
      if (_running && _networkDiagnosticCount < 4) {
        _networkDiagnosticCount++;
        _log('D4C 网卡诊断不可用：${error.runtimeType}；不能据同 ID 判断冲突');
      }
    }
  }

  Future<void> start() async {
    if (_disposed) throw StateError('Discovery service has been disposed');
    final previous = _lifecycleOperation;
    final operation = () async {
      await previous;
      if (!_disposed && !_running) await _startService();
    }();
    // Keep the queue usable after failure while returning the error to caller.
    _lifecycleOperation = operation.then<void>((_) {},
        onError: (Object error, StackTrace stack) {});
    await operation;
  }

  Future<void> _startService() async {
    if (_running) return;
    _packetJournal.startRun();
    _socketEventSequence = 0;
    // stop() closes the client; a restarted service needs a fresh one.
    _client.close(force: true);
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _manualProbeNoTargetsLogged = false;
    _manualProbeTargetsLogged = false;
    _manualProbeFailureLoggedIps.clear();
    _manualProbeSuccessLoggedIps.clear();
    _udpDiagnosticSamples = 0;
    _helloSendDiagnosticCount = 0;
    _helloReplyDiagnosticCount = 0;
    _firstValidHelloDiagnosticLogged = false;
    _dismissedUdpDiagnosticIdsLogged.clear();
    _localDiscoveryAddresses = null;
    _networkDiagnosticCount = 0;
    _udpErrorDiagnosticCount = 0;
    _sameIdOtherDiagnosticCount = 0;
    _visibleDiagnosticCount = 0;
    _discoveryTraceClock = Stopwatch()..start();
    _discoveryTrace = DiscoveryLatencyTrace();
    _log('D4C 发现服务开始；UDP $discoveryPort / TCP $transferPort；'
        'ID 指纹=${_discoveryIdTag(deviceId)}');
    // Start TCP first so the advertised discovery endpoint always exists.
    try {
      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, transferPort);
      if (_disposed) { await _stopService(); return; }
      _packetJournal.event('socket_bind_begin', {'bind': '0.0.0.0',
        'port': discoveryPort, 'reuse_address': true});
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      if (_disposed) { await _stopService(); return; }
      _udp!.broadcastEnabled = true;
      final listeningRun = _packetJournal.run;
      final listeningSocket = _udp!;
      _packetJournal.event('listener_register', {'socket_run': listeningRun,
        'bind': listeningSocket.address.address, 'port': listeningSocket.port});
      _udp!.listen((event) => _handleUdp(event,
        eventSocket: listeningSocket, listenerRun: listeningRun), onError: (Object error) {
        if (_udpErrorDiagnosticCount++ < 2) {
          _packetJournal.event('socket_error', {'socket_run': listeningRun,
            'error': error.runtimeType.toString()});
          _log('D4C UDP 接收异常：${error.runtimeType}');
        }
      }, onDone: () {
        _packetJournal.event('listener_done', {'socket_run': listeningRun,
          'active_run': _packetJournal.run,
          'same_active_socket': identical(listeningSocket, _udp),
          'explicit_cancel': false, 'completion': 'socket_stream_done'});
        _packetJournal.event('socket_closed', {'socket_run': listeningRun,
          'expected': !_running || listeningRun != _packetJournal.run});
        if (_running && listeningRun == _packetJournal.run) {
          _log('D4C UDP 监听意外关闭');
        }
      });
      _log('D4C UDP 已绑定并注册监听：0.0.0.0:$discoveryPort；'
          '运行${_discoveryTraceClock!.elapsedMilliseconds}ms；'
          'readEventsEnabled=${_udp!.readEventsEnabled}');
      _packetJournal.event('socket_ready', {'stage': 'B',
        'bind': _udp!.address.address, 'port': _udp!.port,
        'read_events': _udp!.readEventsEnabled, 'broadcast_enabled': _udp!.broadcastEnabled});
      _httpServer!.listen((request) {
        _handleHttp(request).catchError((Object error) {
          _log('接收服务异常：$error');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.close();
          } catch (_) {}
        });
      });
      _running = true;
      unawaited(_recordDiscoveryInterfaces());
      _discoveryReplyThrottle.clear();
      _firstDiscoveredPeerClock = Stopwatch()..start();
      // Diagnostic-only delayed snapshots: do not increase broadcast traffic.
      for (final seconds in <int>[10, 20, 35]) {
        _discoveryTraceTimers.add(Timer(Duration(seconds: seconds), () {
          if (!_running) return;
          _packetJournal.summary('snapshot_${seconds}s');
          if (_firstDiscoveredPeerClock == null) return;
          _emitDiscoveryTrace('等待 ${seconds}s');
        }));
      }
      // Warm-up only: do not replace the established 3-second steady timer.
      // No signed pairing or encrypted-transfer state is changed here.
      for (final delay in DiscoveryWarmupPolicy.warmupDelays) {
        _warmupTimers.add(Timer(delay, () {
          if (_running) _broadcastHello();
        }));
      }
      _announceTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _broadcastHello(),
      );
      _peerTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        final now = DateTime.now();
        // Keep an established device through temporary Wi-Fi/UDP packet loss.
        // Manual fallback entries remain until this app instance exits.
        _peers.removeWhere((_, peer) =>
            !peer.isManual && peerExpired(peer.seenAt, now));
        _staleLogged.removeWhere((id) => !_peers.containsKey(id));
        for (final peer in _peers.values) {
          if (!peer.isManual && peer.isStale && _staleLogged.add(peer.id)) {
            _log('设备暂时失联，自动重试：${peer.name}');
          }
        }
        _accepted.removeWhere((_, a) => now.isAfter(a.expiresAt));
        notifyListeners();
      });
      // A TCP reachability signal complements lossy UDP broadcasts.  The
      // endpoint is NOT an identity proof and does not grant send permission.
      _probeTimer = Timer.periodic(
        const Duration(seconds: 6), (_) {
          unawaited(_recordDiscoveryInterfaces());
          _alreadyProbedManualIps.clear();
          _scheduleManualHealthProbe();
          _probeKnownPeers();
        });
      // D4B2: probe already-saved manual IPs immediately instead of waiting
      // for the first six-second periodic tick. This is reachability only.
      _scheduleManualHealthProbe();
      _packetJournal.event('service_ready', {'stage': 'A',
        'udp': discoveryPort, 'tcp': transferPort, 'listening': true});
      _broadcastHello();
      _log('局域网服务启动，TCP $transferPort / UDP $discoveryPort');
    } catch (e) {
      _packetJournal.event('service_start_failed', {'error': e.runtimeType.toString()});
      await _stopService();
      rethrow;
    }
  }

  ({int sent, int length}) _sendDiscoveryHello(
      RawDatagramSocket socket, InternetAddress target) {
    final packet = _packetJournal.prepare({
      'protocol': protocolVersion, 'type': 'hello', 'id': deviceId,
      'name': deviceName, 'port': transferPort,
    });
    try {
      final sent = socket.send(packet.bytes, target, discoveryPort);
      _packetJournal.sent(packet, target: target.address, port: discoveryPort,
        bindAddress: socket.address.address, localPort: socket.port,
        returned: sent, listening: _running && socket.readEventsEnabled);
      return (sent: sent, length: packet.bytes.length);
    } catch (error) {
      _packetJournal.sent(packet, target: target.address, port: discoveryPort,
        bindAddress: socket.address.address, localPort: socket.port,
        error: error is SocketException
          ? 'SocketException:${error.osError?.errorCode}' : error.runtimeType.toString(),
        listening: _running && socket.readEventsEnabled);
      rethrow;
    }
  }

  void _broadcastHello() {
    final socket = _udp;
    if (socket == null) return;
    try {
      final elapsedMs = _discoveryTraceClock?.elapsedMilliseconds ?? 0;
      final sendResult = _sendDiscoveryHello(socket, InternetAddress('255.255.255.255'));
      final bytesSent = sendResult.sent;
      _discoveryTrace?.onBroadcast(
        elapsedMs,
        accepted: bytesSent == sendResult.length,
      );
      if (_helloSendDiagnosticCount < _maxHelloSendDiagnosticSamples) {
        _helloSendDiagnosticCount++;
        _log('D4B3 hello 广播发送 #$_helloSendDiagnosticCount：运行${elapsedMs}ms；'
            '本地 send 返回 $bytesSent/${sendResult.length} 字节（不代表对端已收到）');
      }
      // Repeat the same discovery packet directly to already-known LAN peers.
      // This costs very little and can recover when broadcasts are filtered.
      // E22-D2: explicitly saved LAN addresses also get bounded unicast
      // discovery, even before the first received UDP packet. This is NOT
      // pairing, identity proof or a permission to transfer files.
      for (final ip in DiscoveryActiveProbePolicy.unicastTargets(
          _peers.values.map((p) => p.ip))) {
        try {
          _sendDiscoveryHello(socket, InternetAddress(ip));
        } catch (_) {
          // A transient adapter/network change should not stop discovery.
        }
      }
    } catch (e) {
      _log('广播发送失败：$e');
    }
  }

  // Best-effort unicast hello sent only in response to an already validated
  // NEW or recovered UDP peer. No identity or trust is inferred from the IP.
  void _replyHelloTo(String sourceIp) {
    final socket = _udp;
    if (!_running || socket == null) return;
    try {
      final sendResult = _sendDiscoveryHello(socket, InternetAddress(sourceIp));
      final bytesSent = sendResult.sent;
      if (_helloReplyDiagnosticCount < _maxHelloReplyDiagnosticSamples) {
        _helloReplyDiagnosticCount++;
        final elapsedMs = _discoveryTraceClock?.elapsedMilliseconds ?? 0;
        _log('D4B3 hello 单播响应 #$_helloReplyDiagnosticCount：目标=$sourceIp；'
            '运行${elapsedMs}ms；本地 send 返回 $bytesSent/${sendResult.length} 字节');
      }
    } catch (e) {
      _log('发现响应发送失败：$e');
    }
  }

  void _emitDiscoveryTrace(String event) {
    final trace = _discoveryTrace;
    final clock = _discoveryTraceClock;
    if (trace == null || clock == null) return;
    _log('D4 发现时序：$event；${trace.summary(clock.elapsedMilliseconds)}');
  }

  void _logUdpPacketDiagnostic(String sourceIp, int byteLength, String reason) {
    if (_udpDiagnosticSamples >= _maxUdpDiagnosticSamples) return;
    _udpDiagnosticSamples++;
    _log('D4B3 UDP 包诊断 #$_udpDiagnosticSamples：来源=$sourceIp；'
        '长度=$byteLength 字节；$reason');
  }

  void _logFirstValidHelloDiagnostic(
      String sourceIp, Map<String, dynamic> body) {
    if (_firstValidHelloDiagnosticLogged) return;
    _firstValidHelloDiagnosticLogged = true;
    final elapsedMs = _discoveryTraceClock?.elapsedMilliseconds ?? 0;
    final id = body['id'] as String;
    _log('D4B3 首个协议有效 hello：来源=$sourceIp；运行${elapsedMs}ms；'
        '设备 ID 长度=${id.length}；ID指纹=${_discoveryIdTag(id)}；端口=${body['port']}');
  }

  void refreshPeers() {
    _dismissedDiscoveredPeers.clear();
    _alreadyProbedManualIps.clear();
    _broadcastHello();
    _scheduleManualHealthProbe();
    _probeKnownPeers();
  }

  void _scheduleManualHealthProbe() {
    // Coalesce startup/recovery of several saved IPs into one bounded pass.
    _manualProbeKick?.cancel();
    _manualProbeKick = Timer(const Duration(milliseconds: 250), () {
      if (_running) unawaited(_probeSavedManualTargets());
    });
  }

  // E22-D4B: limit each saved-address health check to one short, total
  // deadline and execute up to three independent IPs concurrently. The old
  // serial loop could wait for several dead addresses BEFORE checking a
  // reachable peer. This path is discovery-only and never authorizes trust.
  void _logManualProbeFailureOnce(String ip, Stopwatch timer, String reason) {
    if (_manualProbeFailureLoggedIps.add(ip)) {
      _log('D4B2 探测结果：$ip ${timer.elapsedMilliseconds}ms 失败（$reason）');
    }
  }

  void _logManualProbeSuccessOnce(String ip, Stopwatch timer) {
    if (_manualProbeSuccessLoggedIps.add(ip)) {
      _log('D4B2 探测结果：$ip ${timer.elapsedMilliseconds}ms 网络可达（尚未认证）');
    }
  }

  Future<void> _probeSavedManualTargets() async {
    if (!_running || _manualHealthProbeInProgress) return;
    _manualHealthProbeInProgress = true;
    try {
      final targets = DiscoveryActiveProbePolicy.unicastTargets(
          _peers.values.where((p) => p.isManual).map((p) => p.ip));
      if (targets.isEmpty) {
        if (!_manualProbeNoTargetsLogged) {
          _manualProbeNoTargetsLogged = true;
          _log('D4B2 启动探测：没有已保存的手动 IP；未知设备首次发现仍依赖 UDP 广播');
        }
        return;
      }
      final pending = targets
          .where((ip) => _alreadyProbedManualIps.add(ip))
          .toList(growable: false);
      if (pending.isEmpty) return;
      if (!_manualProbeTargetsLogged) {
        _manualProbeTargetsLogged = true;
        _log('D4B2 启动探测：立即检查 ${pending.length} 个已保存手动 IP，最多 '
            '${DiscoveryProbeBatch.maxConcurrency} 路并发');
      }
      await DiscoveryProbeBatch.run(pending, (ip) async {
        final deadline = Stopwatch()..start();
        const budget = Duration(milliseconds: 3000);
        Duration remaining() {
          final left = budget - deadline.elapsed;
          if (left <= Duration.zero) throw TimeoutException('健康探测超时');
          return left;
        }

        try {
          final req = await _client.getUrl(Uri(
              scheme: 'http', host: ip, port: transferPort,
              path: '/health')).timeout(remaining());
          final res = await req.close().timeout(remaining());
          if (res.statusCode != HttpStatus.ok) {
            await res.drain<void>().timeout(remaining());
            _logManualProbeFailureOnce(ip, deadline, 'HTTP ${res.statusCode}');
            return;
          }
          final responseText = await res.transform(utf8.decoder).join()
              .timeout(remaining());
          final candidate = DiscoveryActiveProbePolicy.parseHealthResponse(
              responseText, ip: ip, selfId: deviceId);
          if (candidate == null) {
            _logManualProbeFailureOnce(ip, deadline, '响应协议不匹配');
            return;
          }
          if (!_running) return;
          // A user may remove an address while an async probe is pending.
          // Never silently recreate a deleted locator.
          if (!_peers.values.any((p) => p.isManual && p.ip == ip)) return;
          final previous = _peers[candidate.id];
          if (previous != null && previous.ip != ip) {
            _logManualProbeFailureOnce(ip, deadline, '设备地址与现有条目冲突');
            return;
          }
          _logManualProbeSuccessOnce(ip, deadline);
          final wasAbsent = previous == null;
          _peers[candidate.id] = NearPeer(
              id: candidate.id, name: candidate.name,
              ip: ip, port: transferPort);
          _staleLogged.remove(candidate.id);
          if (wasAbsent) {
            _discoveryTrace?.onPeerVisible(
                _discoveryTraceClock?.elapsedMilliseconds ?? 0,
                via: DiscoveryTraceSource.healthProbe);
            _emitDiscoveryTrace('首次设备 TCP 健康探测');
            if (_firstDiscoveredPeerClock != null) {
              final elapsed = _firstDiscoveredPeerClock!.elapsedMilliseconds;
              _firstDiscoveredPeerClock!.stop();
              _firstDiscoveredPeerClock = null;
              _log('发现诊断：启动至首次发现 ${elapsed}ms'
                  '（只读 TCP 探测，尚未认证）');
            }
            _log('发现诊断：已保存地址 $ip 网络可达（尚需签名认证）');
          }
          notifyListeners();
        } catch (error) {
          // Offline/old addresses cannot delay all other saved targets.
          // Record only the first failure per IP to keep the 40-line log useful.
          _logManualProbeFailureOnce(ip, deadline, error.runtimeType.toString());
        }
      });
    } finally {
      _manualHealthProbeInProgress = false;
      // A manual IP added during the previous pass should not wait for a
      // much later periodic timer, and cannot be bypassed as signed trust.
      final remainingTargets = DiscoveryActiveProbePolicy.unicastTargets(
          _peers.values.where((p) => p.isManual).map((p) => p.ip))
          .where((ip) => !_alreadyProbedManualIps.contains(ip));
      if (_running && remainingTargets.isNotEmpty) _scheduleManualHealthProbe();
    }
  }

  Future<void> _probeKnownPeers() async {
    if (!_running || _probeInProgress) return;
    _probeInProgress = true;
    try {
      // Bound concurrent reachability checks; never scan the whole subnet.
      final peers = _peers.values.where((p) => !p.isManual).take(12).toList();
      await Future.wait(peers.map((peer) async {
        try {
          final uri = Uri(
            scheme: 'http', host: peer.ip, port: peer.port, path: '/health',
          );
          final req = await _client.getUrl(uri).timeout(const Duration(seconds: 3));
          final res = await req.close().timeout(const Duration(seconds: 3));
          if (res.statusCode != HttpStatus.ok) {
            await res.drain();
            return;
          }
          final body = await res.transform(utf8.decoder).join()
              .timeout(const Duration(seconds: 3));
          final status = jsonDecode(body);
          if (status is! Map<String, dynamic> ||
              status['protocol'] != protocolVersion ||
              status['id'] != peer.id) {
            return;
          }
          if (!_running) return;
          final current = _peers[peer.id];
          if (current == null || current.ip != peer.ip ||
              current.port != peer.port) {
            return;
          }
          final wasStale = current.isStale;
          current.seenAt = DateTime.now();
          _staleLogged.remove(current.id);
          if (wasStale) _log('重新发现：${current.name}');
          notifyListeners();
        } catch (_) {
          // Reachability failure is expected when a peer sleeps or changes IP.
          // The expiry timer, not one failure, determines whether to forget it.
        }
      }));
    } finally {
      _probeInProgress = false;
    }
  }

  void _handleUdp(RawSocketEvent event,
      {required RawDatagramSocket eventSocket, required int listenerRun}) {
    final eventId = ++_socketEventSequence;
    _packetJournal.event('socket_event', {'ev': eventId,
      'kind': event.toString(), 'socket_run': listenerRun,
      'active_run': _packetJournal.run,
      'same_active_socket': identical(eventSocket, _udp),
      'running': _running, 'disposed': _disposed});
    if (event != RawSocketEvent.read) return;
    final socket = _udp;
    if (socket == null) {
      _packetJournal.event('drain_end', {'ev': eventId,
        'packets': 0, 'reason': 'no_active_socket'});
      return;
    }
    var readCount = 0;
    while (true) {
      Datagram? packet;
      try {
        packet = socket.receive();
      } catch (error) {
        _packetJournal.event('socket_read_exception', {'ev': eventId,
          'socket_run': listenerRun, 'packets_before_error': readCount,
          'error': error.runtimeType.toString()});
        rethrow;
      }
      if (packet == null) {
        _packetJournal.event('drain_end', {'ev': eventId,
          'socket_run': listenerRun, 'packets': readCount,
          'reason': 'receive_returned_null'});
        break;
      }
      readCount++;
      _discoveryTrace?.onDatagram(
          _discoveryTraceClock?.elapsedMilliseconds ?? 0);
      final sourceIp = packet.address.address;
      final receipt = _packetJournal.receive(packet.data, sourceIp, packet.port,
        context: {'ev': eventId, 'socket_run': listenerRun, 'read_index': readCount});
      try {
        final classification = DiscoveryPacketClassifier.classify(
          packet.data,
          expectedProtocol: protocolVersion,
          selfId: deviceId,
          sourceIp: sourceIp,
          localAddresses: _localDiscoveryAddresses,
        );
        _packetJournal.annotate(receipt, classification.body);
        final compatible = classification.body?['protocol'] == protocolVersion;
        if (!classification.isProtocolValidHello) {
          _packetJournal.result(receipt, reason: classification.kind.name,
            protocolCompatible: compatible, remoteHello: false, peerUpdate: 'filtered');
          if (classification.kind == DiscoveryPacketKind.sameIdOtherAddress &&
              _sameIdOtherDiagnosticCount++ < 2) {
            _log('D4C 同 ID 异址诊断：来源=$sourceIp；长度=${packet.data.length}；'
                '类型=hello；ID指纹=${_discoveryIdTag(deviceId)}；'
                '运行${_discoveryTraceClock?.elapsedMilliseconds ?? 0}ms；'
                '${classification.label}');
          }
          _logUdpPacketDiagnostic(
              sourceIp, packet.data.length,
              '${classification.label}；运行${_discoveryTraceClock?.elapsedMilliseconds ?? 0}ms；'
              '类型=${classification.body?["type"] == "hello" ? "hello" : "非hello/未知"}；'
              'ID指纹=${classification.body?["id"] is String ? _discoveryIdTag(classification.body!["id"] as String) : "无"}；'
              '本机来源=${_localDiscoveryAddresses?.contains(sourceIp) ?? "未知"}');
          continue;
        }
        final body = classification.body!;
        _discoveryTrace?.onValidHello(
            _discoveryTraceClock?.elapsedMilliseconds ?? 0);
        _logFirstValidHelloDiagnostic(sourceIp, body);
        // Keep the pre-existing 128-character guard after the timing marker,
        // matching D4's established definition of a protocol-valid hello.
        final id = body['id'] as String;
        if (id.length > DiscoveryPacketClassifier.maxDeviceIdLength) {
          _packetJournal.result(receipt, reason: 'id_too_long',
            protocolCompatible: true, remoteHello: false, peerUpdate: 'filtered');
          _logUdpPacketDiagnostic(sourceIp, packet.data.length,
              '拒绝：设备 ID 超过 128 字符');
          continue;
        }
        final dismissedAt = _dismissedDiscoveredPeers[id];
        if (dismissedAt == sourceIp) {
          _packetJournal.result(receipt, reason: 'locally_hidden',
            protocolCompatible: true, remoteHello: true, peerUpdate: 'hidden');
          if (_dismissedUdpDiagnosticIdsLogged.add(id)) {
            _logUdpPacketDiagnostic(sourceIp, packet.data.length,
                '协议有效，但该设备条目被本机隐藏规则拦截');
          }
          continue;
        }
        if (dismissedAt != null) _dismissedDiscoveredPeers.remove(id);
        final existing = _peers[id];
        final wasStale = existing?.isStale ?? false;
        if (existing != null && existing.ip == sourceIp &&
            existing.port == body['port']) {
          // Update the existing entry, rather than constructing a new device
          // and making the UI selection appear to flicker on every hello.
          existing.seenAt = DateTime.now();
        } else {
          final rawName = body['name'] as String;
          _peers[id] = NearPeer(
            id: id,
            name: rawName.substring(0, min(rawName.length, 60)),
            ip: sourceIp,
            port: body['port'] as int,
          );
        }
        _staleLogged.remove(id);
        _packetJournal.result(receipt, reason: 'valid_hello',
          protocolCompatible: true, remoteHello: true,
          peerUpdate: existing == null ? 'added' :
            existing.ip == sourceIp && existing.port == body['port'] ? 'refreshed' : 'replaced');
        _packetJournal.awaitUi(id, receipt);
        if (wasStale) _log('重新发现：${body['name']}');
        if (existing == null) {
          if (_visibleDiagnosticCount++ < 4) {
            _log('D4C 远端进入设备列表：来源=$sourceIp；'
                'ID指纹=${_discoveryIdTag(id)}；运行'
                '${_discoveryTraceClock?.elapsedMilliseconds ?? 0}ms（尚未认证）');
          }
          _discoveryTrace?.onPeerVisible(
            _discoveryTraceClock?.elapsedMilliseconds ?? 0,
            via: DiscoveryTraceSource.udpHello,
          );
          _emitDiscoveryTrace('首次设备 UDP 广播');
        }
        if (existing == null && _firstDiscoveredPeerClock != null) {
          final elapsed = _firstDiscoveredPeerClock!.elapsedMilliseconds;
          _firstDiscoveredPeerClock!.stop();
          _firstDiscoveredPeerClock = null;
          _log('发现诊断：启动至首次发现 ${elapsed}ms（尚未认证）');
        }
        // The first packet might reach only one endpoint. A bounded direct
        // response lets the other endpoint learn about us immediately.
        // Never echo every recurring broadcast: that would cause a UDP storm.
        if ((existing == null || wasStale ||
                existing.ip != sourceIp) &&
            packet.port == discoveryPort &&
            _discoveryReplyThrottle.allow(sourceIp, DateTime.now())) {
          _replyHelloTo(sourceIp);
        }
        notifyListeners();
      } catch (error) {
        _packetJournal.result(receipt, reason: 'handler_exception',
          protocolCompatible: false, remoteHello: false,
          peerUpdate: 'exception', error: error.runtimeType.toString());
        // Keep malformed/foreign LAN traffic isolated from the service while
        // exposing a bounded, payload-free reason for the first few packets.
        _logUdpPacketDiagnostic(sourceIp, packet.data.length,
            '处理异常：${error.runtimeType}');
      }
    }
  }

  void addManualPeer(String ip) {
    if (!isValidIpv4(ip)) throw const FormatException('请输入有效的 IPv4 地址');
    final peerId = 'manual:$ip';
    _peers[peerId] = NearPeer(
      id: peerId,
      name: '手动连接 $ip',
      ip: ip,
      port: transferPort,
    );
    notifyListeners();
    if (_running) {
      _broadcastHello(); // Known address; do not wait for broadcast discovery.
      _scheduleManualHealthProbe();
    }
  }

  /// Removes a local device-list entry ONLY; never modifies signed trust,
  /// encryption keys, authenticated channels, chat history or remote devices.
  /// An online discovered peer may be removed only after an explicit failed
  /// reconnect attempt. It remains hidden until Refresh or process restart.
  bool removeDisplayedPeer({required String peerId, required String ip,
      bool allowFailedConnection = false}) {
    final peer = _peers[peerId];
    if (peer == null || peer.ip != ip) return false;
    if (!peer.isManual && !peer.isStale && !allowFailedConnection) return false;
    _peers.remove(peerId);
    _staleLogged.remove(peerId);
    if (!peer.isManual) _dismissedDiscoveredPeers[peerId] = ip;
    notifyListeners();
    return true;
  }

  Future<void> _respond(HttpRequest req, int status, Map<String, dynamic> json) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(json));
    await req.response.close();
  }

  Future<Map<String, dynamic>?> _readSmallJson(HttpRequest req) async {
    final bytes = <int>[];
    await for (final piece in req) {
      if (bytes.length + piece.length > 4096) return null;
      bytes.addAll(piece);
    }
    try {
      final obj = jsonDecode(utf8.decode(bytes));
      return obj is Map<String, dynamic> ? obj : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleHttp(HttpRequest req) async {
    // Public LAN reachability response. NOT authentication, not a trust signal.
    if (req.method == 'GET' && req.uri.path == '/health') {
      await _respond(req, HttpStatus.ok, {
        'protocol': protocolVersion,
        'id': deviceId,
        'name': deviceName, // Display-only metadata, never signed identity.
      });
      return;
    }
    if (req.method != 'POST') {
      await _respond(req, 405, {'error': 'method not allowed'});
      return;
    }
    // DEV9B disables EVERY legacy plaintext POST on the production app.
    // Discovery /health remains available for peer presence only.
    if (!allowLegacyFileTransfer) {
      await _respond(req, HttpStatus.forbidden,
          {'error': 'plaintext file transfer disabled; upgrade to DEV9B'});
      return;
    }
    if (req.uri.path == '/offer') {
      final data = await _readSmallJson(req);
      if (data == null ||
          data['name'] is! String ||
          data['size'] is! int ||
          data['hash'] is! String ||
          data['senderName'] is! String) {
        await _respond(req, 400, {'error': 'bad offer'});
        return;
      }
      final size = data['size'] as int;
      final hash = data['hash'] as String;
      if (size < 0 || size > maxFileBytes ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
          (data['name'] as String).length > 255 ||
          (data['senderName'] as String).length > 80) {
        await _respond(req, 413, {'error': 'invalid file or size'});
        return;
      }
      if (_accepted.length >= 4) {
        await _respond(req, 429, {'error': 'busy'});
        return;
      }
      final remoteIp = req.connectionInfo?.remoteAddress.address ?? '?';
      final offer = FileOffer(
        name: sanitizeFileName(data['name'] as String),
        size: size,
        senderName: data['senderName'] as String,
        remoteIp: remoteIp,
      );
      _log('收到文件请求：${offer.name}（${offer.senderName}）');
      bool allow = false;
      try {
        allow = await (askReceiver?.call(offer) ?? Future.value(false))
            .timeout(const Duration(seconds: 90), onTimeout: () => false);
      } catch (_) {}
      if (!allow) {
        _log('已拒绝：${offer.name}');
        await _respond(req, 403, {'error': 'receiver declined'});
        return;
      }
      final token = randomHex(24);
      _accepted[token] = _AcceptedOffer(
        name: offer.name,
        size: offer.size,
        hash: hash,
        ip: remoteIp,
      );
      await _respond(req, 200, {'token': token});
      return;
    }
    if (req.uri.pathSegments.length == 2 &&
        req.uri.pathSegments.first == 'upload') {
      final token = req.uri.pathSegments.last;
      final offer = _accepted.remove(token); // One-time token; no replay.
      if (offer == null ||
          offer.ip != req.connectionInfo?.remoteAddress.address ||
          DateTime.now().isAfter(offer.expiresAt)) {
        await _respond(req, 403, {'error': 'expired or wrong sender'});
        return;
      }
      if (req.contentLength != offer.size) {
        await _respond(req, 400, {'error': 'file length mismatch'});
        return;
      }
      final root = Directory('${(await getApplicationDocumentsDirectory()).path}'
          '${Platform.pathSeparator}NearLinkReceived');
      await root.create(recursive: true);
      final target = await _uniqueTarget(root, offer.name);
      final temp = File('${target.path}.part.${randomHex(4)}');
      var written = 0;
      try {
        final sink = temp.openWrite();
        try {
          await for (final chunk in req) {
            written += chunk.length;
            if (written > offer.size) throw const FormatException('exceeds limit');
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (written != offer.size) throw const FormatException('truncated file');
        final digest = (await sha256.bind(temp.openRead()).first).toString();
        if (digest != offer.hash) throw const FormatException('SHA-256 mismatch');
        await temp.rename(target.path);
        _log('接收成功：${offer.name}');
        receivedFile?.call(target);
        await _respond(req, 200, {'ok': true, 'savedAs': target.uri.pathSegments.last});
      } catch (e) {
        if (await temp.exists()) await temp.delete();
        _log('接收失败：$e');
        await _respond(req, 400, {'error': 'file incomplete or checksum failed'});
      }
      return;
    }
    await _respond(req, 404, {'error': 'unknown endpoint'});
  }

  Future<File> _uniqueTarget(Directory directory, String name) async {
    final clean = sanitizeFileName(name);
    var dest = File('${directory.path}${Platform.pathSeparator}$clean');
    final dot = clean.lastIndexOf('.');
    final stem = dot > 0 ? clean.substring(0, dot) : clean;
    final ext = dot > 0 ? clean.substring(dot) : '';
    var i = 1;
    while (await dest.exists()) {
      dest = File('${directory.path}${Platform.pathSeparator}${stem}_$i$ext');
      i++;
    }
    return dest;
  }

  Future<String> sendFile(NearPeer peer, PlatformFile file) async {
    if (!allowLegacyFileTransfer) {
      throw StateError('plaintext transfers disabled in DEV9B');
    }
    final size = file.lengthSync() ?? await file.length();
    if (size == null) throw StateError('无法读取文件大小');
    if (size > maxFileBytes) throw StateError('v0.1 单文件限制 20MB');
    if (size < 0) throw StateError('文件大小异常');
    _log('计算 SHA-256：${file.name}');
    final digest = (await sha256.bind(file.readAsByteStream()).first).toString();
    final base = Uri(scheme: 'http', host: peer.ip, port: peer.port);
    final offerReq = await _client.postUrl(base.replace(path: '/offer'));
    offerReq.headers.contentType = ContentType.json;
    offerReq.write(jsonEncode({
      'name': sanitizeFileName(file.name),
      'size': size,
      'hash': digest,
      'senderName': deviceName,
    }));
    _log('等待 ${peer.name} 确认接收');
    final offerRes = await offerReq.close().timeout(const Duration(seconds: 100));
    final answer = await offerRes.transform(utf8.decoder).join();
    if (offerRes.statusCode != 200) throw StateError('对方未接受：$answer');
    final json = jsonDecode(answer) as Map<String, dynamic>;
    final token = json['token'];
    if (token is! String) throw const FormatException('缺少传输授权');

    final upload = await _client.postUrl(base.replace(path: '/upload/$token'));
    upload.contentLength = size;
    upload.headers.contentType = ContentType.binary;
    await upload.addStream(file.readAsByteStream());
    final response = await upload.close().timeout(const Duration(seconds: 120));
    final result = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) throw StateError('发送失败：$result');
    _log('发送成功：${file.name} → ${peer.name}');
    return result;
  }

  Future<void> stop() async {
    final previous = _lifecycleOperation;
    final operation = () async {
      await previous;
      await _stopService();
    }();
    _lifecycleOperation = operation.then<void>((_) {},
        onError: (Object error, StackTrace stack) {});
    await operation;
  }

  Future<void> _stopService() async {
    _packetJournal.summary('stop');
    _packetJournal.event('stop', {'listening_before_close': _running});
    _running = false;
    _announceTimer?.cancel();
    for (final timer in _warmupTimers) { timer.cancel(); }
    _warmupTimers.clear();
    for (final timer in _discoveryTraceTimers) { timer.cancel(); }
    _discoveryTraceTimers.clear();
    _discoveryTraceClock?.stop();
    _discoveryTraceClock = null;
    _discoveryTrace = null;
    _firstDiscoveredPeerClock?.stop();
    _firstDiscoveredPeerClock = null;
    _discoveryReplyThrottle.clear();
    _peerTimer?.cancel();
    _probeTimer?.cancel();
    _manualProbeKick?.cancel();
    _manualProbeKick = null;
    _alreadyProbedManualIps.clear();
    _packetJournal.event('socket_close_requested', {'via': 'stop',
      'socket_present': _udp != null, 'socket_run': _packetJournal.run,
      'listener_cancel': 'no_explicit_cancel_stream_owned_by_socket'});
    _udp?.close();
    _udp = null;
    await _httpServer?.close(force: true);
    _httpServer = null;
    _client.close(force: true);
    _peers.clear();
    _staleLogged.clear();
    _dismissedDiscoveredPeers.clear();
    _accepted.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _packetJournal.summary('dispose');
    _disposed = true;
    _running = false;
    _announceTimer?.cancel();
    for (final timer in _warmupTimers) { timer.cancel(); }
    _warmupTimers.clear();
    for (final timer in _discoveryTraceTimers) { timer.cancel(); }
    _discoveryTraceTimers.clear();
    _discoveryTraceClock?.stop();
    _discoveryTraceClock = null;
    _discoveryTrace = null;
    _firstDiscoveredPeerClock?.stop();
    _firstDiscoveredPeerClock = null;
    _discoveryReplyThrottle.clear();
    _peerTimer?.cancel();
    _probeTimer?.cancel();
    _manualProbeKick?.cancel();
    _packetJournal.event('socket_close_requested', {'via': 'dispose',
      'socket_present': _udp != null, 'socket_run': _packetJournal.run,
      'listener_cancel': 'no_explicit_cancel_stream_owned_by_socket'});
    _udp?.close();
    _httpServer?.close(force: true);
    _running = false;
    _client.close(force: true);
    super.dispose();
  }
}
