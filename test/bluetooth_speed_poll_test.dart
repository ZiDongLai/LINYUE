import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';
import 'package:nearlink/bluetooth/bluetooth_transport.dart';
import 'package:nearlink/services/disk_capacity_guard.dart';

import 'bluetooth_e32_test.dart' as e32;
import 'bluetooth_e30_test.dart' show until;
import 'bluetooth_poc_test.dart' as b1;

// The native bridges drain their receive buffers on each poll. This double
// keeps the same byte-stream boundary while avoiding an artificial 37-byte
// fragmentation cost in the polling comparison.
class _DrainNative extends e32.CapacityNative {
  int polls = 0;

  @override
  Future<T?> invoke<T>(String method, [Map<String, dynamic>? args]) async {
    if (method == 'poll') {
      polls++;
      final bytes = Uint8List.fromList(buffer);
      buffer.clear();
      return <String, dynamic>{
            'generation': generation,
            'state': state,
            'bytes': bytes,
            'error': 'peer disconnected',
            'peerId': '112233445566',
          }
          as T;
    }
    return super.invoke<T>(method, args);
  }
}

Future<int> _transferWithPoll(Duration filePollInterval) async {
  final ia = await b1.identity(), ib = await b1.identity();
  await b1.trust(ia, ib);
  await b1.trust(ib, ia);
  final na = _DrainNative(), nb = _DrainNative();
  na.other = nb;
  nb.other = na;
  final dir = await Directory.systemTemp.createTemp('bluetooth_poll_speed_');
  final inbox = await Directory('${dir.path}/inbox').create();
  final a = BluetoothTransport(
    identity: ia,
    server: false,
    native: na,
    textEnabled: true,
    filesEnabled: true,
    pollInterval: const Duration(milliseconds: 100),
    filePollInterval: filePollInterval,
  );
  final b = BluetoothTransport(
    identity: ib,
    server: true,
    native: nb,
    textEnabled: true,
    filesEnabled: true,
    pollInterval: const Duration(milliseconds: 100),
    filePollInterval: filePollInterval,
  );
  a.onText = (_, _) async {};
  b.onText = (_, _) async {};
  b.approveFile = (_) async => true;
  b.onFileReceived = (_, _) async {};
  b.fileStore = BluetoothFileStore(
    inbox: inbox,
    work: Directory('${dir.path}/work'),
    diskGuard: DiskCapacityGuard(lookup: (_) async => 100000000),
    commit: (temp, offer) => temp.rename('${inbox.path}/${offer.name}'),
  );
  try {
    await b.start(expectedFingerprint: ia.local.fingerprint);
    await a.start(
      expectedFingerprint: ib.local.fingerprint,
      deviceId: '112233445566',
    );
    try {
      await until(() => a.fileReady && b.fileReady);
    } catch (_) {
      debugPrint(
        'client state=${a.state} error=${a.lastError} events=${a.events}',
      );
      debugPrint(
        'server state=${b.state} error=${b.lastError} events=${b.events}',
      );
      rethrow;
    }
    final original = List<int>.generate(32768, (i) => i % 251);
    final source = await File('${dir.path}/source.bin').writeAsBytes(original);
    final clock = Stopwatch()..start();
    final receipt = await a.sendFile(source);
    clock.stop();
    expect(receipt.size, original.length);
    expect(await File('${inbox.path}/source.bin').readAsBytes(), original);
    expect(na.peak, lessThanOrEqualTo(16384));
    expect(nb.peak, lessThanOrEqualTo(16384));
    for (final transport in [a, b]) {
      final pipeline = transport.events.singleWhere(
        (line) => line.contains('BT pipeline direction='),
      );
      expect(pipeline, contains('valid=true'));
      for (final field in [
        'encryptUs',
        'decryptUs',
        'nativePollCalls',
        'nativeWriteUs',
        'capacityUs',
      ]) {
        final match = RegExp('$field=([0-9]+)').firstMatch(pipeline);
        expect(match, isNotNull, reason: pipeline);
        expect(int.parse(match!.group(1)!), greaterThan(0), reason: pipeline);
      }
      expect(
        int.parse(
          RegExp('decryptFrames=([0-9]+)').firstMatch(pipeline)!.group(1)!,
        ),
        greaterThanOrEqualTo(8),
      );
      debugPrint(pipeline);
    }
    expect(
      a.events.any(
        (line) =>
            line.contains('BT file timing direction=send') &&
            line.contains('result=final-receipt-verified') &&
            line.contains('chunks=8'),
      ),
      isTrue,
    );
    expect(
      b.events.any(
        (line) =>
            line.contains('BT file timing direction=receive') &&
            line.contains('result=final-ack-enqueued') &&
            line.contains('chunks=8'),
      ),
      isTrue,
    );
    debugPrint(
      'SIMULATED native poll fileDelayMs=${filePollInterval.inMilliseconds} '
      'elapsedMs=${clock.elapsedMilliseconds} polls=${na.polls + nb.polls} '
      'bytes=${original.length}',
    );
    final idlePolls = na.polls + nb.polls;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(na.polls + nb.polls - idlePolls, lessThanOrEqualTo(6));
    return clock.elapsedMilliseconds;
  } finally {
    await a.disconnect();
    await b.disconnect();
    a.dispose();
    b.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await dir.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native age ticks keep fresh diagnostics without rebuilding workbench',
    () async {
      final transport = BluetoothTransport(
        identity: await b1.identity(),
        server: false,
      );
      addTearDown(transport.dispose);
      var notifications = 0;
      transport.addListener(() => notifications++);
      final state = <String, dynamic>{
        'platform': 'windows',
        'phase': 'connected',
        'radioSnapshotAgeMs': 1,
      };
      transport.captureNativeDiagnostics(state);
      expect(notifications, 1);
      for (var age = 2; age <= 100; age++) {
        transport.captureNativeDiagnostics({
          ...state,
          'radioSnapshotAgeMs': age,
        });
      }
      expect(notifications, 1);
      expect(transport.nativeDiagnostics, contains('radioSnapshotAgeMs=100'));
      transport.captureNativeDiagnostics({...state, 'phase': 'idle'});
      expect(notifications, 2);
      transport.captureNativeDiagnostics({
        ...state,
        'phase': 'idle',
        'permission': false,
      });
      expect(notifications, 3);
      transport.captureNativeDiagnostics({
        ...state,
        'phase': 'idle',
        'permission': false,
        'radioSnapshotAgeMs': 200,
      }, notifyAgeOnly: true);
      expect(notifications, 4);
      expect(transport.nativeDiagnostics, contains('radioSnapshotAgeMs=200'));
    },
  );

  test(
    'file polling keeps full encrypted file receipt and idle rate',
    () async {
      final oldMs = await _transferWithPoll(const Duration(milliseconds: 100));
      final candidateMs = await _transferWithPoll(
        const Duration(milliseconds: 20),
      );
      expect(oldMs, greaterThan(0));
      expect(candidateMs, greaterThan(0));
    },
  );
}
