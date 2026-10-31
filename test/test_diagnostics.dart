import 'dart:io';

/// The runner supplies a NEW per-command directory. Direct test invocations use
/// an OS temporary child, never a sealed audit directory.
Future<Directory> testDiagnosticsDirectory() async {
  final configured = Platform.environment['LINYUE_TEST_DIAGNOSTICS'];
  if (configured == null || configured.isEmpty) {
    return Directory.systemTemp.createTemp('linyue_test_diagnostics_');
  }
  return Directory(configured).create(recursive: true);
}
