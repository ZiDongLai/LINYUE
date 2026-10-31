import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/disk_capacity_guard.dart';

void main() {
  const mib = 1024 * 1024;
  test('real reported free bytes pass with reserve', () async {
    final guard = DiskCapacityGuard(
      lookup: (path) async { expect(path, '/target'); return 110 * mib; },
      minimumReserveBytes: 8 * mib);
    final status = await guard.requireRoom(destinationPath: '/target',
      fileBytes: 100 * mib);
    expect(status.freeBytes, 110 * mib);
    expect(status.additionalBytes, 100 * mib);
    expect(status.reserveBytes, 8 * mib);
    expect(status.enough, true);
  });
  test('too little space refuses before any write', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => 107 * mib,
      minimumReserveBytes: 8 * mib);
    await expectLater(guard.requireRoom(destinationPath: '/target',
      fileBytes: 100 * mib), throwsStateError);
  });
  test('unknown capacity fails closed for large files', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => null);
    await expectLater(guard.requireRoom(destinationPath: '/target',
      fileBytes: 40 * mib), throwsStateError);
  });
  test('negative capacity is not treated as valid', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => -1);
    expect(await guard.availableBytes('/target'), null);
  });
  test('volume probe exception becomes unknown', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => throw Exception('offline'));
    await expectLater(guard.requireRoom(destinationPath: '/target',
      fileBytes: 30 * mib), throwsStateError);
  });
  test('resume counts only verified non-duplicated bytes', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => 43 * mib,
      minimumReserveBytes: 8 * mib);
    final status = await guard.requireRoom(destinationPath: '/target',
      fileBytes: 100 * mib, verifiedBytes: 65 * mib);
    expect(status.additionalBytes, 35 * mib);
    expect(status.enough, true);
  });
  test('unverified last chunk is not a valid resume offset', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => 43 * mib,
      minimumReserveBytes: 8 * mib);
    await expectLater(guard.requireRoom(destinationPath: '/target',
      fileBytes: 100 * mib, verifiedBytes: 64 * mib), throwsStateError);
  });
  test('rejects malicious oversize or negative resume offsets', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => 999 * mib);
    await expectLater(guard.inspect(destinationPath: '/target',
      fileBytes: 20, verifiedBytes: 21), throwsArgumentError);
    await expectLater(guard.inspect(destinationPath: '/target',
      fileBytes: 20, verifiedBytes: -1), throwsArgumentError);
  });
  test('threshold exact equality passes', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => 58 * mib,
      minimumReserveBytes: 8 * mib);
    final status = await guard.requireRoom(destinationPath: '/target',
      fileBytes: 50 * mib);
    expect(status.enough, true);
  });
  test('reserve scales with size when 5 percent exceeds minimum', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => 210 * mib,
      minimumReserveBytes: 1 * mib);
    final status = await guard.inspect(destinationPath: '/target',
      fileBytes: 200 * mib);
    expect(status.reserveBytes, 10 * mib);
    expect(status.enough, true);
  });
  test('empty target path returns unknown', () async {
    final guard = DiskCapacityGuard(lookup: (_) async => 1);
    expect(await guard.availableBytes(' '), isNull);
  });
}
