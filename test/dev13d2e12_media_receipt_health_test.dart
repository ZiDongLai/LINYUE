import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/media_receipt_health.dart';
import 'package:nearlink/services/mobile_media_source_policy.dart';

void main() {
  late Directory temporary;
  late Directory stagedRoot;
  late Directory receipts;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('linyue_e12_');
    stagedRoot = Directory('${temporary.path}${Platform.pathSeparator}LinYuePickedImages');
    receipts = Directory('${temporary.path}${Platform.pathSeparator}'
        '${MobileMediaSourcePolicy.receiptDirectoryName}');
  });
  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Future<File> stage(String name) async {
    final source = File('${temporary.path}${Platform.pathSeparator}$name');
    await source.writeAsBytes([1, 3, 5, 7], flush: true);
    return MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: stagedRoot,
        displayName: name, receiptDirectory: receipts);
  }

  test('read-only healthy receipt preserves original and stage', () async {
    final file = await stage('photo.jpg');
    final result = await MediaReceiptHealth.inspect(
        pickedMediaDirectory: stagedRoot, receiptDirectory: receipts);
    expect(result.complete, isTrue);
    expect(result.intactReceipts, 1);
    expect(result.intactBytes, 4);
    expect(result.orphanReceipts, 0);
    expect(result.invalidReceipts, 0);
    expect(await file.readAsBytes(), [1, 3, 5, 7]);
    expect(await MobileMediaSourcePolicy.receiptFor(file, receipts).exists(), isTrue);
  });

  test('missing stage is diagnosed but never deleted or modified', () async {
    final file = await stage('clip.mp4');
    final receipt = MobileMediaSourcePolicy.receiptFor(file, receipts);
    await file.delete();
    final report = await MediaReceiptHealth.inspect(
        pickedMediaDirectory: stagedRoot, receiptDirectory: receipts);
    expect(report.complete, isTrue);
    expect(report.orphanReceipts, 1);
    expect(await receipt.exists(), isTrue);
  });

  test('mismatched receipt size is not treated as intact', () async {
    final file = await stage('clip.mp4');
    final receipt = MobileMediaSourcePolicy.receiptFor(file, receipts);
    final data = jsonDecode(await receipt.readAsString()) as Map<String, dynamic>;
    data['bytes'] = 700;
    await receipt.writeAsString(jsonEncode(data), flush: true);
    final report = await MediaReceiptHealth.inspect(
        pickedMediaDirectory: stagedRoot, receiptDirectory: receipts);
    expect(report.intactReceipts, 0);
    expect(report.invalidReceipts, 1);
    expect(await file.length(), 4);
  });

  test('malformed json and unexpected filenames are invalid', () async {
    await receipts.create(recursive: true);
    await File('${receipts.path}${Platform.pathSeparator}broken.json')
        .writeAsString('{broken', flush: true);
    final report = await MediaReceiptHealth.inspect(
        pickedMediaDirectory: stagedRoot, receiptDirectory: receipts);
    expect(report.complete, isTrue);
    expect(report.invalidReceipts, 1);
  });

  test('missing receipt root is a valid empty report', () async {
    final report = await MediaReceiptHealth.inspect(
        pickedMediaDirectory: stagedRoot, receiptDirectory: receipts);
    expect(report.complete, isTrue);
    expect(report.inspectedReceipts, 0);
  });

  test('scan cap fails closed and suppresses health totals', () async {
    await stage('a.jpg');
    await stage('b.jpg');
    final report = await MediaReceiptHealth.inspect(
        pickedMediaDirectory: stagedRoot, receiptDirectory: receipts,
        maxReceipts: 1);
    expect(report.complete, isFalse);
    expect(report.intactReceipts, 0);
    expect(report.orphanReceipts, 0);
  });
}
