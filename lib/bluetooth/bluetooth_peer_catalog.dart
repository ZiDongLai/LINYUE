import 'dart:convert';

import '../security/device_identity.dart';

/// Classic Bluetooth addresses returned by the two native adapters only.
/// Never turn a discovery ID, process nonce or fingerprint into an OS identity.
String? canonicalBluetoothAddress(Object? raw) {
  if (raw is! String) return null;
  final address = raw.trim().replaceAll(RegExp('[:-]'), '').toUpperCase();
  if (!RegExp(r'^[0-9A-F]{12}$').hasMatch(address) ||
      address == '000000000000' ||
      address == '020000000000' ||
      address == 'FFFFFFFFFFFF') {
    return null;
  }
  return address;
}

/// Human confirmation only: select ONE already registered full fingerprint.
/// Never an OS device ID, enrollment proof, password or handshake credential.
String bluetoothIdentityCode(String fingerprint) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) return '';
  final code = fingerprint.substring(0, 24).toUpperCase();
  return [
    for (var i = 0; i < code.length; i += 4) code.substring(i, i + 4),
  ].join(' ');
}

String? resolveBluetoothIdentity(Iterable<String> registered, String input) {
  final value = input.replaceAll(RegExp(r'[\s:-]'), '').toLowerCase();
  if (!RegExp(r'^(?:[0-9a-f]{24}|[0-9a-f]{64})$').hasMatch(value)) return null;
  final matches = registered.where((fp) => fp.startsWith(value)).toList();
  return matches.length == 1 ? matches.single : null;
}

class PairedBluetoothDevice {
  const PairedBluetoothDevice({
    required this.id,
    required this.name,
    this.paired = true,
    this.phone = false,
    this.fullAddress = false,
    this.peripheral = false,
  });
  final String id, name;
  final bool paired;
  final bool phone;
  final bool fullAddress;
  final bool peripheral;
  String get suffix =>
      '${id.substring(6, 8)}:${id.substring(8, 10)}:${id.substring(10, 12)}';
  String get displayName => fullAddress
      ? '$name · 地址 ${[for (var i = 0; i < 12; i += 2) id.substring(i, i + 2)].join(':')}'
      : '$name · 尾号 $suffix';
}

class BluetoothPeerCatalog {
  const BluetoothPeerCatalog(this.devices, this.incompleteEntries);
  final List<PairedBluetoothDevice> devices;
  final int incompleteEntries;
  factory BluetoothPeerCatalog.fromSnapshot(Object? raw) {
    final byId = <String, PairedBluetoothDevice>{};
    var incomplete = 0;
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) {
          incomplete++;
          continue;
        }
        final id = canonicalBluetoothAddress(entry['id']);
        if (id == null) {
          incomplete++;
          continue;
        }
        final text = entry['name'];
        final name = text is String && text.trim().isNotEmpty
            ? text.trim()
            : '未提供蓝牙名称';
        final previous = byId[id];
        byId[id] = PairedBluetoothDevice(
          id: id,
          name: name == '未提供蓝牙名称' && previous != null ? previous.name : name,
          paired: entry['paired'] != false || (previous?.paired ?? false),
          phone: entry['kind'] == 'phone' || (previous?.phone ?? false),
          peripheral:
              entry['kind'] == 'peripheral' || (previous?.peripheral ?? false),
        );
      }
    }
    final devices = byId.values.toList()
      ..sort((a, b) {
        if (a.paired != b.paired) return a.paired ? -1 : 1;
        if (a.phone != b.phone) return a.phone ? -1 : 1;
        final names = a.name.compareTo(b.name);
        return names != 0 ? names : a.id.compareTo(b.id);
      });
    final labels = <String, int>{};
    for (final d in devices) {
      labels[d.displayName] = (labels[d.displayName] ?? 0) + 1;
    }
    return BluetoothPeerCatalog([
      for (final d in devices)
        labels[d.displayName]! > 1
            ? PairedBluetoothDevice(
                id: d.id,
                name: d.name,
                paired: d.paired,
                phone: d.phone,
                fullAddress: true,
                peripheral: d.peripheral,
              )
            : d,
    ], incomplete);
  }
}

/// Locator -> already trusted public identity hint. Does not enroll identities.
/// Only remember after B1 authenticated AND native endpoint matches selection.
class BluetoothPeerBindings {
  BluetoothPeerBindings(this.identity);
  final DeviceIdentityManager identity;
  static const storageKey = 'linyue.bluetooth.verified-peer-bindings.v1';
  final _records = <String, String>{};
  Future<void>? _loading;
  String? loadError;
  Future<void> _tail = Future<void>.value();
  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    try {
      final raw = await identity.vault.read(storageKey);
      if (raw == null) return;
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['v'] != 1 ||
          value['owner'] != identity.local.fingerprint ||
          value['peers'] is! Map ||
          (value['peers'] as Map).length > 100) {
        throw const FormatException('Invalid Bluetooth association data');
      }
      for (final entry in (value['peers'] as Map).entries) {
        final id = canonicalBluetoothAddress(entry.key);
        if (id == null ||
            entry.key != id ||
            entry.value is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value as String)) {
          throw const FormatException('Invalid Bluetooth association entry');
        }
        _records[id] = entry.value as String;
      }
    } catch (e) {
      _records.clear();
      loadError = '$e'; // Preserve corrupt bytes; never auto-reset.
    }
  }

  String? fingerprintFor(String id) {
    final value = _records[canonicalBluetoothAddress(id)];
    return identity.entries.any((e) => e.fingerprint == value) ? value : null;
  }

  Future<void> _change(void Function() edit) {
    final result = _tail.then((_) async {
      await load();
      if (loadError != null) {
        throw StateError('Bluetooth association storage unavailable');
      }
      final old = Map<String, String>.from(_records);
      edit();
      try {
        await identity.vault.write(
          storageKey,
          jsonEncode({
            'v': 1,
            'owner': identity.local.fingerprint,
            'peers': _records,
          }),
        );
      } catch (_) {
        _records
          ..clear()
          ..addAll(old);
        rethrow;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> retainPaired(Set<String> current) => _change(() {
    _records.removeWhere(
      (id, fp) =>
          !current.contains(id) ||
          !identity.entries.any((entry) => entry.fingerprint == fp),
    );
  });
  Future<void> forget(String id) => _change(() {
    _records.remove(canonicalBluetoothAddress(id));
  });
  Future<void> remember(String id, String fingerprint) => _change(() {
    final canonical = canonicalBluetoothAddress(id);
    if (canonical == null ||
        !identity.entries.any((e) => e.fingerprint == fingerprint)) {
      throw StateError('Only an existing trusted identity can be associated');
    }
    if (!_records.containsKey(canonical) && _records.length >= 100) {
      throw StateError('Bluetooth association limit reached');
    }
    _records[canonical] = fingerprint;
  });
}
