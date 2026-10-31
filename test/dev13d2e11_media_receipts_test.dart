import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/media_copy_audit.dart';
import 'package:nearlink/services/mobile_media_source_policy.dart';

void main() {
  late Directory temp;
  late Directory stagedRoot;
  late Directory receipts;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('linyue_e11_');
    stagedRoot = Directory('${temp.path}${Platform.pathSeparator}LinYuePickedImages');
    receipts = Directory('${temp.path}${Platform.pathSeparator}'
        '${MobileMediaSourcePolicy.receiptDirectoryName}');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> createMedia(String name, List<int> bytes) async {
    final source = File('${temp.path}${Platform.pathSeparator}$name');
    await source.writeAsBytes(bytes, flush: true);
    return source;
  }

  test('photo staging produces an independent receipt with exact size', () async {
    final source = await createMedia('photo.jpg', [1, 2, 4, 8]);
    final staged = await MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: stagedRoot,
        displayName: 'photo.jpg', receiptDirectory: receipts);
    final receipt = MobileMediaSourcePolicy.receiptFor(staged, receipts);
    final json = jsonDecode(await receipt.readAsString()) as Map<String, dynamic>;
    expect(json['schema'], 1);
    expect(json['bytes'], 4);
    expect(json['storedName'], staged.uri.pathSegments.last);
    expect(await source.readAsBytes(), [1, 2, 4, 8]);
    expect(await staged.readAsBytes(), [1, 2, 4, 8]);
  });

  test('audit distinguishes newly registered and legacy old media', () async {
    final source = await createMedia('clip.mp4', [3, 2, 1]);
    final staged = await MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: stagedRoot,
        displayName: 'clip.mp4', receiptDirectory: receipts);
    await staged.setLastModified(DateTime.now().subtract(const Duration(days: 8)));
    final legacy = File('${stagedRoot.path}${Platform.pathSeparator}'
        '1234567890123456_100_legacy.png');
    await legacy.writeAsBytes([0, 1], flush: true);
    await legacy.setLastModified(DateTime.now().subtract(const Duration(days: 8)));
    final audit = await MediaCopyAudit.inspect(
        pickedMediaDirectory: stagedRoot,
        receiptDirectory: receipts, referencedPaths: {});
    expect(audit.complete, isTrue);
    expect(audit.reviewFiles, 2);
    expect(audit.registeredReviewFiles, 1);
    expect(audit.registeredFiles, 1);
    expect(audit.registeredReviewBytes, 3);
    expect(audit.reviewDetails.where((item) => item.provenanceVerified).length, 1);
    expect(await staged.exists(), isTrue);
    expect(await legacy.exists(), isTrue);
  });

  test('recent media is counted as registered without 7-day wait', () async {
    final source = await createMedia('fresh.jpg', [7, 8, 9]);
    final staged = await MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: stagedRoot,
        displayName: 'fresh.jpg', receiptDirectory: receipts);
    final audit = await MediaCopyAudit.inspect(
        pickedMediaDirectory: stagedRoot,
        receiptDirectory: receipts, referencedPaths: {});
    expect(audit.complete, isTrue);
    expect(audit.registeredFiles, 1);
    expect(audit.registeredBytes, 3);
    expect(audit.reviewFiles, 0);
    expect(audit.recentFiles, 1);
    expect(await staged.exists(), isTrue);
  });

  test('unreadable receipt does not mark a media file as registered', () async {
    final source = await createMedia('clip.mp4', [1, 2]);
    final staged = await MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: stagedRoot,
        displayName: 'clip.mp4', receiptDirectory: receipts);
    await staged.setLastModified(DateTime.now().subtract(const Duration(days: 8)));
    final receipt = MobileMediaSourcePolicy.receiptFor(staged, receipts);
    await receipt.writeAsString('{not json}', flush: true);
    final audit = await MediaCopyAudit.inspect(
        pickedMediaDirectory: stagedRoot,
        receiptDirectory: receipts, referencedPaths: {});
    expect(audit.registeredReviewFiles, 0);
    expect(audit.reviewDetails.single.provenanceVerified, isFalse);
    expect(await staged.exists(), isTrue);
  });

  test('queue preparation failure cleanup affects only new app-private copy', () async {
    final source = await createMedia('clip.mov', [4, 3, 2, 1]);
    final staged = await MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: stagedRoot,
        displayName: 'clip.mov', receiptDirectory: receipts);
    final receipt = MobileMediaSourcePolicy.receiptFor(staged, receipts);
    await MobileMediaSourcePolicy.discardUnqueuedStage(
        staged: staged, receiptDirectory: receipts);
    expect(await staged.exists(), isFalse);
    expect(await receipt.exists(), isFalse);
    expect(await source.readAsBytes(), [4, 3, 2, 1]);
  });

  test('stage error never emits fake receipt', () async {
    final source = await createMedia('big.mp4', [1, 2, 3, 4]);
    await expectLater(MobileMediaSourcePolicy.stageFile(
        source: source, stagingRoot: stagedRoot,
        displayName: 'big.mp4', maximumFileBytes: 3,
        receiptDirectory: receipts), throwsStateError);
    expect(await receipts.exists(), isFalse);
    expect(await source.readAsBytes(), [1, 2, 3, 4]);
  });
}
