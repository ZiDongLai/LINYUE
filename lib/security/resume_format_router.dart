/// DEV12-C3B V1/V2 checkpoint selection. No implicit migration or overwrite.
import 'dart:io';

import 'resume_checkpoint.dart';
import 'linear_resume_checkpoint.dart';

enum ResumeCheckpointFormat { legacyV1, linearV2 }

class ResumeFormatRouter {
  ResumeFormatRouter(this.directory);
  final Directory directory;

  /// Any partial checkpoint state counts: a missing .part accompanied by a
  /// surviving slot is a CORRUPT record, not permission to start over.
  Future<ResumeCheckpointFormat> choose(String id) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
      throw const FormatException('invalid resume task id');
    }
    final legacy = ResumeCheckpointStore(directory);
    final linear = LinearResumeCheckpointStore(directory);
    final v1Files = <File>[
      legacy.partFile(id),
      File('${directory.path}${Platform.pathSeparator}.linyue_resume_$id.a.json'),
      File('${directory.path}${Platform.pathSeparator}.linyue_resume_$id.b.json'),
    ];
    final v2Files = <File>[
      linear.partFile(id),
      File('${directory.path}${Platform.pathSeparator}.linyue_resume_v2_$id.a.json'),
      File('${directory.path}${Platform.pathSeparator}.linyue_resume_v2_$id.b.json'),
    ];
    Future<bool> hasAny(List<File> files) async {
      var found = false;
      for (final f in files) {
        final type = await FileSystemEntity.type(f.path, followLinks: false);
        if (type == FileSystemEntityType.link ||
            (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file)) {
          throw StateError('unsafe resume record type');
        }
        if (type == FileSystemEntityType.file) found = true;
      }
      return found;
    }
    final v1 = await hasAny(v1Files);
    final v2 = await hasAny(v2Files);
    if (v1 && v2) throw StateError('conflicting V1 and V2 checkpoints');
    // Existing filename consent without a trusted journal is not a new task.
    if (!v1 && !v2) {
      final consent = File('${directory.path}${Platform.pathSeparator}.linyue_resume_$id.name');
      if (await FileSystemEntity.type(consent.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('orphaned consent: checkpoint missing');
      }
    }
    return v1 ? ResumeCheckpointFormat.legacyV1 : ResumeCheckpointFormat.linearV2;
  }
}
