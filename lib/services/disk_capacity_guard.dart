/// DEV11-B2 real filesystem free-space probe and non-destructive preflight.
/// The query must target the *destination* volume, not device-global total.
/// Free space is a snapshot; write failures must still be handled safely.
import 'dart:async';
import 'dart:math' as math;
import 'package:disk_usage/disk_usage.dart';

typedef DiskSpaceLookup = Future<int?> Function(String path);

class DiskCapacitySnapshot {
  const DiskCapacitySnapshot({required this.freeBytes,
    required this.additionalBytes, required this.reserveBytes});
  final int? freeBytes;
  final int additionalBytes;
  final int reserveBytes;
  bool get measurable => freeBytes != null;
  bool get enough => measurable && freeBytes! >= additionalBytes + reserveBytes;
}

class DiskCapacityException extends StateError {
  DiskCapacityException(String message) : super(message);
}

class DiskCapacityGuard {
  const DiskCapacityGuard({this.lookup,
    this.minimumReserveBytes = 32 * 1024 * 1024});
  final DiskSpaceLookup? lookup;
  final int minimumReserveBytes;

  Future<int?> availableBytes(String destinationPath) async {
    if (destinationPath.trim().isEmpty) return null;
    try {
      final int? available = await (lookup != null
        ? lookup!(destinationPath) : DiskUsage.freeSpace(destinationPath))
        .timeout(const Duration(seconds: 5));
      if (available == null || available < 0) return null;
      return available;
    } catch (_) { // Plugin absent, inaccessible volume or filesystem error.
      return null;
    }
  }

  Future<DiskCapacitySnapshot> inspect({required String destinationPath,
    required int fileBytes, int verifiedBytes = 0}) async {
    if (fileBytes < 0 || verifiedBytes < 0 || verifiedBytes > fileBytes ||
        minimumReserveBytes < 0) {
      throw ArgumentError('invalid disk preflight size / offset');
    }
    final remaining = fileBytes - verifiedBytes;
    final reserve = math.max(minimumReserveBytes, remaining ~/ 20);
    return DiskCapacitySnapshot(freeBytes: await availableBytes(destinationPath),
      additionalBytes: remaining, reserveBytes: reserve);
  }

  /// Unknown space is NOT assumed sufficient for new large-file writes.
  Future<DiskCapacitySnapshot> requireRoom({required String destinationPath,
    required int fileBytes, int verifiedBytes = 0}) async {
    final data = await inspect(destinationPath: destinationPath,
      fileBytes: fileBytes, verifiedBytes: verifiedBytes);
    if (!data.measurable) {
      throw DiskCapacityException('无法读取目标目录所在磁盘的真实可用空间，已停止写入');
    }
    if (!data.enough) {
      final fmt = (int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
      throw DiskCapacityException('目标磁盘空间不足：可用 ${fmt(data.freeBytes!)} MiB，'
        '需写入 ${fmt(data.additionalBytes)} MiB，'
        '预留 ${fmt(data.reserveBytes)} MiB；已停止传输');
    }
    return data;
  }
}
