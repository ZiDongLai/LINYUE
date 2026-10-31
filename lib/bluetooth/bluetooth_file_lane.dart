import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import '../security/secure_core.dart' show secureRandomBytes;
import 'bluetooth_file_store.dart';
import 'bluetooth_file_results.dart';
import 'bluetooth_file_policy.dart';

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

/// One transfer at a time per endpoint; E33 reverse is explicitly negotiated. All messages are inside B1 AEAD.
/// No IP, LAN recovery journal, key material or file-wide byte allocation.
class BluetoothFileLane {
  BluetoothFileLane({
    required this.server,
    required this.seal,
    required this.alive,
    required this.onProgress,
    this.reverseEnabled = false,
    this.store,
    this.approve,
    this.onReceived,
    this.peerFingerprint = '',
    this.diagnostic,
    this.ackTimeout = const Duration(seconds: 15),
  });
  final bool server, reverseEnabled;
  final Future<void> Function(Map<String, dynamic>) seal;
  final void Function() alive;
  final void Function(BluetoothFileProgress) onProgress;
  final BluetoothFileStore? store;
  final Future<bool> Function(BluetoothFileOffer)? approve;
  final Future<void> Function(BluetoothFileOffer, File)? onReceived;
  final Duration ackTimeout;
  final String peerFingerprint;
  final void Function(String)? diagnostic;
  void _timingDiagnostic(String message) {
    try {
      diagnostic?.call(message);
    } catch (_) {
      // Performance reporting must never change file or ACK semantics.
    }
  }

  bool _resultOffered = false, _resultConfirmed = false;
  final _resultAttempts =
      <String, ({BluetoothFileOffer offer, String token})>{};
  final _terminal = <String, String>{};
  BluetoothFileOffer? _unconfirmed;
  String _unconfirmedToken = '';
  Map<String, dynamic>? _lateResult;
  bool get hasUnconfirmedResult => _unconfirmed != null;
  Map<String, dynamic>? get resultCapability =>
      store?.reliableResults == true &&
          onReceived != null &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(peerFingerprint)
      ? {'v': 'linyue-bt-result-e36-v1'}
      : null;
  void observeResult(Object? value) {
    _resultOffered =
        resultCapability != null && _same(value, resultCapability!);
  }

  void confirmResult(Object? value, Object? echo) {
    _resultConfirmed =
        resultCapability != null &&
        _same(value, resultCapability!) &&
        _same(echo, resultCapability!);
  }

  bool get resultReady => ready && _resultOffered && _resultConfirmed;
  bool _sizeOffered = false, _sizeConfirmed = false;
  Map<String, dynamic>? get sizeCapability =>
      store?.maxBytes == bluetoothCandidateFileBytes && resultCapability != null
      ? {'v': 'linyue-bt-limit-e37-v1', 'max': bluetoothCandidateFileBytes}
      : null;
  void observeSize(Object? value) {
    _sizeOffered = sizeCapability != null && _same(value, sizeCapability!);
  }

  void confirmSize(Object? value, Object? echo) {
    _sizeConfirmed =
        sizeCapability != null &&
        _same(value, sizeCapability!) &&
        _same(echo, sizeCapability!);
  }

  int get maxFileBytes => resultReady && _sizeOffered && _sizeConfirmed
      ? bluetoothCandidateFileBytes
      : bluetoothFileMaxBytes;
  bool _closed = false,
      _offeredCapability = false,
      _confirmedCapability = false,
      _sending = false,
      _reverseOffered = false,
      _reverseConfirmed = false;
  BluetoothFileOffer? _outgoing, _incoming;
  BluetoothStagedFile? _staged;
  String _token = '', _outgoingToken = '';
  int _next = 0, _lastOffset = -1, _lastIndex = -1;
  String _lastDigest = '';
  int _receiveChunks = 0, _receiveDecodeUs = 0, _receiveAppendUs = 0;
  int _receiveAckQueueUs = 0, _receiveMaxAppendUs = 0;
  Stopwatch? _receiveTiming;
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
  Map<String, dynamic>? get reverseCapability =>
      !reverseEnabled ||
          (!server && (store == null || approve == null || onReceived == null))
      ? null
      : {
          'v': 'linyue-bt-reverse-e33-v1',
          'role': server ? 'send' : 'receive',
          'max': bluetoothFileMaxBytes,
          'chunk': bluetoothFileChunkBytes,
        };
  Map<String, dynamic> get _remoteReverse => {
    ...?reverseCapability,
    'role': server ? 'receive' : 'send',
  };
  void observeReverse(Object? remote) {
    _reverseOffered =
        reverseCapability != null && _same(remote, _remoteReverse);
  }

  void confirmReverse(Object? remote, Object? echo) {
    _reverseConfirmed =
        reverseCapability != null &&
        _same(remote, _remoteReverse) &&
        _same(echo, reverseCapability!);
  }

  bool get reverseReady => ready && _reverseOffered && _reverseConfirmed;
  bool get sendReady => ready && (!server || reverseReady);
  bool get receiveReady =>
      ready && (server || reverseReady) && store != null && approve != null;
  final _sentComplete = <String, Map<String, dynamic>>{};
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
    bool reconciled = false,
  ]) {
    final key = '${receive ? 'receive' : 'send'}:${offer.id}';
    if (_terminal.containsKey(key) && !reconciled) return;
    if (phase.startsWith('成功') || phase.startsWith('失败')) {
      _terminal[key] = phase;
      if (_terminal.length > 16) _terminal.remove(_terminal.keys.first);
    }
    onProgress(BluetoothFileProgress(offer, receive, bytes, phase, error));
  }

  bool _validReceipt(
    Map<String, dynamic> m,
    BluetoothFileOffer offer,
    String token,
  ) =>
      m['id'] == offer.id &&
      m['size'] == offer.size &&
      m['sha'] == offer.sha256 &&
      m['token'] == token;

  Future<void> repairCommittedHistory() async {
    if (resultCapability == null) return;
    await for (final record in store!.results.pendingHistory(peerFingerprint)) {
      _alive();
      if (record.offer.id == _incoming?.id || _sending) continue;
      final file = await store!.verifyResult(record);
      await onReceived!(record.offer, file);
      _alive();
      await store!.results.advance(record, 'history');
      diagnostic?.call(
        'BT completion history repaired id=${record.offer.id.substring(0, 8)}; no transfer resumed, no ACK sent',
      );
    }
  }

  Future<void> _noteAckQueued(BluetoothFileResult record) async {
    try {
      await store!.results.advance(record, 'ackQueued');
    } catch (e) {
      diagnostic?.call(
        'BT ACK queue observation could not be persisted type=${e.runtimeType}; verified file/history retained',
      );
    }
  }

  /// Only the original in-session offer/token may ask for a verified result.
  /// No data frames are retransmitted, and this state is cleared on disconnect.
  Future<BluetoothFileOffer> confirmUncertainResult() async {
    _alive();
    final offer = _unconfirmed;
    if (offer == null) throw StateError('没有待核对的蓝牙传输');
    if (!resultReady) throw StateError('对端不支持结果核对，结果未确认；不会重新发送或改用局域网');
    if (_sending) throw StateError('正在处理蓝牙文件');
    _sending = true;
    _outgoing = offer;
    _outgoingToken = _unconfirmedToken;
    try {
      final result =
          _lateResult ??
          await _exchange('file-result', {
            'k': 'file-result-query',
            'id': offer.id,
            'token': _unconfirmedToken,
            'size': offer.size,
            'sha': offer.sha256,
          });
      if (!_validReceipt(result, offer, _unconfirmedToken) ||
          (result['k'] != 'file-complete' && result['status'] != 'complete')) {
        throw StateError('蓝牙结果未确认，请保留现有文件，不要重复发送');
      }
      _alive();
      _sentComplete[offer.id] = {...result, 'k': 'file-complete'}
        ..remove('status');
      if (_sentComplete.length > 8) {
        _sentComplete.remove(_sentComplete.keys.first);
      }
      _unconfirmed = null;
      _lateResult = null;
      _progress(offer, false, offer.size, '成功 · 对端已核验文件与接收记录', '', true);
      return offer;
    } finally {
      _sending = false;
      _outgoing = null;
      _outgoingToken = '';
    }
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

  Future<BluetoothFileOffer> send(File source, {String? name}) async {
    _alive();
    if (hasUnconfirmedResult) throw StateError('上次蓝牙结果未确认，请先核对结果，不会重复发送');
    if (!sendReady) throw StateError('对端未协商此方向蓝牙文件能力；不会改用局域网');
    if (_sending || _incoming != null) throw StateError('已有蓝牙文件任务，请等待完成');
    _sending = true;
    BluetoothFileOffer? offer;
    var acknowledgedBytes = 0;
    final timing = Stopwatch()..start();
    var offerUs = 0, chunkCount = 0, chunkRttUs = 0, maxChunkRttUs = 0;
    var postOfferOtherUs = 0;
    void reportTiming(String result) {
      if (offer == null) return;
      _timingDiagnostic(
        'BT file timing direction=send id=${offer.id.substring(0, 8)} '
        'result=$result bytes=$acknowledgedBytes chunks=$chunkCount '
        'totalUs=${timing.elapsedMicroseconds} preflightOfferUs=$offerUs '
        'chunkRttUs=$chunkRttUs maxChunkRttUs=$maxChunkRttUs '
        'postOfferOtherUs=$postOfferOtherUs',
      );
    }

    try {
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('发送源不是可访问的普通文件');
      }
      final size = await source.length();
      if (size > maxFileBytes) {
        throw StateError(
          '蓝牙单文件超过双方协商上限${bluetoothFileLimitLabel(maxFileBytes)}，不会改走局域网',
        );
      }
      final sha = (await hashes.sha256.bind(source.openRead()).first)
          .toString();
      _alive();
      offer = BluetoothFileOffer(
        id: _randomId(),
        name: name ?? source.uri.pathSegments.last,
        size: size,
        sha256: sha,
        maxBytes: maxFileBytes,
      );
      _outgoing = offer;
      _progress(offer, false, 0, '等待对端确认');
      final accepted = await _exchange('file-accept', {
        'k': 'file-offer',
        'id': offer.id,
        'name': offer.name,
        'size': size,
        'sha': sha,
      }, timeout: const Duration(seconds: 65));
      offerUs = timing.elapsedMicroseconds;
      final token = accepted['token'];
      if (token is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(token) ||
          accepted['offset'] != 0) {
        throw StateError('蓝牙文件授权无效');
      }
      _outgoingToken = token;
      final input = await source.open(mode: FileMode.read);
      var offset = 0, index = 0;
      try {
        while (offset < size) {
          _alive();
          final data = await input.read(
            (size - offset).clamp(0, bluetoothFileChunkBytes),
          );
          if (data.isEmpty) throw StateError('源文件在发送期间截断');
          final chunkTiming = Stopwatch()..start();
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
          final rtt = chunkTiming.elapsedMicroseconds;
          chunkCount++;
          chunkRttUs += rtt;
          if (rtt > maxChunkRttUs) maxChunkRttUs = rtt;
          index++;
          acknowledgedBytes = offset;
          _progress(offer, false, offset, '已获对端块确认 · 尚待整文件校验');
        }
      } finally {
        await input.close();
      }
      if (await source.length() != size ||
          (await hashes.sha256.bind(source.openRead()).first).toString() !=
              sha) {
        throw StateError('发送源内容发生变化');
      }
      _progress(offer, false, size, '等待对端校验并落盘');
      final endMessage = {
        'k': 'file-end',
        'id': offer.id,
        'token': token,
        'size': size,
        'sha': sha,
      };
      late Map<String, dynamic> finalAck;
      if (resultReady) {
        _unconfirmed = offer;
        _unconfirmedToken = token;
      }
      try {
        finalAck = await _exchange('file-complete', endMessage);
      } catch (e) {
        if (e is! TimeoutException && !resultReady) rethrow;
        _unconfirmed = offer;
        _unconfirmedToken = token;
        diagnostic?.call(
          'BT final receipt timeout id=${offer.id.substring(0, 8)}; result unknown',
        );
        if (resultReady) {
          // One bounded query in the SAME authenticated session; no new send.
          finalAck = await _exchange('file-result', {
            'k': 'file-result-query',
            'id': offer.id,
            'token': token,
            'size': size,
            'sha': sha,
          });
          if (finalAck['k'] != 'file-complete' &&
              finalAck['status'] != 'complete') {
            throw StateError('蓝牙结果未确认，请核对结果而非重新发送');
          }
        } else {
          rethrow;
        }
      }
      if (finalAck['size'] != size ||
          finalAck['sha'] != sha ||
          finalAck['token'] != token) {
        throw StateError('蓝牙最终回执不匹配');
      }
      _sentComplete[offer.id] = {...finalAck, 'k': 'file-complete'}
        ..remove('status');
      if (_sentComplete.length > 8) {
        _sentComplete.remove(_sentComplete.keys.first);
      }
      _progress(offer, false, size, '成功 · 对端已校验并保存');
      postOfferOtherUs = timing.elapsedMicroseconds - offerUs - chunkRttUs;
      reportTiming('final-receipt-verified');
      _unconfirmed = null;
      _lateResult = null;
      return offer;
    } catch (e) {
      reportTiming('failed-${e.runtimeType}');
      if (offer != null) {
        diagnostic?.call(
          'BT send failed id=${offer.id.substring(0, 8)} type=${e.runtimeType} resultUnknown=$hasUnconfirmedResult',
        );
        _progress(
          offer,
          false,
          acknowledgedBytes,
          hasUnconfirmedResult ? '失败 · 结果未确认，请核对结果' : '失败 · 未确认完成',
          hasUnconfirmedResult ? '结果未确认：${e.runtimeType}' : '$e',
        );
        if (!_closed && ready && !hasUnconfirmedResult) {
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
      _outgoingToken = '';
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
    if (kind == 'file-result-query') {
      if (!resultReady) throw StateError('未协商蓝牙结果核对能力');
      final attempt = _resultAttempts[id];
      if (attempt == null || !_validReceipt(m, attempt.offer, attempt.token)) {
        throw StateError('蓝牙结果查询未绑定本次授权');
      }
      try {
        var record = await store!.results.load(peerFingerprint, id);
        if (record == null ||
            record.offer.size != attempt.offer.size ||
            record.offer.sha256 != attempt.offer.sha256 ||
            record.offer.name != attempt.offer.name) {
          throw StateError('没有可信的提交结果');
        }
        final file = await store!.verifyResult(record);
        _alive();
        await onReceived!(
          record.offer,
          file,
        ); // production history callback is idempotent
        _alive();
        record = await store!.results.advance(record, 'history');
        await _emit({
          'k': 'file-result',
          'id': id,
          'token': attempt.token,
          'size': record.offer.size,
          'sha': record.offer.sha256,
          'status': 'complete',
        });
        await _noteAckQueued(record);
        _progress(
          record.offer,
          true,
          record.offer.size,
          '成功 · 文件与记录已核对',
          '',
          true,
        );
      } catch (e) {
        diagnostic?.call(
          'BT result unconfirmed id=${id.substring(0, 8)} stage=verify-history type=${e.runtimeType}',
        );
        await _emit({
          'k': 'file-result',
          'id': id,
          'token': attempt.token,
          'size': attempt.offer.size,
          'sha': attempt.offer.sha256,
          'status': 'unknown',
        });
      }
      return;
    }
    if (kind == 'file-error') {
      if (_outgoing?.id == id) {
        final done = _pending?.done;
        if (done != null && !done.isCompleted) {
          done.completeError(StateError('对端蓝牙文件失败：${m['reason']}'));
        }
      }
      if (_incoming?.id == id) {
        _progress(_incoming!, true, _staged?.bytes ?? 0, '失败 · 对端已停止传输');
        await _abortIncoming();
      }
      return;
    }
    if (kind == 'file-accept' ||
        kind == 'file-chunk-ack' ||
        kind == 'file-complete' ||
        kind == 'file-result') {
      if (!sendReady) throw StateError('此方向蓝牙文件能力未协商');
      final completed = _sentComplete[id];
      if ((kind == 'file-complete' ||
              (kind == 'file-result' && m['status'] == 'complete')) &&
          completed != null &&
          [
            'id',
            'token',
            'size',
            'sha',
          ].every((key) => m[key] == completed[key])) {
        return;
      }
      if (kind == 'file-complete' &&
          _unconfirmed?.id == id &&
          _validReceipt(m, _unconfirmed!, _unconfirmedToken) &&
          _pending == null) {
        _lateResult = Map.from(
          m,
        ); // UI stays unknown until the result is consumed.
        return;
      }
      if (kind == 'file-result' &&
          _unconfirmed?.id == id &&
          _validReceipt(m, _unconfirmed!, _unconfirmedToken) &&
          (_pending == null || _pending!.done.isCompleted)) {
        return;
      }
      final pending = _pending;
      if (id != _outgoing?.id ||
          pending == null ||
          (kind != pending.kind &&
              !(kind == 'file-complete' && pending.kind == 'file-result')) ||
          pending.done.isCompleted) {
        throw StateError('Unexpected/duplicate Bluetooth file ACK');
      }
      if (kind == 'file-complete' || kind == 'file-result') {
        if (m['size'] != _outgoing!.size ||
            m['sha'] != _outgoing!.sha256 ||
            m['token'] != _outgoingToken) {
          throw StateError('蓝牙最终回执不匹配');
        }
        if (kind == 'file-result' && m['status'] != 'complete') {
          pending.done.complete(m);
          return;
        }
        _sentComplete[id] = {...m, 'k': 'file-complete'}..remove('status');
        if (_sentComplete.length > 8) {
          _sentComplete.remove(_sentComplete.keys.first);
        }
      }
      pending.done.complete(m);
      return;
    }
    if (!receiveReady) throw StateError('此方向蓝牙文件接收能力未协商');
    try {
      if (kind == 'file-offer') {
        if (_incoming != null || _sending) throw StateError('正在处理另一个蓝牙文件');
        final offer = BluetoothFileOffer.parse(m, maxBytes: maxFileBytes);
        if (_completed.containsKey(id)) {
          throw StateError('File ID already completed');
        }
        _incoming = offer;
        _receiveTiming = Stopwatch()..start();
        _receiveChunks = 0;
        _receiveDecodeUs = 0;
        _receiveAppendUs = 0;
        _receiveAckQueueUs = 0;
        _receiveMaxAppendUs = 0;
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
        _resultAttempts[id] = (offer: offer, token: _token);
        if (_resultAttempts.length > 8) {
          _resultAttempts.remove(_resultAttempts.keys.first);
        }
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
        final decodeTiming = Stopwatch()..start();
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
        _receiveDecodeUs += decodeTiming.elapsedMicroseconds;
        final appendTiming = Stopwatch()..start();
        await staged.append(m['offset'], data);
        final appendUs = appendTiming.elapsedMicroseconds;
        _receiveAppendUs += appendUs;
        if (appendUs > _receiveMaxAppendUs) _receiveMaxAppendUs = appendUs;
        _stillReceiving(offer, staged, activeToken);
        _lastOffset = m['offset'];
        _lastIndex = _next++;
        _lastDigest = digest;
        _progress(offer, true, staged.bytes, '接收中 · 尚待整文件校验');
        final ackTiming = Stopwatch()..start();
        await _emit({
          'k': 'file-chunk-ack',
          'id': id,
          'offset': staged.bytes,
          'i': _lastIndex,
          'sha': digest,
        });
        _receiveAckQueueUs += ackTiming.elapsedMicroseconds;
        _receiveChunks++;
      } else if (kind == 'file-end') {
        if (m['size'] != offer.size || m['sha'] != offer.sha256) {
          throw StateError('蓝牙文件结束信息错误');
        }
        _progress(offer, true, staged.bytes, '校验并保存');
        _idle?.cancel(); // byte-idle timeout is not a commit/history deadline
        final commitTiming = Stopwatch()..start();
        final saved = await staged.finish(authenticatedPeer: peerFingerprint);
        final commitUs = commitTiming.elapsedMicroseconds;
        _stillReceiving(offer, staged, activeToken);
        final historyTiming = Stopwatch()..start();
        await onReceived?.call(offer, saved);
        _stillReceiving(offer, staged, activeToken);
        BluetoothFileResult? durable;
        if (store!.reliableResults) {
          durable = await store!.results.load(peerFingerprint, id);
          if (durable == null) throw StateError('蓝牙提交结果未持久化');
          durable = await store!.results.advance(durable, 'history');
          _stillReceiving(offer, staged, activeToken);
        }
        final historyUs = historyTiming.elapsedMicroseconds;
        final receipt = <String, dynamic>{
          'id': id,
          'token': activeToken,
          'size': offer.size,
          'sha': offer.sha256,
        };
        _completed[id] = (receipt: receipt, file: saved);
        if (_completed.length > 8) _completed.remove(_completed.keys.first);
        await _abortIncoming();
        try {
          final finalAckTiming = Stopwatch()..start();
          await _emit({...receipt, 'k': 'file-complete'});
          if (durable != null) await _noteAckQueued(durable);
          _timingDiagnostic(
            'BT file timing direction=receive id=${id.substring(0, 8)} '
            'result=final-ack-enqueued bytes=${offer.size} chunks=$_receiveChunks '
            'totalUs=${_receiveTiming?.elapsedMicroseconds ?? 0} '
            'decodeUs=$_receiveDecodeUs appendUs=$_receiveAppendUs '
            'maxAppendUs=$_receiveMaxAppendUs ackQueueUs=$_receiveAckQueueUs '
            'commitUs=$commitUs historyUs=$historyUs '
            'finalAckQueueUs=${finalAckTiming.elapsedMicroseconds}',
          );
        } catch (e) {
          _timingDiagnostic(
            'BT file timing direction=receive id=${id.substring(0, 8)} '
            'result=final-ack-unknown bytes=${offer.size} '
            'chunks=$_receiveChunks totalUs=${_receiveTiming?.elapsedMicroseconds ?? 0} '
            'decodeUs=$_receiveDecodeUs appendUs=$_receiveAppendUs '
            'ackQueueUs=$_receiveAckQueueUs commitUs=$commitUs historyUs=$historyUs',
          );
          _progress(
            offer,
            true,
            offer.size,
            '失败 · 文件已保存，回执未确认',
            '${e.runtimeType}',
          );
          diagnostic?.call(
            'BT file committed/history persisted; final ACK not confirmed id=${id.substring(0, 8)}',
          );
          return;
        }
        _progress(offer, true, offer.size, '成功 · 已校验并保存');
      } else {
        throw StateError('Unsupported file message');
      }
    } catch (e) {
      final offer = _incoming;
      if (offer != null) {
        _timingDiagnostic(
          'BT file timing direction=receive id=${offer.id.substring(0, 8)} '
          'result=failed-${e.runtimeType} bytes=${_staged?.bytes ?? 0} '
          'chunks=$_receiveChunks totalUs=${_receiveTiming?.elapsedMicroseconds ?? 0} '
          'decodeUs=$_receiveDecodeUs appendUs=$_receiveAppendUs '
          'ackQueueUs=$_receiveAckQueueUs',
        );
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
    _sentComplete.clear();
    _resultAttempts.clear();
    _unconfirmed = null;
    _lateResult = null;
  }
}
