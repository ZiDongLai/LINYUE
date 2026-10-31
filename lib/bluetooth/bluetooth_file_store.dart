import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/services.dart';
import '../services/disk_capacity_guard.dart';
import '../services/received_file_actions.dart';
import 'bluetooth_file_results.dart';
import 'bluetooth_file_policy.dart';

const bluetoothFileMaxBytes = 1024 * 1024;

String bluetoothFileName(String name) {
  final safe = ReceivedFileActions.validateFileName(name);
  if (safe != name ||
      safe.length > 120 ||
      safe.startsWith('.') ||
      safe.endsWith('.part') ||
      safe.endsWith('.writing')) {
    throw const FormatException('蓝牙文件名无效或属于临时文件');
  }
  return safe;
}

class BluetoothFileOffer {
  BluetoothFileOffer({
    required this.id,
    required this.name,
    required this.size,
    required this.sha256,
    this.commitNonce,
    this.maxBytes = bluetoothFileMaxBytes,
  }) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        size < 0 ||
        !bluetoothValidFileLimit(maxBytes) ||
        size > maxBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        (commitNonce != null &&
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(commitNonce!))) {
      throw FormatException(
        '蓝牙文件元数据无效（协商上限${bluetoothFileLimitLabel(maxBytes)}）',
      );
    }
    bluetoothFileName(name);
  }
  final String id, name, sha256;
  // Local-only reserved target nonce. parse() never accepts it from the wire.
  final String? commitNonce;
  // Local validation policy; never taken from an untrusted wire field.
  final int maxBytes;
  final int size;
  static BluetoothFileOffer parse(
    Map<String, dynamic> m, {
    int maxBytes = bluetoothFileMaxBytes,
  }) {
    if (m['id'] is! String ||
        m['name'] is! String ||
        m['size'] is! int ||
        m['sha'] is! String) {
      throw const FormatException('Invalid file offer fields');
    }
    return BluetoothFileOffer(
      id: m['id'],
      name: m['name'],
      size: m['size'],
      sha256: m['sha'],
      maxBytes: maxBytes,
    );
  }
}

typedef BluetoothFileCommit =
    Future<File> Function(File temporary, BluetoothFileOffer offer);

/// Temporary files live OUTSIDE the existing inbox; no LAN journal is created.
class BluetoothFileStore {
  BluetoothFileStore({
    required this.inbox,
    required this.work,
    this.diskGuard = const DiskCapacityGuard(),
    this.allowWindowsNestedWork = false,
    this.reliableResults = false,
    this.openWriter,
    this.recoverCommitted,
    this.maxBytes = bluetoothDefaultFileBytes,
    BluetoothFileCommit? commit,
  }) : commit = commit ?? commitAndroid;
  final Directory inbox, work;
  final bool allowWindowsNestedWork;
  final bool reliableResults;
  final int maxBytes;
  final Future<RandomAccessFile> Function(File)? openWriter;
  final Future<File> Function(BluetoothFileResult)? recoverCommitted;
  late final BluetoothFileResults results = BluetoothFileResults(
    work,
    inbox,
    maxBytes: maxBytes,
  );
  final DiskCapacityGuard diskGuard;
  final BluetoothFileCommit commit;
  Future<File> verifyResult(BluetoothFileResult record) async {
    if (record.phase == 'prepared') throw StateError('文件未进入提交阶段，结果不能确认');
    if (record.phase == 'committing') {
      if (recoverCommitted != null) {
        final file = await recoverCommitted!(record);
        if (await file.resolveSymbolicLinks() !=
            await results.target(record).resolveSymbolicLinks()) {
          throw StateError('恢复提交目标不符');
        }
      } else {
        final arguments = {
          'inbox': inbox.path,
          'path': results.target(record).path,
          'transferId': record.offer.id,
          'name': record.offer.name,
          'size': record.offer.size,
          'sha256': record.offer.sha256,
          'commitNonce': record.nonce,
          'verifyOnly': true,
        };
        final channel = Platform.isWindows
            ? const MethodChannel('nearlink/bluetooth_file_commit')
            : _channel;
        final result = await channel.invokeMapMethod<String, dynamic>(
          Platform.isWindows ? 'commit' : 'commitBluetoothReceivedFile',
          arguments,
        );
        if (result?['path'] is! String ||
            result?['size'] != record.offer.size ||
            result?['sha256'] != record.offer.sha256 ||
            await File(result!['path'] as String).resolveSymbolicLinks() !=
                await results.target(record).resolveSymbolicLinks()) {
          throw StateError('系统未返回有效的持久提交复核结果');
        }
      }
      await results.verify(record);
      await results.advance(record, 'committed');
    }
    return results.verify(record);
  }

  static const _channel = MethodChannel('nearlink/files');
  static Future<File> commitAndroid(File file, BluetoothFileOffer offer) async {
    final result = await _channel
        .invokeMapMethod<String, dynamic>('commitBluetoothReceivedFile', {
          'path': file.path,
          'transferId': offer.id,
          'name': offer.name,
          'size': offer.size,
          'sha256': offer.sha256,
          if (offer.commitNonce != null) 'commitNonce': offer.commitNonce,
        });
    if (result?['path'] is! String ||
        result?['size'] != offer.size ||
        result?['sha256'] != offer.sha256) {
      throw StateError('系统未返回有效蓝牙文件提交结果');
    }
    return File(result!['path'] as String);
  }

  static Future<File> commitWindows(
    File file,
    BluetoothFileOffer offer,
    Directory inbox,
  ) async {
    final result = await const MethodChannel('nearlink/bluetooth_file_commit')
        .invokeMapMethod<String, dynamic>('commit', {
          'inbox': inbox.path,
          'path': file.path,
          'name': offer.name,
          'size': offer.size,
          'sha256': offer.sha256,
          if (offer.commitNonce != null) 'commitNonce': offer.commitNonce,
        });
    if (result?['path'] is! String ||
        result?['size'] != offer.size ||
        result?['sha256'] != offer.sha256) {
      throw StateError('电脑未返回有效的蓝牙文件提交结果');
    }
    return File(result!['path'] as String);
  }

  Future<BluetoothStagedFile> begin(BluetoothFileOffer offer) async {
    if (!bluetoothValidFileLimit(maxBytes) || offer.size > maxBytes) {
      throw StateError('文件超过本机蓝牙接收上限');
    }
    if (await FileSystemEntity.type(inbox.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        work.absolute.path == inbox.absolute.path) {
      throw StateError('蓝牙接收目录未就绪');
    }
    await work.create(recursive: true);
    final root = await inbox.resolveSymbolicLinks();
    final working = await work.resolveSymbolicLinks();
    final allowedNested =
        allowWindowsNestedWork &&
        working == '$root${Platform.pathSeparator}.linyue_part_bt_e33';
    if (working == root ||
        (working.startsWith('$root${Platform.pathSeparator}') &&
            !allowedNested)) {
      throw StateError('蓝牙暂存目录必须与完成接收目录隔离');
    }
    await diskGuard.requireRoom(
      destinationPath: inbox.path,
      fileBytes: offer.size,
    );
    final folder = await work.createTemp('rx_');
    final file = File('${folder.path}${Platform.pathSeparator}payload.part');
    return BluetoothStagedFile._(
      this,
      offer,
      folder,
      file,
      await (openWriter?.call(file) ?? file.open(mode: FileMode.writeOnly)),
    );
  }
}

class BluetoothStagedFile {
  BluetoothStagedFile._(
    this.store,
    this.offer,
    this.folder,
    this.file,
    this._writer,
  );
  final BluetoothFileStore store;
  final BluetoothFileOffer offer;
  final Directory folder;
  final File file;
  RandomAccessFile? _writer;
  bool _cancelled = false;
  int bytes = 0;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() f) {
    final next = _tail.then((_) => f());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _alive() {
    if (_cancelled) throw StateError('蓝牙文件接收已停止');
  }

  Future<void> append(int offset, List<int> data) => _serial(() async {
    _alive();
    if (offset != bytes ||
        data.isEmpty ||
        bytes + data.length > offer.size ||
        _writer == null) {
      throw StateError('蓝牙文件偏移或长度错误');
    }
    await _writer!.writeFrom(data);
    _alive();
    bytes += data.length;
  });
  Future<File> finish({String? authenticatedPeer}) => _serial(() async {
    _alive();
    if (bytes != offer.size || _writer == null) throw StateError('蓝牙文件尚未完整接收');
    await _writer!.flush();
    await _writer!.close();
    _writer = null;
    _alive();
    final digest = (await hashes.sha256.bind(file.openRead()).first).toString();
    _alive();
    if (await file.length() != offer.size || digest != offer.sha256) {
      throw StateError('蓝牙文件SHA-256或长度校验失败');
    }
    BluetoothFileResult? record;
    if (store.reliableResults) {
      if (authenticatedPeer == null) throw StateError('蓝牙提交缺少可信对端身份');
      record = await store.results.prepare(authenticatedPeer, offer);
      record = await store.results.advance(record, 'committing');
    }
    final localOffer = record == null
        ? offer
        : BluetoothFileOffer(
            id: offer.id,
            name: offer.name,
            size: offer.size,
            sha256: offer.sha256,
            commitNonce: record.nonce,
            maxBytes: offer.maxBytes,
          );
    final saved = await store.commit(file, localOffer);
    if (record != null) {
      if (await saved.resolveSymbolicLinks() !=
          await store.results.target(record).resolveSymbolicLinks()) {
        throw StateError('原生蓝牙提交目标与持久记录不符');
      }
      await store.results.verify(record);
      await store.results.advance(record, 'committed');
    }
    _alive();
    final canonical = File(await saved.resolveSymbolicLinks());
    if (canonical.parent.path != await store.inbox.resolveSymbolicLinks() ||
        await canonical.length() != offer.size ||
        (await hashes.sha256.bind(canonical.openRead()).first).toString() !=
            offer.sha256) {
      throw StateError('蓝牙文件最终落盘校验失败');
    }
    _alive();
    return canonical;
  });
  Future<void> abort() {
    _cancelled = true;
    return _serial(() async {
      try {
        await _writer?.close();
      } catch (_) {}
      _writer = null;
      // Only this createTemp directory; never the final file or a user source.
      try {
        if (await folder.exists()) await folder.delete(recursive: true);
      } catch (_) {}
    });
  }
}
