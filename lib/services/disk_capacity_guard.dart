/// DEV11-B2 real filesystem free-space probe and non-destructive preflight.
/// The query must target the *destination* volume, not device-global total.
/// Free space is a snapshot; write failures must still be handled safely.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:disk_usage/disk_usage.dart';

typedef DiskSpaceLookup = Future<int?> Function(String path);

const _windowsDiskCapacityChannel = MethodChannel('nearlink/disk_capacity');

class DiskCapacitySnapshot {
  const DiskCapacitySnapshot({
    required this.freeBytes,
    required this.additionalBytes,
    required this.reserveBytes,
    this.lookupError,
  });
  final int? freeBytes;
  final int additionalBytes;
  final int reserveBytes;
  final String? lookupError;
  bool get measurable => freeBytes != null;
  bool get enough => measurable && freeBytes! >= additionalBytes + reserveBytes;
}

class _DiskSpaceProbe {
  const _DiskSpaceProbe(this.freeBytes, this.error);
  final int? freeBytes;
  final String? error;
}

class DiskCapacityException extends StateError {
  DiskCapacityException(String message) : super(message);
}

class DiskCapacityGuard {
  const DiskCapacityGuard({
    this.lookup,
    this.minimumReserveBytes = 32 * 1024 * 1024,
  });
  final DiskSpaceLookup? lookup;
  final int minimumReserveBytes;

  Future<int?> availableBytes(String destinationPath) async {
    return (await _probeAvailableBytes(destinationPath)).freeBytes;
  }

  Future<_DiskSpaceProbe> _probeAvailableBytes(String destinationPath) async {
    if (destinationPath.trim().isEmpty) {
      return const _DiskSpaceProbe(null, '目标目录路径为空');
    }
    try {
      final int? available =
          await (lookup != null
                  ? lookup!(destinationPath)
                  : Platform.isWindows
                  ? _windowsDiskCapacityChannel.invokeMethod<int>(
                      'availableBytes',
                      {'path': destinationPath},
                    )
                  : DiskUsage.freeSpace(destinationPath))
              .timeout(const Duration(seconds: 5));
      if (available == null) {
        return const _DiskSpaceProbe(null, '查询接口未返回结果');
      }
      if (available < 0) {
        return const _DiskSpaceProbe(null, '查询接口返回了无效空间值');
      }
      return _DiskSpaceProbe(available, null);
    } on PlatformException catch (error) {
      final message = error.message;
      final detail = message == null || message.isEmpty
          ? error.code
          : '${error.code}: $message';
      return _DiskSpaceProbe(null, detail);
    } on MissingPluginException {
      return const _DiskSpaceProbe(null, '磁盘空间查询组件未加载');
    } catch (error) {
      // Plugin absent, inaccessible volume or filesystem error.
      return _DiskSpaceProbe(null, error.runtimeType.toString());
    }
  }

  Future<DiskCapacitySnapshot> inspect({
    required String destinationPath,
    required int fileBytes,
    int verifiedBytes = 0,
  }) async {
    if (fileBytes < 0 ||
        verifiedBytes < 0 ||
        verifiedBytes > fileBytes ||
        minimumReserveBytes < 0) {
      throw ArgumentError('invalid disk preflight size / offset');
    }
    final remaining = fileBytes - verifiedBytes;
    final reserve = math.max(minimumReserveBytes, remaining ~/ 20);
    final probe = await _probeAvailableBytes(destinationPath);
    return DiskCapacitySnapshot(
      freeBytes: probe.freeBytes,
      additionalBytes: remaining,
      reserveBytes: reserve,
      lookupError: probe.error,
    );
  }

  /// Unknown space is NOT assumed sufficient for new large-file writes.
  Future<DiskCapacitySnapshot> requireRoom({
    required String destinationPath,
    required int fileBytes,
    int verifiedBytes = 0,
  }) async {
    final data = await inspect(
      destinationPath: destinationPath,
      fileBytes: fileBytes,
      verifiedBytes: verifiedBytes,
    );
    if (!data.measurable) {
      final detail = data.lookupError == null ? '' : '（${data.lookupError}）';
      throw DiskCapacityException('无法读取目标目录所在磁盘的真实可用空间，已停止写入$detail');
    }
    if (!data.enough) {
      final fmt = (int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
      throw DiskCapacityException(
        '目标磁盘空间不足：可用 ${fmt(data.freeBytes!)} MiB，'
        '需写入 ${fmt(data.additionalBytes)} MiB，'
        '预留 ${fmt(data.reserveBytes)} MiB；已停止传输',
      );
    }
    return data;
  }
}
