import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// E12: independent read-only health check for E11+ source receipts.
/// A healthy receipt is proof of origin metadata, NOT a deletion permit.
final class MediaReceiptHealthResult {
  const MediaReceiptHealthResult({
    required this.complete,
    required this.inspectedReceipts,
    required this.intactReceipts,
    required this.intactBytes,
    required this.orphanReceipts,
    required this.invalidReceipts,
  });

  final bool complete;
  final int inspectedReceipts;
  final int intactReceipts;
  final int intactBytes;
  final int orphanReceipts;
  final int invalidReceipts;
}

final class MediaReceiptHealth {
  MediaReceiptHealth._();

  static const int maximumReceipts = 2500;
  static final RegExp _receiptName = RegExp(r'^[a-f0-9]{64}\.json$');
  static final RegExp _stagedName = RegExp(
      r'^\d{13,20}_\d{1,12}_.+\.(jpg|jpeg|png|gif|webp|heic|heif|bmp|mp4|m4v|mov|3gp|3g2|webm|mkv|avi|wmv|mpg|mpeg)$',
      caseSensitive: false);

  /// Never opens a media file to write; never mutates or deletes any file.
  static Future<MediaReceiptHealthResult> inspect({
    required Directory pickedMediaDirectory,
    required Directory receiptDirectory,
    int maxReceipts = maximumReceipts,
  }) async {
    if (maxReceipts < 1) throw ArgumentError.value(maxReceipts, 'maxReceipts');
    const empty = MediaReceiptHealthResult(
        complete: true, inspectedReceipts: 0, intactReceipts: 0,
        intactBytes: 0, orphanReceipts: 0, invalidReceipts: 0);

    final receiptType = await FileSystemEntity.type(
        receiptDirectory.path, followLinks: false);
    if (receiptType == FileSystemEntityType.notFound) return empty;
    if (receiptType != FileSystemEntityType.directory) {
      return const MediaReceiptHealthResult(
          complete: false, inspectedReceipts: 0, intactReceipts: 0,
          intactBytes: 0, orphanReceipts: 0, invalidReceipts: 0);
    }
    final pickedType = await FileSystemEntity.type(
        pickedMediaDirectory.path, followLinks: false);
    if (pickedType != FileSystemEntityType.directory &&
        pickedType != FileSystemEntityType.notFound) {
      return const MediaReceiptHealthResult(
          complete: false, inspectedReceipts: 0, intactReceipts: 0,
          intactBytes: 0, orphanReceipts: 0, invalidReceipts: 0);
    }
    var complete = true;
    var inspected = 0;
    var intact = 0;
    var intactBytes = 0;
    var orphan = 0;
    var invalid = 0;
    try {
      await for (final entity in receiptDirectory.list(followLinks: false)) {
        if (inspected >= maxReceipts) {
          complete = false;
          break;
        }
        inspected++;
        try {
          if (await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
            // A symlink or unexpected nested directory is never trusted.
            complete = false;
            continue;
          }
          final leaf = entity.uri.pathSegments.last;
          final size = await File(entity.path).length();
          if (!_receiptName.hasMatch(leaf) || size <= 0 || size > 4096) {
            invalid++;
            continue;
          }
          final data = jsonDecode(await File(entity.path).readAsString());
          if (data is! Map<String, dynamic>) {
            invalid++;
            continue;
          }
          final storedName = data['storedName'];
          final bytes = data['bytes'];
          final created = data['createdAtUtc'];
          if (data['schema'] != 1 ||
              data['producer'] != 'linyue-mobile-stage' ||
              storedName is! String || !_stagedName.hasMatch(storedName) ||
              storedName.contains('/') || storedName.contains('\\') ||
              bytes is! int || bytes <= 0 || bytes > 1024 * 1024 * 1024 ||
              created is! String || DateTime.tryParse(created) == null ||
              leaf != '${sha256.convert(utf8.encode(storedName))}.json') {
            invalid++;
            continue;
          }
          final staged = File('${pickedMediaDirectory.path}'
              '${Platform.pathSeparator}$storedName');
          final stagedType = await FileSystemEntity.type(
              staged.path, followLinks: false);
          if (stagedType == FileSystemEntityType.notFound) {
            orphan++;
          } else if (stagedType == FileSystemEntityType.file) {
            if (await staged.length() == bytes) {
              intact++;
              intactBytes += bytes;
            } else {
              invalid++;
            }
          } else {
            complete = false;
          }
        } catch (_) {
          // An unreadable or malformed JSON receipt is never a valid record.
          invalid++;
        }
      }
    } catch (_) {
      complete = false;
    }
    return MediaReceiptHealthResult(
        complete: complete, inspectedReceipts: inspected,
        intactReceipts: complete ? intact : 0,
        intactBytes: complete ? intactBytes : 0,
        orphanReceipts: complete ? orphan : 0,
        invalidReceipts: complete ? invalid : 0);
  }
}
