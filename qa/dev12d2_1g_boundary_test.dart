// DEV12-D2: fast boundary tests. No GiB allocation; use real 1GiB opt-in QA separately.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/secure_file_channel.dart';
import 'package:nearlink/security/resume_checkpoint.dart';
import 'package:nearlink/security/linear_resume_checkpoint.dart';
import 'package:nearlink/security/outbound_resume_journal.dart';
import 'package:nearlink/security/outbound_resume_controller.dart';
import 'package:nearlink/security/resume_completion_receipt.dart';

const _mib = 1024 * 1024;
void main() {
  test('V2 is 1GiB, but V1 legacy remains capped at 512MiB', () {
    expect(secureStreamPilotMaxBytes, 1024 * _mib);
    expect(secureLegacyStreamMaxBytes, 512 * _mib);
    expect(resumeCheckpointMaxBytes, 512 * _mib);
    expect(linearCheckpointMaxBytes, 1024 * _mib);
    expect(outboundResumeMaxFileBytes, 1024 * _mib);
    final journal = OutboundResumeJournal(Directory.systemTemp);
    final controller = OutboundResumeController(
        journal: journal, sourcesDirectory: Directory.systemTemp);
    expect(journal.maxBytes, 1024 * _mib);
    expect(controller.maxStagedBytes, 2560 * _mib);
    print('[DEV12-D2] CAPS_PASS v2_mib=1024 v1_mib=512 quota_mib=2560');
  });
  test('V2 1GiB complete receipt is valid, 1GiB+1 rejected', () {
    final original = ResumeCompletionReceipt(taskId: 'a' * 32,
        peer: 'b' * 64, sha256: 'c' * 64, size: 1024 * _mib,
        originalName: 'one.bin', savedName: 'one.bin');
    expect(() => original.validate(), returnsNormally);
    expect(() => ResumeCompletionReceipt.fromJson({
      ...original.toJson(), 'size': 1024 * _mib + 1,
    }), throwsFormatException);
    print('[DEV12-D2] RECEIPT_BOUNDARY_PASS');
  });
}
