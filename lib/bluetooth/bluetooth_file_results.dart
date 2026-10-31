import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import '../security/secure_core.dart' show secureRandomBytes;
import 'bluetooth_file_store.dart';
import 'bluetooth_file_policy.dart';

/// E36 completion journal, NOT a data checkpoint or a LAN recovery task.
/// No session key or offer token is persisted. Records never authorize a peer.
class BluetoothFileResult {
  const BluetoothFileResult(
    this.peer,
    this.offer,
    this.nonce,
    this.phase,
    this.generation,
  );
  final String peer, nonce, phase;
  final BluetoothFileOffer offer;
  final int generation;
  String get savedName {
    final dot = offer.name.lastIndexOf('.');
    final stem = dot > 0 ? offer.name.substring(0, dot) : offer.name;
    final ext = dot > 0 ? offer.name.substring(dot) : '';
    return '${stem}_BT_$nonce$ext';
  }

  Map<String, dynamic> get json => {
    'v': 'linyue-bt-completion-e36-v1',
    'transport': 'bluetooth',
    'peer': peer,
    'id': offer.id,
    'name': offer.name,
    'size': offer.size,
    'sha': offer.sha256,
    'nonce': nonce,
    'phase': phase,
    'generation': generation,
  };
}

class BluetoothFileResults {
  BluetoothFileResults(
    this.work,
    this.inbox, {
    this.maxBytes = bluetoothDefaultFileBytes,
  });
  final Directory work, inbox;
  final int maxBytes;
  Future<void> _tail = Future<void>.value();
  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Directory get directory =>
      Directory('${work.path}${Platform.pathSeparator}.results_e36');
  static const phases = [
    'prepared',
    'committing',
    'committed',
    'history',
    'ackQueued',
  ];
  Future<void> _root() async {
    if (await FileSystemEntity.type(inbox.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('蓝牙接收目录不可安全访问');
    }
    final workKind = await FileSystemEntity.type(work.path, followLinks: false);
    if (workKind == FileSystemEntityType.notFound) {
      await work.create(recursive: true);
    }
    if (await FileSystemEntity.type(work.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('蓝牙提交记录工作目录不安全');
    }
    final resultKind = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (resultKind != FileSystemEntityType.notFound &&
        resultKind != FileSystemEntityType.directory) {
      throw StateError('蓝牙提交记录目录类型不安全');
    }
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await directory.resolveSymbolicLinks() !=
            '${await work.resolveSymbolicLinks()}${Platform.pathSeparator}.results_e36') {
      throw StateError('蓝牙提交记录目录不安全');
    }
  }

  void _ids(String peer, String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(peer) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const FormatException('Invalid Bluetooth result identity');
    }
  }

  File _slot(String peer, String id, int generation) {
    _ids(peer, id);
    return File(
      '${directory.path}${Platform.pathSeparator}${peer}_$id.${generation.isEven ? 'a' : 'b'}.json',
    );
  }

  Future<BluetoothFileResult?> load(String peer, String id) async {
    _ids(peer, id);
    await _root();
    BluetoothFileResult? latest;
    var present = false;
    for (var slot = 0; slot < 2; slot++) {
      final file = _slot(peer, id, slot);
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      present = true;
      if (type != FileSystemEntityType.file) {
        throw StateError('Unsafe Bluetooth result record');
      }
      try {
        if (await file.length() > 8192) {
          throw const FormatException('Oversize completion record');
        }
        final envelope = jsonDecode(await file.readAsString());
        final m = envelope['record'] as Map<String, dynamic>;
        if (hashes.sha256.convert(utf8.encode(jsonEncode(m))).toString() !=
                envelope['checksum'] ||
            m['v'] != 'linyue-bt-completion-e36-v1' ||
            m['transport'] != 'bluetooth' ||
            m['peer'] != peer ||
            m['id'] != id ||
            m['generation'] is! int ||
            m['generation'] < 0 ||
            m['generation'] % 2 != slot ||
            m['nonce'] is! String ||
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(m['nonce']) ||
            !phases.contains(m['phase'])) {
          throw const FormatException('Invalid completion record');
        }
        final value = BluetoothFileResult(
          peer,
          BluetoothFileOffer.parse(m, maxBytes: maxBytes),
          m['nonce'],
          m['phase'],
          m['generation'],
        );
        if (latest == null || value.generation > latest.generation) {
          latest = value;
        }
      } catch (_) {
        /* Older valid slot may survive an interrupted update. */
      }
    }
    if (present && latest == null) throw StateError('蓝牙提交记录损坏，请保留诊断');
    return latest;
  }

  Future<void> _write(BluetoothFileResult value) async {
    await _root();
    final slot = _slot(value.peer, value.offer.id, value.generation);
    final kind = await FileSystemEntity.type(slot.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound &&
        kind != FileSystemEntityType.file) {
      throw StateError('Unsafe result slot');
    }
    final tmp = File('${slot.path}.writing');
    // Never follow a leftover link; no unknown file is deleted on failure.
    if (await FileSystemEntity.type(tmp.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('蓝牙提交记录存在未完成写入，请保留诊断');
    }
    await tmp.create(exclusive: true);
    try {
      final m = value.json;
      await tmp.writeAsString(
        jsonEncode({
          'record': m,
          'checksum': hashes.sha256
              .convert(utf8.encode(jsonEncode(m)))
              .toString(),
        }),
        flush: true,
      );
      await tmp.rename(slot.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<BluetoothFileResult> prepare(String peer, BluetoothFileOffer offer) =>
      _exclusive(() async {
        if (await load(peer, offer.id) != null) {
          throw StateError('蓝牙任务已有提交记录，不能重复接收');
        }
        final nonce = secureRandomBytes(
          16,
        ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        final record = BluetoothFileResult(peer, offer, nonce, 'prepared', 0);
        if (await FileSystemEntity.type(
              target(record).path,
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          throw StateError('蓝牙接收目标已存在');
        }
        await _write(record);
        return record;
      });
  File target(BluetoothFileResult record) =>
      File('${inbox.path}${Platform.pathSeparator}${record.savedName}');
  Future<BluetoothFileResult> advance(
    BluetoothFileResult record,
    String phase,
  ) => _exclusive(() async {
    final current = await load(record.peer, record.offer.id);
    if (current == null ||
        current.nonce != record.nonce ||
        current.offer.sha256 != record.offer.sha256 ||
        current.offer.size != record.offer.size ||
        current.offer.name != record.offer.name) {
      throw StateError('蓝牙结果记录身份不一致');
    }
    if (!phases.contains(phase)) throw ArgumentError('Unknown result phase');
    if (phases.indexOf(current.phase) >= phases.indexOf(phase)) return current;
    final next = BluetoothFileResult(
      current.peer,
      current.offer,
      current.nonce,
      phase,
      current.generation + 1,
    );
    await _write(next);
    return next;
  });
  Future<File> verify(BluetoothFileResult record) async {
    final file = target(record);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        File(await file.resolveSymbolicLinks()).parent.path !=
            await inbox.resolveSymbolicLinks() ||
        await file.length() != record.offer.size ||
        (await hashes.sha256.bind(file.openRead()).first).toString() !=
            record.offer.sha256) {
      throw StateError('蓝牙已提交文件不存在或校验失败，不能确认成功');
    }
    return File(await file.resolveSymbolicLinks());
  }

  /// Repairs completed-file/history consistency only, never partial data or ACKs.
  Stream<BluetoothFileResult> pendingHistory(String authenticatedPeer) async* {
    _ids(authenticatedPeer, '0' * 32);
    await _root();
    var repaired = 0;
    await for (final item in directory.list(followLinks: false)) {
      final name = item.uri.pathSegments.last;
      if (!name.startsWith('${authenticatedPeer}_') ||
          !name.endsWith('.a.json')) {
        continue;
      }
      final id = name.substring(authenticatedPeer.length + 1, name.length - 7);
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) continue;
      final record = await load(authenticatedPeer, id);
      if (record == null ||
          phases.indexOf(record.phase) >= phases.indexOf('history')) {
        continue;
      }
      if (record.phase == 'prepared') continue;
      if (await FileSystemEntity.type(
            target(record).path,
            followLinks: false,
          ) ==
          FileSystemEntityType.notFound) {
        continue;
      }
      yield record;
      if (++repaired >= 64) break;
    }
  }
}
