import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/security/in_app_pairing.dart';
import 'package:nearlink/services/same_platform_connection_policy.dart';
import 'package:nearlink/services/same_platform_live_connection.dart';

const localId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const remoteId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const otherId = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const ip = '192.168.18.15';

PairingResult signed(String fingerprint, {String address = ip}) => PairingResult(
  remoteName: '广播名称只用于展示', fingerprint: fingerprint, remoteIp: address,
);

Future<PairingResult> request(
  SamePlatformLiveConnection gate, {
  required Future<PairingResult?> Function() resume,
  bool Function(String)? registered,
  String local = localId,
  bool ready = true,
  String address = ip,
  Future<PairingResult> Function()? firstPair,
}) => gate.resolve(
  remoteIp: address,
  localFingerprint: local,
  secureChannelReady: ready,
  isRegistered: registered ?? ((fingerprint) => fingerprint == remoteId),
  trySignedResume: resume,
  initiateSignedPairing: firstPair ?? () async => throw StateError('不能跳过六位码确认'),
);

void main() {
  group('E22-C: 同平台并发连接、重连与身份隔离最终回归', () {
    test('40 次同一 IP 本机并发操作只进行一次签名校验', () async {
      final gate = SamePlatformLiveConnection();
      final block = Completer<PairingResult?>();
      var networkCalls = 0;
      final futures = List<Future<PairingResult>>.generate(40, (_) => request(
        gate, resume: () { networkCalls++; return block.future; },
      ));
      expect(gate.isConnecting(ip), isTrue);
      expect(networkCalls, 1);
      block.complete(signed(remoteId));
      final signedResults = await Future.wait(futures);
      expect(signedResults.length, 40);
      expect(signedResults.every((r) => r.fingerprint == remoteId), isTrue);
      expect(networkCalls, 1);
      expect(gate.isConnecting(ip), isFalse);
    });

    test('第二个请求若未登记该签名身份，不得继承首请求认证', () async {
      final gate = SamePlatformLiveConnection();
      final waiting = Completer<PairingResult?>();
      var secondNetworkInvoked = false;
      final first = request(gate, resume: () => waiting.future);
      final second = request(
        gate,
        registered: (_) => false,
        resume: () async { secondNetworkInvoked = true; return signed(remoteId); },
      );
      waiting.complete(signed(remoteId));
      expect((await first).fingerprint, remoteId);
      await expectLater(second, throwsA(isA<StateError>()));
      expect(secondNetworkInvoked, isFalse);
    });

    test('第二个请求的加密会话失效，即使有进行中的签名也必须拒绝', () async {
      final gate = SamePlatformLiveConnection();
      final waiting = Completer<PairingResult?>();
      final first = request(gate, resume: () => waiting.future);
      await expectLater(
        request(gate, ready: false, resume: () async => signed(remoteId)),
        throwsA(isA<StateError>()),
      );
      waiting.complete(signed(remoteId));
      expect((await first).fingerprint, remoteId);
    });

    test('等待同一 IP 配对的自连接请求独立拒绝', () async {
      final gate = SamePlatformLiveConnection();
      final waiting = Completer<PairingResult?>();
      final first = request(gate, resume: () => waiting.future);
      final wrongLocal = request(
        gate, local: remoteId,
        registered: (_) => true,
        resume: () async => signed(otherId),
      );
      waiting.complete(signed(remoteId));
      expect((await first).fingerprint, remoteId);
      await expectLater(wrongLocal, throwsA(isA<StateError>()));
    });

    test('等待认证时登记身份被撤销，首请求也不得继续', () async {
      final gate = SamePlatformLiveConnection();
      final waiting = Completer<PairingResult?>();
      var enrolled = true;
      final first = request(
        gate,
        registered: (value) => enrolled && value == remoteId,
        resume: () => waiting.future,
      );
      enrolled = false;
      waiting.complete(signed(remoteId));
      await expectLater(first, throwsA(isA<StateError>()));
      expect(gate.isConnecting(ip), isFalse);
    });

    test('返回其他 IP 的签名结果不能被任何同 IP 请求接受', () async {
      final gate = SamePlatformLiveConnection();
      final waiting = Completer<PairingResult?>();
      final first = request(gate, resume: () => waiting.future);
      final second = request(gate, resume: () async => signed(remoteId));
      waiting.complete(signed(remoteId, address: '192.168.18.99'));
      await expectLater(first, throwsA(isA<StateError>()));
      await expectLater(second, throwsA(isA<StateError>()));
      expect(gate.isConnecting(ip), isFalse);
    });

    test('首次网络配对失败不污染下一次重新连接', () async {
      final gate = SamePlatformLiveConnection();
      final waiting = Completer<PairingResult?>();
      final first = request(gate, resume: () => waiting.future);
      final second = request(gate, resume: () => waiting.future);
      final checkFirst = expectLater(first, throwsA(isA<StateError>()));
      final checkSecond = expectLater(second, throwsA(isA<StateError>()));
      waiting.completeError(StateError('断网'));
      await checkFirst;
      await checkSecond;
      expect(gate.isConnecting(ip), isFalse);
      final succeeded = await request(gate, resume: () async => signed(remoteId));
      expect(succeeded.fingerprint, remoteId);
    });

    test('多次依次重连均需要新的签名会话而非复用旧结果', () async {
      final gate = SamePlatformLiveConnection();
      var signedProofs = 0;
      for (var attempt = 0; attempt < 20; attempt++) {
        final response = await request(gate, resume: () async {
          signedProofs++;
          return signed(remoteId);
        });
        expect(response.fingerprint, remoteId);
        expect(gate.isConnecting(ip), isFalse);
      }
      expect(signedProofs, 20);
    });

    test('两台不同 IP 的身份登记和签名结果始终隔离', () async {
      final gate = SamePlatformLiveConnection();
      final firstIp = request(gate, resume: () async => signed(remoteId));
      final secondIp = request(
        gate,
        address: '192.168.18.16',
        registered: (value) => value == otherId,
        resume: () async => signed(otherId, address: '192.168.18.16'),
      );
      final results = await Future.wait([firstIp, secondIp]);
      expect(results[0].fingerprint, remoteId);
      expect(results[1].fingerprint, otherId);
    });

    test('Windows/Android 任意组合均不跳过签名认证规则', () {
      for (final first in LinyueEndpointPlatform.values) {
        for (final second in LinyueEndpointPlatform.values) {
          final candidate = SamePlatformPeerCandidate(
            localFingerprint: localId, remoteIp: ip,
            reachable: true, enrolledFingerprint: remoteId,
            authenticatedFingerprint: otherId,
            encryptedChannelReady: true,
            authenticatedProtocolConfirmed: true,
            localPlatform: first, announcedPlatform: second,
            announcedName: '仿冒的受信任名称',
          );
          expect(
            SamePlatformConnectionPolicy.evaluate(candidate).mayAttemptSecureOperation,
            isFalse, reason: '${first.name} -> ${second.name}',
          );
        }
      }
    });

    test('新设备首次配对只能通过既有签名和六位码流程', () async {
      final gate = SamePlatformLiveConnection();
      var pairings = 0;
      var registered = false;
      final result = await request(
        gate,
        resume: () async => null,
        registered: (value) => registered && value == remoteId,
        firstPair: () async {
          pairings++;
          registered = true; // Simulate confirmed SAS enrollment by PairingService.
          return signed(remoteId);
        },
      );
      expect(pairings, 1);
      expect(result.fingerprint, remoteId);
    });

    test('原设备断点续传必须拒绝被交换的签名设备', () {
      expect(() => SamePlatformLiveConnection.authorizeSignedIdentity(
        remoteIp: ip, localFingerprint: localId,
        registeredFingerprint: remoteId, signedFingerprint: otherId,
        secureChannelReady: true,
      ), throwsA(isA<StateError>()));
      expect(() => SamePlatformLiveConnection.authorizeSignedIdentity(
        remoteIp: ip, localFingerprint: localId,
        registeredFingerprint: remoteId, signedFingerprint: remoteId,
        secureChannelReady: false,
      ), throwsA(isA<StateError>()));
      expect(() => SamePlatformLiveConnection.authorizeSignedIdentity(
        remoteIp: ip, localFingerprint: localId,
        registeredFingerprint: remoteId, signedFingerprint: remoteId,
        secureChannelReady: true,
      ), returnsNormally);
    });

    test('公网、回环和非法地址连接在网络操作前被拒绝', () async {
      final gate = SamePlatformLiveConnection();
      for (final address in ['127.0.0.1', '8.8.8.8', '192.168.01.9', 'host.local']) {
        var contacted = false;
        await expectLater(request(
          gate, address: address,
          resume: () async { contacted = true; return signed(remoteId); },
        ), throwsA(isA<StateError>()));
        expect(contacted, isFalse, reason: address);
      }
    });
  });
}
