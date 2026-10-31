import 'dart:convert';
import 'package:crypto/crypto.dart' as hashes;
import '../../security/secure_core.dart' show secureRandomBytes;
import '../../services/received_file_actions.dart';
import '../bluetooth_file_policy.dart' show bluetoothDefaultFileBytes;

const btCheckpointSchema = 'linyue-bt-checkpoint-p0-v1';
const btCheckpointEmptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
final _id = RegExp(r'^[a-f0-9]{32}$');
final _sha = RegExp(r'^[a-f0-9]{64}$');

enum BtCheckpointRole { sender, receiver }

enum BtCheckpointStatus {
  created,
  active,
  paused,
  completed,
  cancelled,
  failed,
  expired,
}

extension BtCheckpointTerminal on BtCheckpointStatus {
  bool get isTerminal => const {
    BtCheckpointStatus.completed,
    BtCheckpointStatus.cancelled,
    BtCheckpointStatus.failed,
    BtCheckpointStatus.expired,
  }.contains(this);
}

void _shape(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    throw const FormatException('Checkpoint fields missing or unsupported');
  }
}

/// Identity binding only, NOT evidence of a trusted/connected peer.
/// Source/data bindings are local opaque IDs, never user-supplied paths.
class BtCheckpointIdentity {
  BtCheckpointIdentity({
    required this.taskId,
    required this.localFingerprint,
    required this.peerFingerprint,
    required this.role,
    required this.fileName,
    required this.fileSize,
    required this.fileSha256,
    required this.dataBinding,
    this.sourceBinding,
    this.transport = 'bluetooth',
  }) {
    if (!_id.hasMatch(taskId) ||
        !_id.hasMatch(dataBinding) ||
        !_sha.hasMatch(localFingerprint) ||
        !_sha.hasMatch(peerFingerprint) ||
        localFingerprint == peerFingerprint ||
        transport != 'bluetooth' ||
        fileSize < 0 ||
        fileSize > bluetoothDefaultFileBytes ||
        !_sha.hasMatch(fileSha256) ||
        (sourceBinding != null && !_id.hasMatch(sourceBinding!)) ||
        (role == BtCheckpointRole.sender && sourceBinding == null) ||
        ReceivedFileActions.validateFileName(fileName) != fileName ||
        fileName.length > 120 ||
        fileName.startsWith('.') ||
        fileName.endsWith('.part') ||
        fileName.endsWith('.writing')) {
      throw const FormatException('Invalid P0 task identity/content/route');
    }
  }
  static String newId() => secureRandomBytes(
    16,
  ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  final String taskId, localFingerprint, peerFingerprint, fileName, fileSha256;
  final String transport, dataBinding;
  final String? sourceBinding;
  final BtCheckpointRole role;
  final int fileSize;
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'transport': transport,
    'local': localFingerprint,
    'peer': peerFingerprint,
    'role': role.name,
    'name': fileName,
    'size': fileSize,
    'sha256': fileSha256,
    'dataBinding': dataBinding,
    'sourceBinding': sourceBinding,
  };
  bool sameAs(BtCheckpointIdentity other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
  factory BtCheckpointIdentity.fromJson(Map<String, dynamic> m) {
    _shape(m, {
      'taskId',
      'transport',
      'local',
      'peer',
      'role',
      'name',
      'size',
      'sha256',
      'dataBinding',
      'sourceBinding',
    });
    if (m['taskId'] is! String ||
        m['transport'] is! String ||
        m['local'] is! String ||
        m['peer'] is! String ||
        m['role'] is! String ||
        m['name'] is! String ||
        m['size'] is! int ||
        m['sha256'] is! String ||
        m['dataBinding'] is! String ||
        (m['sourceBinding'] != null && m['sourceBinding'] is! String)) {
      throw const FormatException('Invalid P0 identity types');
    }
    return BtCheckpointIdentity(
      taskId: m['taskId'],
      transport: m['transport'],
      localFingerprint: m['local'],
      peerFingerprint: m['peer'],
      role: BtCheckpointRole.values.byName(m['role']),
      fileName: m['name'],
      fileSize: m['size'],
      fileSha256: m['sha256'],
      dataBinding: m['dataBinding'],
      sourceBinding: m['sourceBinding'],
    );
  }
}

/// No session key, token, frame sequence, LAN task or transfer success receipt.
/// `completed` is an explicitly sealed LOCAL P0 lifecycle, not an E38 ACK.
class BtCheckpointRecord {
  BtCheckpointRecord({
    required this.identity,
    required this.generation,
    required this.previousHash,
    required this.offset,
    required this.prefixSha256,
    required this.status,
    required DateTime createdUtc,
    required DateTime updatedUtc,
    this.terminalReason,
  }) : createdUtc = createdUtc.toUtc(),
       updatedUtc = updatedUtc.toUtc() {
    if (generation < 0 ||
        generation > 255 ||
        (generation == 0 ? previousHash != '' : !_sha.hasMatch(previousHash)) ||
        offset < 0 ||
        offset > identity.fileSize ||
        !_sha.hasMatch(prefixSha256) ||
        (offset == 0 && prefixSha256 != btCheckpointEmptySha256) ||
        (offset == identity.fileSize && prefixSha256 != identity.fileSha256) ||
        this.createdUtc.isBefore(DateTime.utc(2020)) ||
        this.updatedUtc.isBefore(this.createdUtc) ||
        (status == BtCheckpointStatus.created &&
            (offset != 0 || generation != 0)) ||
        (status == BtCheckpointStatus.completed &&
            offset != identity.fileSize) ||
        (status.isTerminal
            ? terminalReason == null || terminalReason!.isEmpty
            : terminalReason != null) ||
        (terminalReason != null &&
            (terminalReason!.length > 160 ||
                RegExp(r'[\x00-\x1f]').hasMatch(terminalReason!)))) {
      throw const FormatException('Invalid P0 state/offset/generation');
    }
  }
  final BtCheckpointIdentity identity;
  final int generation, offset;
  final String previousHash, prefixSha256;
  final BtCheckpointStatus status;
  final DateTime createdUtc, updatedUtc;
  final String? terminalReason;
  Map<String, dynamic> toJson() => {
    'schema': btCheckpointSchema,
    'identity': identity.toJson(),
    'generation': generation,
    'previousHash': previousHash,
    'offset': offset,
    'prefixSha256': prefixSha256,
    'status': status.name,
    'createdUtc': createdUtc.toIso8601String(),
    'updatedUtc': updatedUtc.toIso8601String(),
    'terminalReason': terminalReason,
  };
  String get digest =>
      hashes.sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
  void validateNext(BtCheckpointRecord next) {
    if (!identity.sameAs(next.identity) ||
        next.generation != generation + 1 ||
        next.previousHash != digest ||
        next.createdUtc != createdUtc ||
        next.updatedUtc.isBefore(updatedUtc) ||
        next.offset < offset ||
        (next.offset == offset && next.prefixSha256 != prefixSha256) ||
        status.isTerminal ||
        next.status == BtCheckpointStatus.created) {
      throw StateError(
        'P0 update regresses, conflicts or changes a terminal task',
      );
    }
  }

  factory BtCheckpointRecord.fromJson(Map<String, dynamic> m) {
    _shape(m, {
      'schema',
      'identity',
      'generation',
      'previousHash',
      'offset',
      'prefixSha256',
      'status',
      'createdUtc',
      'updatedUtc',
      'terminalReason',
    });
    if (m['schema'] != btCheckpointSchema ||
        m['identity'] is! Map<String, dynamic> ||
        m['generation'] is! int ||
        m['previousHash'] is! String ||
        m['offset'] is! int ||
        m['prefixSha256'] is! String ||
        m['status'] is! String ||
        m['createdUtc'] is! String ||
        m['updatedUtc'] is! String ||
        (m['terminalReason'] != null && m['terminalReason'] is! String)) {
      throw const FormatException('Unsupported P0 schema or field types');
    }
    return BtCheckpointRecord(
      identity: BtCheckpointIdentity.fromJson(m['identity']),
      generation: m['generation'],
      previousHash: m['previousHash'],
      offset: m['offset'],
      prefixSha256: m['prefixSha256'],
      status: BtCheckpointStatus.values.byName(m['status']),
      createdUtc: DateTime.parse(m['createdUtc']),
      updatedUtc: DateTime.parse(m['updatedUtc']),
      terminalReason: m['terminalReason'],
    );
  }
}
