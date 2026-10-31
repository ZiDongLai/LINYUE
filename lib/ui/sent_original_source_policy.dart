import 'dart:io';

/// Selects an existing original file for sent-history preview.
///
/// Never stores paths to symlinks, transient picker copies, or files whose
/// size differs from the bytes that were just sent. It does not alter data.
final class SentOriginalSourcePolicy {
  SentOriginalSourcePolicy._();

  static Future<String?> resolve({
    required String? candidatePath,
    required Directory temporaryDirectory,
    required int expectedBytes,
  }) async {
    if (candidatePath == null || candidatePath.isEmpty || expectedBytes < 0) {
      return null;
    }
    try {
      // A symlink could be retargeted after transfer. Do not persist it.
      if (await FileSystemEntity.type(candidatePath, followLinks: false) !=
          FileSystemEntityType.file) return null;
      final original = File(candidatePath);
      if (await original.length() != expectedBytes) return null;
      final canonical = await original.resolveSymbolicLinks();
      final tempRoot = await temporaryDirectory.resolveSymbolicLinks();
      final sep = Platform.pathSeparator;
      final candidateCompare = Platform.isWindows ? canonical.toLowerCase() : canonical;
      final tempCompare = Platform.isWindows ? tempRoot.toLowerCase() : tempRoot;
      final prefix = tempCompare.endsWith(sep) ? tempCompare : '$tempCompare$sep';
      if (candidateCompare == tempCompare || candidateCompare.startsWith(prefix)) {
        return null;
      }
      return canonical;
    } on FileSystemException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}
