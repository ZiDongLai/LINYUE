import 'dart:io';
import 'bluetooth_file_lane.dart';
import 'bluetooth_file_store.dart';
import 'bluetooth_bounded_writer.dart';
import 'dart:async';
import 'package:crypto/crypto.dart' as hashes;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../security/device_identity.dart';
import 'bluetooth_protocol.dart';
import 'bluetooth_association.dart';
import '../services/conversation_text_protocol.dart';
import 'bluetooth_native_diagnostics.dart';
import 'bluetooth_peer_catalog.dart' show canonicalBluetoothAddress;

abstract interface class BluetoothNative {
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? arguments]);
}

class MethodChannelBluetoothNative implements BluetoothNative {
  static const _channel = MethodChannel('nearlink/bluetooth_poc');
  @override
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? arguments]) {
    if (!kDebugMode) throw StateError('Bluetooth PoC is debug-only');
    return _channel.invokeMethod<T>(method, arguments);
  }
}

/// One native connection, one decoder, one fresh authenticated session.
/// Native generation + local epoch reject late data after cancellation/restart.
class BluetoothTransport extends ChangeNotifier {
  BluetoothTransport({
    required this.identity,
    required this.server,
    bool? androidPlatform,
    BluetoothNative? native,
    this.textEnabled = false,
    this.filesEnabled = false,
    this.reverseFilesEnabled = false,
    this.pollInterval = const Duration(milliseconds: 100),
    this.filePollInterval = const Duration(milliseconds: 20),
    this.connectionTimeout = const Duration(seconds: 25),
  }) : android = androidPlatform ?? server,
       native = native ?? MethodChannelBluetoothNative();
  final DeviceIdentityManager identity;
  final bool android;
  bool server;
  bool get _defaultServerRole => android;
  final bool textEnabled, filesEnabled, reverseFilesEnabled;
  BluetoothFileStore? fileStore;
  Future<bool> Function(BluetoothFileOffer)? approveFile;
  Future<void> Function(BluetoothFileOffer, File)? onFileReceived;
  BluetoothFileProgress? fileProgress;
  BluetoothBoundedWriter? _writer;
  bool get fileReady => authenticated && (_session?.fileReady ?? false);
  bool get fileSendReady => authenticated && (_session?.fileSendReady ?? false);
  bool get fileReceiveReady =>
      authenticated && (_session?.fileReceiveReady ?? false);
  Future<BluetoothFileOffer> sendFile(File file, {String? name}) async {
    if (!fileSendReady) throw StateError('蓝牙文件通道未就绪；没有LAN回退');
    final clock = Stopwatch()..start();
    _sendPipelineBaseline = _pipelineCounters();
    try {
      final offer = await _session!.sendFile(file, name: name);
      _fileMeasurement(
        'send',
        offer,
        clock.elapsedMicroseconds,
        'final-receipt-verified',
      );
      return offer;
    } catch (e) {
      _event(
        'BT measurement direction=send status=failed elapsedUs=${clock.elapsedMicroseconds} type=${e.runtimeType}; no success receipt',
      );
      rethrow;
    }
  }

  Stopwatch? _receiveFileClock;
  Map<String, int>? _sendPipelineBaseline, _receivePipelineBaseline;
  int _nativePollUs = 0, _nativePollCalls = 0, _nativeWriteUs = 0;
  int _capacityUs = 0, _timerLateUs = 0, _timerMaxLateUs = 0;
  int _listenerUs = 0;
  Map<String, int> _pipelineCounters() => {
    ...?_session?.performanceCounters,
    'nativePollUs': _nativePollUs,
    'nativePollCalls': _nativePollCalls,
    'nativeWriteUs': _nativeWriteUs,
    'capacityUs': _capacityUs,
    'timerLateUs': _timerLateUs,
    'listenerUs': _listenerUs,
    'epoch': _epoch,
  };

  Future<T?> _timedNative<T>(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    final timer = Stopwatch()..start();
    try {
      return await native.invoke<T>(method, args);
    } finally {
      final us = timer.elapsedMicroseconds;
      if (method == 'poll') {
        _nativePollUs += us;
        _nativePollCalls++;
      }
      if (method == 'write') _nativeWriteUs += us;
      if (method == 'writeCapacity') _capacityUs += us;
    }
  }

  void _fileMeasurement(
    String direction,
    BluetoothFileOffer offer,
    int elapsed,
    String result,
  ) {
    final baseline = direction == 'send'
        ? _sendPipelineBaseline
        : _receivePipelineBaseline;
    final current = _pipelineCounters();
    final valid =
        baseline != null && baseline['epoch'] == _epoch && _session != null;
    _event(
      'BT pipeline direction=$direction id=${offer.id.substring(0, 8)} '
      'valid=$valid ${valid ? current.entries.where((e) => e.key != 'epoch').map((e) => '${e.key}=${e.value - (baseline[e.key] ?? 0)}').join(' ') : 'session-changed'} '
      'timerLifetimeMaxLateUs=$_timerMaxLateUs',
    );
    int? rss, maxRss;
    try {
      rss = ProcessInfo.currentRss;
      maxRss = ProcessInfo.maxRss;
    } catch (_) {
      /* Unsupported probe remains unknown. */
    }
    _event(
      'BT measurement direction=$direction id=${offer.id} bytes=${offer.size} sha256=${offer.sha256} '
      'elapsedUs=$elapsed payloadBytesPerSec=${elapsed > 0 ? (offer.size * 1000000 / elapsed).toStringAsFixed(1) : "unknown"} '
      'rssBytes=${rss ?? "unknown"} processLifetimeMaxRssBytes=${maxRss ?? "unknown"} '
      'dartWriterPeakBytes=${_writer?.peakBytes ?? 0} backpressurePolls=${_writer?.backpressurePolls ?? 0} '
      'backpressureUs=${_writer?.backpressureMicros ?? 0} negotiatedMax=$maxFileBytes result=$result',
    );
  }

  bool get hasUnconfirmedFile => _session?.hasUnconfirmedFile ?? false;
  int get maxFileBytes => _session?.maxFileBytes ?? bluetoothFileMaxBytes;
  Future<BluetoothFileOffer> confirmFileResult() async {
    if (!fileSendReady) throw StateError('蓝牙会话已关闭，文件结果仍未确认');
    return _session!.confirmFileResult();
  }

  Future<void> _writeFrame(Uint8List bytes, int epoch) async {
    if (epoch != _epoch || _disposed) {
      throw StateError('Bluetooth write cancelled');
    }
    if (!filesEnabled) {
      await _timedNative<void>('write', {
        'generation': _generation,
        'bytes': bytes,
      });
      return;
    }
    final writer = _writer ??= BluetoothBoundedWriter(
      capacity: () async {
        final packet = await _timedNative<Map>('writeCapacity');
        if (epoch != _epoch ||
            _disposed ||
            packet?['generation'] != _generation ||
            packet?['queuedBytes'] is! int) {
          throw StateError('Bluetooth native byte capacity unavailable/stale');
        }
        return BluetoothBoundedWriter.byteLimit -
            (packet!['queuedBytes'] as int);
      },
      write: (frame) async {
        if (epoch != _epoch || _disposed) {
          throw StateError('Bluetooth write cancelled');
        }
        await _timedNative<void>('write', {
          'generation': _generation,
          'bytes': frame,
        });
      },
    );
    await writer.add(bytes);
  }

  Future<void> Function(String fingerprint, TextChatMessage message)? onText;
  bool Function()? canReceiveText;
  BluetoothAssociation? _association;
  String peerFingerprint = '', peerName = '', localName = '';
  String get comparisonCode => _association?.comparisonCode ?? '';
  bool get confirmationRequired => _association?.needsConfirmation ?? false;
  bool get textReady => authenticated && (_session?.textReady ?? false);
  Future<void> confirmAssociation(bool accepted) async {
    try {
      await _association?.confirm(accepted);
    } catch (e) {
      await disconnect(reason: 'Association confirmation failed: $e');
    }
  }

  Future<void> sendText(TextChatMessage message) async {
    if (!textEnabled || !textReady) {
      throw StateError(
        'Bluetooth text disconnected or not ready; no LAN fallback',
      );
    }
    await _session!.sendText(message);
    _event('Bluetooth text peer ACK verified; id=${message.id}');
  }

  final BluetoothNative native;
  final Duration pollInterval, filePollInterval, connectionTimeout;
  String state = 'idle', authState = '未认证', lastError = '';
  // B3 native endpoint metadata only; never used as a cryptographic identity.
  String? connectedDeviceId;
  final List<Uint8List> receivedTests = [];
  final List<String> events = [];
  String nativeDiagnostics = '';
  final _clock = Stopwatch()..start();
  BluetoothSecureSession? _session;
  BluetoothFrameDecoder _decoder = BluetoothFrameDecoder();
  Timer? _timer, _connectDeadline;
  int _epoch = 0;
  int? _generation;
  bool _polling = false, _starting = false, _disposed = false;
  bool _stopping = false;
  Future<void>? _disconnecting;
  Future<void> _controlTail = Future<void>.value();
  bool get authenticated => _session?.authenticated ?? false;
  bool get active =>
      _starting ||
      state == 'connecting' ||
      state == 'listening' ||
      state == 'connected';

  void _event(String message) {
    if (_disposed) return;
    events.add('${_clock.elapsedMilliseconds}ms $message');
    if (events.length > 80) events.removeAt(0);
    final clock = Stopwatch()..start();
    notifyListeners();
    _listenerUs += clock.elapsedMicroseconds;
  }

  Future<void> _control(Future<void> Function() action) {
    final operation = _controlTail.then((_) => action());
    _controlTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<Map<dynamic, dynamic>> status() async =>
      await native.invoke<Map<dynamic, dynamic>>('status') ?? {};
  Future<void> requestPermission() => native.invoke<void>('permission');

  String _nativeDiagnosticState = '';
  void captureNativeDiagnostics(Object? raw, {bool notifyAgeOnly = false}) {
    final formatted = formatBluetoothNativeDiagnostics(raw);
    if (formatted.isEmpty || formatted == nativeDiagnostics || _disposed) {
      return;
    }
    nativeDiagnostics = formatted;
    // The age is refreshed for copying, but its clock ticks do not change
    // connection state and must not rebuild the entire workbench on every poll.
    final state = formatted
        .split('\n')
        .where((line) => !line.startsWith('radioSnapshotAgeMs='))
        .join('\n');
    if (state != _nativeDiagnosticState || notifyAgeOnly) {
      _nativeDiagnosticState = state;
      final clock = Stopwatch()..start();
      notifyListeners();
      _listenerUs += clock.elapsedMicroseconds;
    }
  }

  Future<void> refreshNativeDiagnostics() async {
    try {
      captureNativeDiagnostics(
        await native.invoke<Map>('diagnostics'),
        notifyAgeOnly: true,
      );
    } catch (_) {
      // A diagnostic read must never close/authorize/reconnect a transport.
      _event(
        'native diagnostic refresh unavailable; previous evidence retained',
      );
    }
  }

  Future<void> start({
    required String expectedFingerprint,
    String? deviceId,
    bool? serverRole,
  }) {
    // Reserve synchronously, before the first platform await.
    if (_disposed || active) {
      throw StateError('Bluetooth operation already active/disposed');
    }
    final role = serverRole ?? server;
    final target = role ? null : canonicalBluetoothAddress(deviceId);
    if (!role && target == null) {
      throw StateError(
        'Target device ID missing or invalid before native start',
      );
    }
    _starting = true;
    server = role;
    final epoch = ++_epoch; // Reserve before queueing so immediate cancel wins.
    return _control(() async {
      try {
        if (_disposed || epoch != _epoch) return;
        await native.invoke<void>('stop', {'reason': 'transport-before-start'});
        if (_disposed || epoch != _epoch) return;
        _writer?.close();
        _writer = null;
        fileProgress = null;
        _decoder = BluetoothFrameDecoder(
          maxBody: filesEnabled ? 16380 : bluetoothMaxFrame,
        );
        receivedTests.clear();
        lastError = '';
        peerFingerprint = '';
        peerName = '';
        _association = null;
        authState = '未认证';
        state = 'connecting';
        connectedDeviceId = null;
        _generation = await native.invoke<int>(
          role ? 'start' : 'connect',
          role ? null : {'id': target},
        );
        if (_disposed || epoch != _epoch) {
          if (_disconnecting == null) {
            await native.invoke<void>('stop', {
              'reason': 'transport-stale-start',
            });
          }
          return;
        }
        if (_generation == null) {
          throw StateError('No native connection generation');
        }
        _event(
          'RFCOMM ${role ? 'server registration requested' : 'client connecting'}; UUID=$bluetoothServiceUuid',
        );
        if (!server) {
          _connectDeadline = Timer(connectionTimeout, () {
            if (epoch == _epoch && state != 'connected') {
              unawaited(disconnect(reason: 'RFCOMM connection timeout'));
            }
          });
        }
        _schedulePoll(epoch, expectedFingerprint);
      } catch (e) {
        if (!_disposed && epoch == _epoch) {
          await refreshNativeDiagnostics(); // Capture failed preconditions before cleanup.
          await _stop('Native start failed: $e');
        }
        rethrow;
      } finally {
        _starting = false;
      }
    });
  }

  void _schedulePoll(int epoch, String expected) {
    if (_disposed || epoch != _epoch || _stopping) return;
    final phase = fileProgress?.phase ?? '';
    final fileInFlight =
        fileProgress != null &&
        !phase.startsWith('成功') &&
        !phase.startsWith('失败');
    final delay = fileInFlight && filePollInterval < pollInterval
        ? filePollInterval
        : pollInterval;
    final due = _clock.elapsedMicroseconds + delay.inMicroseconds;
    _timer = Timer(delay, () {
      final late = (_clock.elapsedMicroseconds - due).clamp(0, 1 << 62);
      _timerLateUs += late;
      if (late > _timerMaxLateUs) _timerMaxLateUs = late;
      unawaited(_poll(epoch, expected));
    });
  }

  Future<void> _poll(int epoch, String expected) async {
    if (_polling || _disposed || epoch != _epoch) return;
    _polling = true;
    try {
      final packet = await _timedNative<Map<dynamic, dynamic>>('poll');
      if (_disposed || epoch != _epoch) return;
      if (packet == null || packet['generation'] != _generation) {
        throw StateError('Stale native generation');
      }
      captureNativeDiagnostics(packet['diagnostics']);
      final remoteState = packet['state'];
      connectedDeviceId = packet['peerId'] is String
          ? packet['peerId'] as String
          : null;
      if (remoteState != 'connected' &&
          remoteState != 'listening' &&
          remoteState != 'connecting') {
        _decoder.finish();
        throw StateError('Native disconnect: ${packet['error']}');
      }
      if (state != remoteState) {
        state = remoteState as String;
        _event('native RFCOMM state=$state; generation=$_generation');
      }
      if (remoteState == 'connected' &&
          _session == null &&
          _association == null) {
        state = 'connected';
        _connectDeadline?.cancel();
        if (textEnabled) {
          final association = BluetoothAssociation(
            server: server,
            identity: identity,
            localName: localName.isEmpty
                ? (android ? 'Android · 邻跃' : 'Windows · 邻跃')
                : localName,
            expectedFingerprint: expected.isEmpty ? null : expected,
            write: (bytes) async {
              if (epoch != _epoch || _disposed) {
                throw StateError('Association cancelled');
              }
              await _writeFrame(bytes, epoch);
            },
            onState: (value) {
              if (epoch != _epoch || _disposed || _stopping) return;
              authState = 'association: $value';
              _event('association: $value');
              if (value.startsWith('error:')) {
                unawaited(disconnect(reason: value));
              }
            },
            onComplete: (fingerprint, name) async {
              if (epoch != _epoch || _disposed) return;
              peerName = name;
              await _startSecureSession(epoch, fingerprint);
            },
          );
          _association = association;
          await association.start();
        } else {
          await _startSecureSession(epoch, expected);
        }
      }
      if (epoch != _epoch || _disposed) return;
      final raw = packet['bytes'];
      if (raw is! Uint8List) throw StateError('Invalid native receive payload');
      if (raw.isNotEmpty) {
        if (_session == null && _association == null) {
          throw StateError('Bytes before connected state');
        }
        for (final message in _decoder.add(raw)) {
          if (epoch != _epoch) return;
          if (_association != null && !_association!.complete) {
            await _association!.receive(message);
          } else {
            await _session!.receive(message);
          }
        }
      }
    } catch (e) {
      if (epoch == _epoch && !_disposed) {
        await disconnect(reason: 'Receive failed: $e');
      }
    } finally {
      _polling = false;
      _schedulePoll(epoch, expected);
    }
  }

  Future<void> _startSecureSession(int epoch, String expected) async {
    if (epoch != _epoch || _disposed) return;
    peerFingerprint = expected;
    final session = BluetoothSecureSession(
      server: server,
      identity: identity,
      expectedFingerprint: expected,
      write: (bytes) async {
        if (epoch != _epoch || _disposed) {
          throw StateError('Connection cancelled');
        }
        await _writeFrame(bytes, epoch);
      },
      onState: (value) {
        if (epoch != _epoch || _disposed || _stopping) return;
        authState = value;
        _event('authentication: $value');
        if (value.startsWith('error:')) {
          unawaited(disconnect(reason: value));
        }
      },
      filesEnabled: filesEnabled,
      reverseFilesEnabled: reverseFilesEnabled,
      onFileDiagnostic: _event,
      fileStore: fileStore,
      approveFile: approveFile,
      onFileReceived: (offer, file) async {
        if (epoch != _epoch ||
            _disposed ||
            !authenticated ||
            peerFingerprint != expected) {
          throw StateError('Bluetooth file authenticated identity changed');
        }
        final handler = onFileReceived;
        if (handler == null) {
          throw StateError('Bluetooth file history unavailable');
        }
        await handler(offer, file);
        if (epoch != _epoch ||
            _disposed ||
            !authenticated ||
            peerFingerprint != expected) {
          throw StateError('Bluetooth file session changed before receipt');
        }
      },
      onFileProgress: (p) {
        if (epoch != _epoch || _disposed || _stopping) return;
        if (p.receiving && fileProgress?.offer.id != p.offer.id) {
          _receiveFileClock = Stopwatch()..start();
          _receivePipelineBaseline = _pipelineCounters();
        }
        fileProgress = p;
        _event(
          'BT file id=${p.offer.id} phase=${p.phase} bytes=${p.bytes}/${p.offer.size} sha256=${p.offer.sha256} ${p.error}',
        );
        if (p.receiving &&
            (p.phase.startsWith('成功') || p.phase.startsWith('失败'))) {
          _fileMeasurement(
            'receive',
            p.offer,
            _receiveFileClock?.elapsedMicroseconds ?? 0,
            p.phase.startsWith('成功')
                ? 'file-history-verified-ack-enqueued'
                : 'failed-or-unknown',
          );
        }
      },
      onText: textEnabled && onText != null && (canReceiveText?.call() ?? true)
          ? (message) async {
              if (epoch != _epoch || _disposed || !authenticated) {
                throw StateError('Disconnected Bluetooth text receiver');
              }
              final handler = onText;
              if (handler == null) {
                throw StateError('Bluetooth chat history unavailable');
              }
              await handler(expected, message);
            }
          : null,
      onTest: (bytes) {
        if (epoch != _epoch || _disposed) {
          throw StateError('Connection cancelled');
        }
        receivedTests.add(Uint8List.fromList(bytes));
        if (receivedTests.length > 8) receivedTests.removeAt(0);
        _event(
          'authenticated test received: ${bytes.length} bytes SHA256=${hashes.sha256.convert(bytes)}',
        );
      },
    );
    _session = session;
    _event('RFCOMM connected; application authentication begins');
    await session.start();
  }

  Future<void> sendTest(List<int> bytes) async {
    final session = _session;
    if (session == null) throw StateError('No authenticated connection');
    await session.sendTest(bytes);
    _event(
      'peer ACK verified: ${bytes.length} bytes SHA256=${hashes.sha256.convert(bytes)}',
    );
  }

  Future<void> disconnect({String? reason}) {
    final pending = _disconnecting;
    if (pending != null) return pending;
    ++_epoch; // Invalidate in-flight awaits immediately, not after queued stop.
    final operation = _control(() => _stop(reason));
    final completed = operation.whenComplete(() => _disconnecting = null);
    _disconnecting = completed;
    return completed;
  }

  Future<void> _stop(String? reason) async {
    final pendingFile = fileProgress;
    if (pendingFile != null &&
        !pendingFile.phase.startsWith('成功') &&
        !pendingFile.phase.startsWith('失败')) {
      fileProgress = BluetoothFileProgress(
        pendingFile.offer,
        pendingFile.receiving,
        pendingFile.bytes,
        '失败 · 蓝牙断开，未确认完成',
        reason ?? '用户断开',
      );
    }
    _stopping = true;
    _writer?.close();
    _writer = null;
    _timer?.cancel();
    _connectDeadline?.cancel();
    _association?.close(reason);
    _association = null;
    _session?.close(reason);
    _session = null;
    _decoder.reset();
    state = reason == null ? 'idle' : 'error';
    authState = '未认证';
    if (reason != null) lastError = reason;
    try {
      await native.invoke<void>('stop', {
        'reason': reason == null
            ? 'transport-disconnect'
            : 'transport-failure-cleanup',
      });
    } catch (e) {
      lastError = 'Native stop failed: $e';
    }
    _generation = null;
    connectedDeviceId = null;
    server = _defaultServerRole;
    _stopping = false;
    _event(reason ?? 'RFCOMM stopped; pending frames cleared');
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect());
    super.dispose();
  }
}
