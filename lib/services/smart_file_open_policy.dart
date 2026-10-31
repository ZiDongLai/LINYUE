import 'received_file_actions.dart';

/// E16: presentation policy for explicit user requests to open common documents.
///
/// This never invokes applications itself. All paths, file existence and Android
/// receive-root checks remain enforced by the existing open services. It only
/// removes the redundant app-level confirmation for well-known *document*
/// types; unknown and media types retain their established confirmation.
final class SmartFileOpenPolicy {
  SmartFileOpenPolicy._();

  static const Map<String, String> _documentKinds = <String, String>{
    'pdf': 'PDF',
    'doc': 'Word', 'docx': 'Word',
    'xls': '表格', 'xlsx': '表格', 'csv': '表格',
    'ppt': '演示文稿', 'pptx': '演示文稿',
    'txt': '文本', 'md': '文本', 'rtf': '文本',
  };

  static String? documentKind(String fileName) {
    final name = fileName.trim();
    if (!ReceivedFileActions.mayOpenWithSystem(name)) return null;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return _documentKinds[name.substring(dot + 1).toLowerCase()];
  }

  static bool isQuickDocument(String fileName) => documentKind(fileName) != null;

  /// Request system default handler directly for common documents. Android's
  /// ACTION_VIEW resolver handles installed alternatives; lack of a handler
  /// must be explained to the user, not silently ignored.
  static String actionLabel(String fileName, {required bool isAndroid}) {
    final kind = documentKind(fileName);
    if (kind != null) return '直接打开$kind文件';
    return isAndroid ? '用其他应用打开' : '用系统默认应用打开';
  }
}
