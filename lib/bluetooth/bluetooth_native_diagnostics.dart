import 'bluetooth_protocol.dart';

/// Bounded public native state only. Never serialize an arbitrary platform map,
/// received payload, full identity card, private key or native argument list.
String formatBluetoothNativeDiagnostics(Object? raw) {
  if (raw is! Map) return '';
  const fields = [
    'platform',
    'fileCommitStage',
    'fileCommitOperation',
    'fileCommitResult',
    'fileCommitException',
    'fileCommitErrno',
    'fileCommitStorage',
    'fileCommitSourceTag',
    'fileCommitTargetTag',
    'fileCommitDirectoryExists',
    'fileCommitDirectoryWritable',
    'fileCommitSameFilesystem',
    'fileCommitExpectedBytes',
    'fileCommitFinalBytes',
    'fileCommitTemporaryHashVerified',
    'fileCommitFinalHashVerified',
    'fileCommitTransferId',

    'nativeGeneration',
    'phase',
    'lastNativeCall',
    'nativeAttempt',
    'preflightStage',
    'preflightError',
    'targetPresent',
    'targetValid',
    'targetInputLength',
    'targetValueKind',
    'targetIdentityKind',
    'targetSuffix',
    'targetPairedMatches',
    'targetEnumerationError',
    'adapterState',
    'adapterWin32Error',
    'adapterInfoError',
    'winsockError',
    'radioQueryStatus',
    'radioPowerState',
    'radioSnapshotAgeMs',
    'radioStateValues',
    'radioCount',
    'radioHresult',
    'serviceUuid',
    'serviceName',
    'permission',
    'sdk',
    'osRelease',
    'manufacturer',
    'model',
    'listenerOpen',
    'registrationReturned',
    'acceptEntered',
    'connected',
    'queryMethod',
    'queryStage',
    'serviceOutcome',
    'resultCount',
    'requestedSuffix',
    'resolvedSuffix',
    'access',
    'bluetoothError',
    'hresult',
    'selectedUuid',
    'selectedChannel',
    'elapsedMs',
  ];
  String bounded(Object value, int max) {
    final text = '$value'.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');
    return text.length > max ? '${text.substring(0, max)}…' : text;
  }

  final lines = <String>['本地协议UUID=$bluetoothServiceUuid'];
  if (raw['serviceUuid'] is String) {
    lines.add(
      raw['serviceUuid'] == bluetoothServiceUuid
          ? '原生UUID与本地协议一致（双端是否同版仍需对照）'
          : '警告：原生UUID与本地协议不一致',
    );
  }
  for (final key in fields) {
    final value = raw[key];
    if (value is String || value is bool || value is num) {
      lines.add('$key=${bounded(value, 180)}');
    }
  }
  final events = raw['events'];
  if (events is List) {
    final start = events.length > 80 ? events.length - 80 : 0;
    for (final value in events.skip(start)) {
      if (value is String) lines.add(bounded(value, 320));
    }
  }
  return lines.join('\n');
}
