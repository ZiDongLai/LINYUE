import 'dart:io';
import 'bluetooth_file_store.dart';
import 'bluetooth_file_policy.dart';

/// Bounded picker/content-URI snapshot, never a LAN recovery source.
class BluetoothSourceStage {
  BluetoothSourceStage._(this.file, this._folder);
  final File file;
  final Directory _folder;
  static Future<BluetoothSourceStage> create({
    required Directory root,
    required String name,
    required int declaredSize,
    required Stream<List<int>> Function() read,
    int maxBytes = bluetoothFileMaxBytes,
  }) async {
    bluetoothFileName(name);
    if (!bluetoothValidFileLimit(maxBytes) ||
        declaredSize < 0 ||
        declaredSize > maxBytes) {
      throw StateError(
        '蓝牙单文件超过协商上限${bluetoothFileLimitLabel(maxBytes)}，不会改走局域网',
      );
    }
    await root.create(recursive: true);
    final folder = await root.createTemp('linyue_bt_send_');
    final file = File('${folder.path}${Platform.pathSeparator}$name');
    RandomAccessFile? output;
    try {
      output = await file.open(mode: FileMode.writeOnly);
      var written = 0;
      await for (final chunk in read()) {
        if (written + chunk.length > declaredSize ||
            written + chunk.length > maxBytes) {
          throw StateError('所选文件超过大小限制或内容已变化');
        }
        await output.writeFrom(chunk);
        written += chunk.length;
      }
      if (written != declaredSize) throw StateError('所选文件长度已变化');
      await output.flush();
      await output.close();
      output = null;
      return BluetoothSourceStage._(file, folder);
    } catch (_) {
      await output?.close();
      await folder.delete(recursive: true); // Only this createTemp child.
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (await _folder.exists()) await _folder.delete(recursive: true);
  }
}
