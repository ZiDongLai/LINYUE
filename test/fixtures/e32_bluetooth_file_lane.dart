import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:nearlink/security/secure_core.dart' show secureRandomBytes;
import 'package:nearlink/bluetooth/bluetooth_file_store.dart';

const bluetoothFileVersion = 'linyue-bt-small-file-e32-v1';
const bluetoothFileChunkBytes = 4096;
String _randomId() => secureRandomBytes(
  16,
).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
String _digest(List<int> b) => hashes.sha256.convert(b).toString();

class BluetoothFileProgress {
  const BluetoothFileProgress(
    this.offer,
    this.receiving,
    this.bytes,
    this.phase, [
    this.error = '',
  ]);
  final BluetoothFileOffer offer;
  final bool receiving;
  final int bytes;
  final String phase, error;
}

/// One W->A file per session at a time. All messages are inside B1 AEAD.
/// No IP, LAN recovery journal, key material or file-wide byte allocation.
class BluetoothFileLane {
  BluetoothFileLane({
    required this.server,
    required this.seal,
    required this.alive,
    required this.onProgress,
    this.store,
    this.approve,
    this.onReceived,
    this.ackTimeout = const Duration(seconds: 15),
  });
  final bool server;
  final Future<void> Function(Map<String, dynamic>) seal;
  final void Function() alive;
  final void Function(BluetoothFileProgress) onProgress;
  final BluetoothFileStore? store;
  final Future<bool> Function(BluetoothFileOffer)? approve;
  final Future<void> Function(BluetoothFileOffer, File)? onReceived;
  final Duration ackTimeout;
  bool _closed = false,
      _offeredCapability = false,
      _confirmedCapability = false,
      _sending = false;
  BluetoothFileOffer? _outgoing, _incoming;
  BluetoothStagedFile? _staged;
  String _token = '';
  int _next = 0, _lastOffset = -1, _lastIndex = -1;
  String _lastDigest = '';
  Timer? _idle;
  ({String kind, Completer<Map<String, dynamic>> done})? _pending;
  final _completed = <String, ({Map<String, dynamic> receipt, File file})>{};
  Map<String, dynamic> get capability => {
    'v': bluetoothFileVersion,
    'role': server ? 'receive' : 'send',
    'max': bluetoothFileMaxBytes,
    'chunk': bluetoothFileChunkBytes,
  };
  bool _same(Object? value, Map<String, dynamic> expected) =>
      value is Map &&
      value.length == expected.length &&
      expected.entries.every((e) => value[e.key] == e.value);
  Map<String, dynamic> get _remoteCapability => {
    ...capability,
    'role': server ? 'send' : 'receive',
  };
  void observeCapability(Object? remote) {
    _offeredCapability = _same(remote, _remoteCapability);
  }

  void confirmCapability(Object? remote, Object? echo) {
    _confirmedCapability =
        _same(remote, _remoteCapability) && _same(echo, capability);
  }

  bool get ready =>
      !_closed &&
      _offeredCapability &&
      _confirmedCapability &&
      (!server || (store != null && approve != null));
  void _alive() {
    alive();
    if (_closed || !ready) throw StateError('蓝牙文件能力未协商或会话已断开');
  }

  void _progress(
    BluetoothFileOffer offer,
    bool receive,
    int bytes,
    String phase, [
    String error = '',
  ]) {
    onProgress(BluetoothFileProgress(offer, receive, bytes, phase, error));
  }

  Future<void> _emit(Map<String, dynamic> m) async {
    _alive();
    await seal({'v': bluetoothFileVersion, ...m});
    _alive();
  }

  Future<Map<String, dynamic>> _exchange(
    String kind,
    Map<String, dynamic> m, {
    Duration? timeout,
  }) async {
    final done = Completer<Map<String, dynamic>>();
    final result = done.future.timeout(timeout ?? ackTimeout);
    unawaited(result.catchError((Object e) => <String, dynamic>{}));
    _pending = (kind: kind, done: done);
    try {
      await _emit(m);
      final ack = await result;
      _alive();
      return ack;
    } finally {
      _pending = null;
    }
  }

  Future<BluetoothFileOffer> send(File source) async {
    _alive();
    if (server || _sending) throw StateError('仅支持电脑向手机发送单个文件');
    _sending = true;
    BluetoothFileOffer? offer;
    try {
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('发送源不是可访问的普通文件');
      }
      final size = await source.length();
      if (size > bluetoothFileMaxBytes) {
        throw StateError('蓝牙测试版单文件最大1 MiB，不会改走局域网');
      }
      final sha = (await hashes.sha256.bind(source.openRead()).first)
          .toString();
      _alive();
      offer = BluetoothFileOffer(
        id: _randomId(),
        name: source.uri.pathSegments.last,
        size: size,
        sha256: sha,
      );
      _outgoing = offer;
      _progress(offer, false, 0, '等待手机确认');
      final accepted = await _exchange('file-accept', {
        'k': 'file-offer',
        'id': offer.id,
        'name': offer.name,
        'size': size,
        'sha': sha,
      }, timeout: const Duration(seconds: 65));
      final token = accepted['token'];
      if (token is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(token) ||
          accepted['offset'] != 0) {
        throw StateError('蓝牙文件授权无效');
      }
      final input = await source.open(mode: FileMode.read);
      var offset = 0, index = 0;
      try {
        while (offset < size) {
          _alive();
          final data = await input.read(
            (size - offset).clamp(0, bluetoothFileChunkBytes),
          );
          if (data.isEmpty) throw StateError('源文件在发送期间截断');
          final ack = await _exchange('file-chunk-ack', {
            'k': 'file-data',
            'id': offer.id,
            'token': token,
            'offset': offset,
            'i': index,
            'd': base64Url.encode(data).replaceAll('=', ''),
          });
          offset += data.length;
          if (ack['offset'] != offset ||
              ack['i'] != index ||
              ack['sha'] != _digest(data)) {
            throw StateError('蓝牙文件块确认不匹配');
          }
          index++;
          _progress(offer, false, offset, '已获手机块确认 · 尚待整文件校验');
        }
      } finally {
        await input.close();
      }
      if (await source.length() != size ||
          (await hashes.sha256.bind(source.openRead()).first).toString() !=
              sha) {
        throw StateError('发送源内容发生变化');
      }
      _progress(offer, false, size, '等待手机校验并落盘');
      final finalAck = await _exchange('file-complete', {
        'k': 'file-end',
        'id': offer.id,
        'token': token,
        'size': size,
        'sha': sha,
      });
      if (finalAck['size'] != size || finalAck['sha'] != sha) {
        throw StateError('蓝牙最终回执不匹配');
      }
      _progress(offer, false, size, '成功 · 手机已校验并保存');
      return offer;
    } catch (e) {
      if (offer != null) {
        _progress(offer, false, 0, '失败 · 未确认完成', '$e');
        if (!_closed && ready) {
          try {
            await _emit({
              'k': 'file-error',
              'id': offer.id,
              'reason': 'sender-aborted',
            });
          } catch (_) {}
        }
      }
      rethrow;
    } finally {
      _sending = false;
      _outgoing = null;
    }
  }

  void _stillReceiving(
    BluetoothFileOffer offer,
    BluetoothStagedFile staged,
    String token,
  ) {
    _alive();
    if (!identical(_incoming, offer) ||
        !identical(_staged, staged) ||
        _token != token) {
      throw StateError('Bluetooth file attempt cancelled/expired');
    }
  }

  Future<void> receive(Map<String, dynamic> m) async {
    _alive();
    if (m['v'] != bluetoothFileVersion ||
        m['id'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(m['id'])) {
      throw const FormatException('Invalid file version/ID');
    }
    final id = m['id'] as String, kind = m['k'];
    if (kind == 'file-error') {
      if (_outgoing?.id == id) {
        final done = _pending?.done;
        if (done != null && !done.isCompleted) {
          done.completeError(StateError('对端蓝牙文件失败：${m['reason']}'));
        }
      }
      if (_incoming?.id == id) await _abortIncoming();
      return;
    }
    if (!server) {
      final pending = _pending;
      if (id != _outgoing?.id ||
          pending == null ||
          kind != pending.kind ||
          pending.done.isCompleted) {
        throw StateError('Unexpected/duplicate Bluetooth file ACK');
      }
      pending.done.complete(m);
      return;
    }
    try {
      if (kind == 'file-offer') {
        if (_incoming != null) throw StateError('手机正在接收另一个蓝牙文件');
        final offer = BluetoothFileOffer.parse(m);
        if (_completed.containsKey(id)) {
          throw StateError('File ID already completed');
        }
        _incoming = offer;
        _progress(offer, true, 0, '等待接收确认');
        if (!await approve!(
          offer,
        ).timeout(const Duration(seconds: 60), onTimeout: () => false)) {
          throw StateError('用户拒绝或接收已暂停');
        }
        _alive();
        final staged = await store!.begin(offer);
        if (_closed) {
          await staged.abort();
          throw StateError('接收已关闭');
        }
        _staged = staged;
        _token = _randomId();
        _next = 0;
        _lastOffset = -1;
        _touch();
        await _emit({
          'k': 'file-accept',
          'id': id,
          'token': _token,
          'offset': 0,
        });
        return;
      }
      final completed = _completed[id];
      if (kind == 'file-end' &&
          completed != null &&
          m['token'] == completed.receipt['token'] &&
          m['sha'] == completed.receipt['sha'] &&
          m['size'] == completed.receipt['size']) {
        if (!await completed.file.exists() ||
            await completed.file.length() != completed.receipt['size'] ||
            (await hashes.sha256.bind(completed.file.openRead()).first)
                    .toString() !=
                completed.receipt['sha']) {
          throw StateError('Completed Bluetooth file changed or missing');
        }
        await _emit({...completed.receipt, 'k': 'file-complete'});
        return;
      }
      final offer = _incoming, staged = _staged;
      if (offer == null ||
          offer.id != id ||
          staged == null ||
          m['token'] != _token) {
        throw StateError('未批准的蓝牙文件或任务不匹配');
      }
      final activeToken = _token;
      _touch();
      if (kind == 'file-data') {
        if (m['d'] is! String ||
            (m['d'] as String).length > 5462 ||
            m['offset'] is! int ||
            m['i'] is! int) {
          throw const FormatException('Invalid file data');
        }
        final encoded = m['d'] as String;
        late final List<int> data;
        try {
          data = base64Url.decode(base64Url.normalize(encoded));
        } on FormatException {
          throw const FormatException('Invalid file base64 encoding');
        }
        if (data.isEmpty ||
            data.length > bluetoothFileChunkBytes ||
            base64Url.encode(data).replaceAll('=', '') != encoded) {
          throw const FormatException('Invalid file bytes');
        }
        final digest = _digest(data);
        if (m['offset'] == _lastOffset &&
            m['i'] == _lastIndex &&
            digest == _lastDigest) {
          await _emit({
            'k': 'file-chunk-ack',
            'id': id,
            'offset': staged.bytes,
            'i': _lastIndex,
            'sha': digest,
          });
          return;
        }
        if (m['i'] != _next || m['offset'] != staged.bytes) {
          throw StateError('蓝牙文件偏移/序号错误');
        }
        await staged.append(m['offset'], data);
        _stillReceiving(offer, staged, activeToken);
        _lastOffset = m['offset'];
        _lastIndex = _next++;
        _lastDigest = digest;
        _progress(offer, true, staged.bytes, '接收中 · 尚待整文件校验');
        await _emit({
          'k': 'file-chunk-ack',
          'id': id,
          'offset': staged.bytes,
          'i': _lastIndex,
          'sha': digest,
        });
      } else if (kind == 'file-end') {
        if (m['size'] != offer.size || m['sha'] != offer.sha256) {
          throw StateError('蓝牙文件结束信息错误');
        }
        _progress(offer, true, staged.bytes, '校验并保存');
        final saved = await staged.finish();
        _stillReceiving(offer, staged, activeToken);
        await onReceived?.call(offer, saved);
        _stillReceiving(offer, staged, activeToken);
        final receipt = <String, dynamic>{
          'id': id,
          'token': activeToken,
          'size': offer.size,
          'sha': offer.sha256,
        };
        _completed[id] = (receipt: receipt, file: saved);
        if (_completed.length > 8) _completed.remove(_completed.keys.first);
        await _abortIncoming();
        await _emit({...receipt, 'k': 'file-complete'});
        _progress(offer, true, offer.size, '成功 · 已校验并保存');
      } else {
        throw StateError('Unsupported file message');
      }
    } catch (e) {
      final offer = _incoming;
      if (offer != null) {
        _progress(offer, true, _staged?.bytes ?? 0, '失败 · 未完成', '$e');
      }
      await _abortIncoming();
      if (!_closed) {
        await _emit({
          'k': 'file-error',
          'id': id,
          'reason':
              'receive-failed: ${e.toString().substring(0, e.toString().length.clamp(0, 180))}',
        });
      }
    }
  }

  void _touch() {
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 30), () {
      final offer = _incoming;
      if (offer != null) {
        _progress(offer, true, _staged?.bytes ?? 0, '失败 · 接收超时');
        unawaited(_abortIncoming());
      }
    });
  }

  Future<void> _abortIncoming() async {
    _idle?.cancel();
    final staged = _staged;
    _staged = null;
    _incoming = null;
    _token = '';
    await staged?.abort();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _idle?.cancel();
    final pending = _pending?.done;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('蓝牙文件连接断开，未确认完成'));
    }
    final offer = _incoming;
    if (offer != null) {
      _progress(offer, true, _staged?.bytes ?? 0, '失败 · 蓝牙已断开');
    }
    unawaited(_abortIncoming());
    _completed.clear();
  }
}
