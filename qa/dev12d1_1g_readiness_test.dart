// LINYUE DEV12-D1 readiness assertions updated for DEV12-D2 pilot.
// Runs only metadata arithmetic and fake disk probes; does not allocate a GiB
// or modify the current 512 MiB production transfer, crypto or resume limits.
// Run: flutter test qa/dev12d1_1g_readiness_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/linear_resume_checkpoint.dart';
import 'package:nearlink/security/outbound_resume_controller.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';
import 'package:nearlink/security/resume_checkpoint.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'package:nearlink/services/disk_capacity_guard.dart';

const int _mib = 1024 * 1024;
const int _gib = 1024 * _mib;
const int _proposedTotalQuota = 2560 * _mib;

Map<String, dynamic> _v2Metadata(int total) => <String, dynamic>{
  'format': 'linyue-linear-checkpoint-v2',
  'id': 'a' * 32,
  'peer': 'b' * 64,
  'sourceSha256': 'c' * 64,
  'total': total,
  'step': linearCheckpointStepBytes,
  'generation': 0,
  'updatedUtc': DateTime.now().toUtc().toIso8601String(),
  'spans': <Map<String, Object>>[],
};

Map<String, dynamic> _v1Metadata(int total) => <String, dynamic>{
  'format': 'linyue-resume-checkpoint-v1',
  'id': 'a' * 32,
  'peer': 'b' * 64,
  'sha256': 'c' * 64,
  'total': total,
  'committed': 0,
  'prefixSha256':
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  'chunkBytes': resumeCheckpointChunkSize,
  'generation': 0,
  'updatedUtc': DateTime.now().toUtc().toIso8601String(),
};

void main() {
  test('D2 expands V2 only and keeps V1 512 MiB bounded', () {
    expect(secureFileMaxBytes, 20 * _mib);
    expect(secureStreamPilotMaxBytes, _gib);
    expect(outboundResumeMaxFileBytes, _gib);
    expect(resumeCheckpointMaxBytes, 512 * _mib);
    expect(linearCheckpointMaxBytes, _gib);
    expect(secureStreamPilotMaxBytes == _gib, isTrue);
    print('[DEV12-D1] EXISTING_512M_GUARDS_PASS max_mib=512 target_mib=1024');
  });

  test('legacy V1 stays bounded; V2 permits exactly 1 GiB', () {
    expect(ResumeCheckpoint.fromJson(_v1Metadata(512 * _mib)).totalBytes,
        512 * _mib);
    expect(
        () => ResumeCheckpoint.fromJson(_v1Metadata(_gib)),
        throwsFormatException,
        reason: 'do not blindly expand legacy resume records');
    expect(LinearCheckpointRecord.fromJson(_v2Metadata(512 * _mib)).total,
        512 * _mib);
    expect(LinearCheckpointRecord.fromJson(_v2Metadata(_gib)).total, _gib);
    expect(() => LinearCheckpointRecord.fromJson(_v2Metadata(_gib + 1)),
        throwsFormatException);
    print('[DEV12-D1] V1_V2_BOUNDARY_GUARDS_PASS');
  });

  test('proposed 1 GiB chunk and V2 span counts fit fixed-size metadata', () {
    expect(linearCheckpointChunkBytes, 256 * 1024);
    expect(linearCheckpointStepBytes, 4 * _mib);
    expect(_gib % linearCheckpointChunkBytes, 0);
    expect(_gib % linearCheckpointStepBytes, 0);
    final chunks = _gib ~/ linearCheckpointChunkBytes;
    final spans = _gib ~/ linearCheckpointStepBytes;
    expect(chunks, 4096);
    expect(spans, 256);

    // Inspect only encoded journal size: 256 digests, no GiB allocation.
    final proposed = _v2Metadata(_gib);
    proposed['generation'] = spans;
    proposed['spans'] = <Map<String, Object>>[
      for (var i = 1; i <= spans; i++)
        <String, Object>{'end': i * linearCheckpointStepBytes,
          'sha256': 'd' * 64},
    ];
    final jsonBytes = utf8.encode(jsonEncode(proposed)).length;
    expect(jsonBytes < 32768, isTrue,
        reason: 'the V2 production slot reader caps JSON at 32 KiB');
    print('[DEV12-D1] V2_1G_METADATA_PASS chunks=$chunks spans=$spans '
        'journal_bytes=$jsonBytes slot_limit_bytes=32768');
  });

  test('1 GiB plus 1 byte needs an additional authenticated final chunk', () {
    final over = _gib + 1;
    final chunks = (over + linearCheckpointChunkBytes - 1) ~/
        linearCheckpointChunkBytes;
    final spans = (over + linearCheckpointStepBytes - 1) ~/
        linearCheckpointStepBytes;
    expect(chunks, 4097);
    expect(spans, 257);
    expect(over > _gib, isTrue);
    // These are bounds for a future implementation, not a protocol change.
    print('[DEV12-D1] FUTURE_1G_PLUS_ONE_PASS chunks=$chunks spans=$spans');
  });

  test('new staging quota fits two 1 GiB tasks not three', () {
    final journal = OutboundResumeJournal(Directory.systemTemp);
    final controller = OutboundResumeController(
        journal: journal, sourcesDirectory: Directory.systemTemp);
    expect(journal.maxBytes, _gib);
    expect(controller.maxStagedBytes, 2560 * _mib);
    expect(controller.maxStagedBytes >= 2 * _gib, isTrue);
    expect(_proposedTotalQuota > 2 * _gib, isTrue);
    expect(_proposedTotalQuota - 2 * _gib, 512 * _mib);
    expect(() => OutboundResumeJournal(Directory.systemTemp,
        maxBytes: _gib + 1), throwsArgumentError);
    print('[DEV12-D1] STAGING_POLICY_REVIEW current_quota_mib=2560 '
        'proposed_quota_mib=2560 two_1g_jobs_fit_proposed=true '
        'note=dev12d2_pilot_enabled');
  });

  test('fake disk probe requires true target-volume room plus reserve', () async {
    final guard = DiskCapacityGuard(lookup: _freeAtExactBoundary);
    final result = await guard.requireRoom(
      destinationPath: 'simulated-target-volume', fileBytes: _gib);
    expect(result.additionalBytes, _gib);
    expect(result.reserveBytes, _gib ~/ 20);
    expect(result.enough, isTrue);
    print('[DEV12-D1] DISK_EXACT_BOUNDARY_PASS required_mib='
        '${(_gib + result.reserveBytes) / _mib}');
  });

  test('disk one byte short or unknown must refuse new 1 GiB write', () async {
    final reserve = _gib ~/ 20;
    final shortGuard = DiskCapacityGuard(
        lookup: (_) async => _gib + reserve - 1);
    final unknownGuard = DiskCapacityGuard(lookup: (_) async => null);
    await expectLater(
        shortGuard.requireRoom(destinationPath: 'test-target', fileBytes: _gib),
        throwsA(isA<DiskCapacityException>()));
    await expectLater(
        unknownGuard.requireRoom(destinationPath: 'test-target', fileBytes: _gib),
        throwsA(isA<DiskCapacityException>()));
    print('[DEV12-D1] DISK_FAIL_CLOSED_PASS unknown_and_short_refused=true');
  });

  test('trusted resume offset checks only outstanding volume bytes', () async {
    const previouslyVerified = 768 * _mib;
    final guard = DiskCapacityGuard(lookup: (_) async => 300 * _mib);
    final result = await guard.requireRoom(destinationPath: 'test-target',
        fileBytes: _gib, verifiedBytes: previouslyVerified);
    expect(result.additionalBytes, 256 * _mib);
    expect(result.reserveBytes, 32 * _mib);
    expect(result.enough, isTrue);
    await expectLater(
        guard.inspect(destinationPath: 'test-target', fileBytes: _gib,
            verifiedBytes: _gib + 1),
        throwsArgumentError);
    print('[DEV12-D1] RESUME_REMAINING_CAPACITY_PASS '
        'verified_mib=768 remaining_mib=256 reserve_mib=32');
  });

  test('1 GiB target needs Android/Windows live memory verification', () {
    // Arithmetic and metadata size cannot establish production peak RAM.
    // The 256 KiB chunk size merely provides a bounded *nominal* chunk.
    expect(_gib ~/ linearCheckpointChunkBytes, 4096);
    expect(linearCheckpointChunkBytes, lessThan(_mib));
    print('[DEV12-D1] LIVE_RAM_NOT_YET_VERIFIED '
        'must_check=Android_real_device,Windows_real_device '
        'note=no_gib_allocated_by_qa');
  });
}

Future<int?> _freeAtExactBoundary(String path) async =>
    _gib + (_gib ~/ 20);
