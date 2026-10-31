import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';
import 'package:nearlink/security/outbound_resume_controller.dart';
import 'package:nearlink/security/resume_checkpoint.dart';
import 'package:nearlink/security/secure_chunk_stream.dart';
import 'package:nearlink/security/linear_resume_checkpoint.dart';
import 'package:nearlink/security/resume_completion_receipt.dart';

void main() {
  const mib = 1024 * 1024;
  test('1 GiB new V2 limits align while legacy V1 stays 512 MiB', () {
    expect(secureFileMaxBytes, 20 * mib);
    expect(secureStreamPilotMaxBytes, 1024 * mib);
    expect(outboundResumeMaxFileBytes, secureStreamPilotMaxBytes);
    expect(resumeCheckpointMaxBytes, 512 * mib);
    expect(linearCheckpointMaxBytes, secureStreamPilotMaxBytes);
    expect(linyueStreamMaxBytes >= secureStreamPilotMaxBytes, isTrue);
    expect(resumeCheckpointChunkSize, 256 * 1024);
  });

  test('journal accepts 1GiB and rejects 1GiB plus one byte', () {
    final j = OutboundResumeJournal(Directory.systemTemp);
    expect(j.maxBytes, 1024 * mib);
    expect(() => OutboundResumeJournal(Directory.systemTemp,
      maxBytes: 1024 * mib + 1), throwsArgumentError);
  });

  test('checkpoint accepts 512MiB metadata but rejects 512MiB+1', () {
    final data = <String, dynamic>{
      'format': 'linyue-resume-checkpoint-v1',
      'id': List<String>.filled(32, 'a').join(),
      'peer': List<String>.filled(64, 'b').join(),
      'sha256': List<String>.filled(64, 'c').join(),
      'total': 512 * mib,
      'committed': 0,
      'prefixSha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'chunkBytes': 256 * 1024,
      'generation': 0,
      'updatedUtc': DateTime.now().toUtc().toIso8601String(),
    };
    expect(ResumeCheckpoint.fromJson(data).totalBytes, 512 * mib);
    expect(() => ResumeCheckpoint.fromJson({...data, 'total': 512 * mib + 1}),
      throwsFormatException);
  });

  test('staging quota allows two 1GiB files, rejects three', () {
    final ctrl = OutboundResumeController(journal:
      OutboundResumeJournal(Directory.systemTemp),
      sourcesDirectory: Directory.systemTemp);
    expect(ctrl.maxStagedBytes, 2560 * mib);
    expect(2 * secureStreamPilotMaxBytes <= ctrl.maxStagedBytes, isTrue);
    expect(3 * secureStreamPilotMaxBytes > ctrl.maxStagedBytes, isTrue);
  });

  test('V2 metadata and completed receipt accept 1 GiB; reject +1 byte', () {
    final base = <String, dynamic>{
      'format': 'linyue-linear-checkpoint-v2',
      'id': 'a' * 32, 'peer': 'b' * 64, 'sourceSha256': 'c' * 64,
      'total': 1024 * mib, 'step': linearCheckpointStepBytes,
      'generation': 0, 'updatedUtc': DateTime.now().toUtc().toIso8601String(),
      'spans': <Map<String, Object>>[],
    };
    expect(LinearCheckpointRecord.fromJson(base).total, 1024 * mib);
    expect(() => LinearCheckpointRecord.fromJson({...base, 'total': 1024 * mib + 1}),
        throwsFormatException);
    final receipt = ResumeCompletionReceipt(taskId: 'a' * 32,
      peer: 'b' * 64, sha256: 'c' * 64,
      size: 1024 * mib, originalName: 'big.bin', savedName: 'big.bin');
    expect(() => receipt.validate(), returnsNormally);
    expect(() => ResumeCompletionReceipt.fromJson({
      ...receipt.toJson(), 'size': 1024 * mib + 1,
    }), throwsFormatException);
  });

}
