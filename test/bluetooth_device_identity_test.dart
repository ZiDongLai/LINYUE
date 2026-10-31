import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/bluetooth/bluetooth_connection_controller.dart';
import 'package:nearlink/bluetooth/bluetooth_peer_catalog.dart';
import 'package:nearlink/security/device_identity.dart';

import 'bluetooth_connection_ui_test.dart' as ui;
import 'bluetooth_poc_test.dart' as b1;

class BindingFaultVault extends b1.MemoryVault {
  bool rejectBindingWrites = false;
  Completer<void>? readGate;
  @override
  Future<String?> read(String key) async {
    if (key == BluetoothPeerBindings.storageKey) await readGate?.future;
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (key == BluetoothPeerBindings.storageKey && rejectBindingWrites) {
      throw StateError('Storage denied');
    }
    await super.write(key, value);
  }
}

void main() {
  group('B3 physical device catalog, not a trust registry', () {
    test(
      'same-name devices with colliding suffixes use complete OS addresses',
      () {
        final c = BluetoothPeerCatalog.fromSnapshot([
          {'id': '112233445566', 'name': '同名手机'},
          {'id': 'AABBCC445566', 'name': '同名手机'},
        ]);
        expect(c.devices.map((d) => d.displayName).toSet().length, 2);
        expect(c.devices.every((d) => d.fullAddress), isTrue);
      },
    );
    test('same address with case/separator variations is one device', () {
      final c = BluetoothPeerCatalog.fromSnapshot([
        {'id': 'aa:bb:cc:dd:ee:ff', 'name': '我的手机'},
        {'id': 'AABBCCDDEEFF', 'name': '我的手机'},
        {'id': 'aa-bb-cc-dd-ee-ff', 'name': '我的手机'},
      ]);
      expect(c.devices.length, 1);
      expect(c.devices.single.id, 'AABBCCDDEEFF');
    });
    test('two real same-name devices remain distinct with useful suffixes', () {
      final c = BluetoothPeerCatalog.fromSnapshot([
        {'id': '112233445566', 'name': '同名手机'},
        {'id': '112233778899', 'name': '同名手机'},
      ]);
      expect(c.devices.length, 2);
      expect(c.devices.map((d) => d.displayName).toSet().length, 2);
      expect(c.devices.first.displayName, contains('44:55:66'));
    });
    test(
      'temporary discovery/session values do not become OS device identities',
      () {
        for (final session in ['first', 'second', 'old-session']) {
          final c = BluetoothPeerCatalog.fromSnapshot([
            {
              'id': '112233445566',
              'name': '手机',
              'session': session,
              'helloId': session,
            },
          ]);
          expect(c.devices.single.id, '112233445566');
        }
        expect(
          BluetoothPeerCatalog.fromSnapshot([
            {'sessionId': 'abc', 'name': '手机'},
          ]).devices,
          isEmpty,
        );
      },
    );
    test('missing/opaque/placeholder identity is not fabricated', () {
      final c = BluetoothPeerCatalog.fromSnapshot([
        {'id': 'process-123', 'name': '手机'},
        {'id': '02:00:00:00:00:00', 'name': '手机'},
        {'id': '000000000000', 'name': '手机'},
        {'name': '手机'},
      ]);
      expect(c.devices, isEmpty);
      expect(c.incompleteEntries, 4);
    });
    test(
      'a fresh snapshot replaces old records, not an accumulating cache',
      () {
        final old = BluetoothPeerCatalog.fromSnapshot([
          {'id': '112233445566', 'name': '旧手机'},
        ]);
        final fresh = BluetoothPeerCatalog.fromSnapshot([
          {'id': 'AABBCCDDEEFF', 'name': '新手机'},
        ]);
        expect(old.devices.length, 1);
        expect(fresh.devices.single.name, '新手机');
        expect(BluetoothPeerCatalog.fromSnapshot([]).devices, isEmpty);
      },
    );
    test(
      'phone classification is prioritized without asserting Android OS',
      () {
        final c = BluetoothPeerCatalog.fromSnapshot([
          {'id': '112233445566', 'name': 'A耳机', 'kind': 'other'},
          {'id': 'AABBCCDDEEFF', 'name': 'Z手机', 'kind': 'phone'},
        ]);
        expect(c.devices.first.name, 'Z手机');
        expect(c.devices.first.phone, isTrue);
      },
    );
    test('unpaired rows are not offered for connection', () {
      expect(
        BluetoothPeerCatalog.fromSnapshot([
          {'id': '112233445566', 'name': '未配对', 'paired': false},
        ]).devices,
        isEmpty,
      );
    });
    test('blank duplicate name cannot erase an available friendly name', () {
      final c = BluetoothPeerCatalog.fromSnapshot([
        {'id': '112233445566', 'name': 'ALN手机'},
        {'id': '11:22:33:44:55:66', 'name': ''},
      ]);
      expect(c.devices.single.name, 'ALN手机');
    });
  });

  group('B3 bounded authenticated associations and confirmation', () {
    test(
      'copied association data from another local identity is not trusted',
      () async {
        final local = await b1.identity(), peer = await b1.identity();
        await b1.trust(local, peer);
        await local.vault.write(
          BluetoothPeerBindings.storageKey,
          '{"v":1,"owner":"other-owner","peers":{"112233445566":"${peer.local.fingerprint}"}}',
        );
        final store = BluetoothPeerBindings(local);
        await store.load();
        expect(store.fingerprintFor('112233445566'), isNull);
        expect(store.loadError, isNotNull);
      },
    );
    test('failed durable write rolls back the in-memory association', () async {
      final vault = BindingFaultVault();
      final local = DeviceIdentityManager(vault);
      await local.initialize();
      final peer = await b1.identity();
      await b1.trust(local, peer);
      vault.rejectBindingWrites = true;
      final store = BluetoothPeerBindings(local);
      await expectLater(
        store.remember('112233445566', peer.local.fingerprint),
        throwsStateError,
      );
      expect(store.fingerprintFor('112233445566'), isNull);
    });
    test('concurrent loads await the same pending vault read', () async {
      final vault = BindingFaultVault();
      final local = DeviceIdentityManager(vault);
      await local.initialize();
      vault.readGate = Completer<void>();
      final store = BluetoothPeerBindings(local);
      var secondDone = false;
      final first = store.load(),
          second = store.load().then((_) {
            secondDone = true;
          });
      await Future<void>.delayed(Duration.zero);
      expect(secondDone, isFalse);
      vault.readGate!.complete();
      await Future.wait([first, second]);
      expect(secondDone, isTrue);
    });
    test(
      'six groups select only an existing complete registered fingerprint',
      () {
        final fp = '0123456789abcdef' * 4;
        expect(bluetoothIdentityCode(fp), '0123 4567 89AB CDEF 0123 4567');
        expect(resolveBluetoothIdentity([fp], bluetoothIdentityCode(fp)), fp);
        expect(resolveBluetoothIdentity([fp], fp.toUpperCase()), fp);
        expect(resolveBluetoothIdentity([fp], '01234567'), isNull);
        expect(resolveBluetoothIdentity([fp], 'f' * 24), isNull);
      },
    );
    test('ambiguous confirmation prefix is rejected rather than guessed', () {
      final prefix = 'a' * 24;
      expect(
        resolveBluetoothIdentity([
          prefix + 'b' * 40,
          prefix + 'c' * 40,
        ], prefix),
        isNull,
      );
    });
    test(
      'association survives a controller/process restart, not a nonce',
      () async {
        final local = await b1.identity(), peer = await b1.identity();
        await b1.trust(local, peer);
        final store = BluetoothPeerBindings(local);
        await store.remember('11:22:33:44:55:66', peer.local.fingerprint);
        final reopened = BluetoothPeerBindings(local);
        await reopened.load();
        expect(reopened.fingerprintFor('112233445566'), peer.local.fingerprint);
      },
    );
    test(
      'revocation and unpaired snapshots invalidate association hints only',
      () async {
        final local = await b1.identity(), peer = await b1.identity();
        await b1.trust(local, peer);
        final store = BluetoothPeerBindings(local);
        await store.remember('112233445566', peer.local.fingerprint);
        await store.retainPaired({});
        expect(store.fingerprintFor('112233445566'), isNull);
        expect(local.entries.length, 1); // Never delete the trust record.
        await store.remember('112233445566', peer.local.fingerprint);
        await local.revoke(peer.local.fingerprint);
        expect(store.fingerprintFor('112233445566'), isNull);
      },
    );
    test(
      'corrupt association bytes are preserved and never trusted/reset',
      () async {
        final local = await b1.identity();
        await local.vault.write(BluetoothPeerBindings.storageKey, 'not json');
        final store = BluetoothPeerBindings(local);
        await store.load();
        expect(store.loadError, isNotNull);
        expect(store.fingerprintFor('112233445566'), isNull);
        await expectLater(store.retainPaired({}), throwsStateError);
        expect(
          await local.vault.read(BluetoothPeerBindings.storageKey),
          'not json',
        );
      },
    );
  });

  group('B3 selection, proof and retry workflow', () {
    Future<ui.Setup> setup({bool android = false}) async {
      final s = await ui.Setup.make(android: android);
      addTearDown(s.controller.dispose);
      return s;
    }

    test(
      'stale association can be explicitly reviewed without deleting trust records',
      () async {
        final s = await setup();
        final oldPeer = await b1.identity();
        await b1.trust(s.controller.identity, oldPeer);
        await s.controller.bindings.remember(
          '112233445566',
          oldPeer.local.fingerprint,
        );
        await s.controller.prepare();
        await ui.selectAndConfirm(s, '112233445566');
        expect(s.transport.expected, oldPeer.local.fingerprint);
        s.transport.emit('error', error: 'Identity signature rejected');
        await s.controller.reviewIdentity();
        expect(s.controller.phase, BluetoothConnectionPhase.chooseIdentity);
        await s.controller.confirmIdentity(
          bluetoothIdentityCode(s.peer.local.fingerprint),
        );
        expect(s.transport.expected, s.peer.local.fingerprint);
        expect(s.transport.starts, 2);
        expect(s.controller.identities.length, 2);
      },
    );

    test(
      'many old same-name identities never block the physical device list',
      () async {
        final s = await setup();
        for (var i = 0; i < 4; i++) {
          await b1.trust(s.controller.identity, await b1.identity());
        }
        await s.controller.prepare();
        expect(s.controller.phase, BluetoothConnectionPhase.chooseDevice);
        expect(s.controller.devices.length, 1);
        expect(s.transport.starts, 0);
        await s.controller.connectDevice('112233445566');
        expect(s.controller.phase, BluetoothConnectionPhase.chooseIdentity);
        await s.controller.confirmIdentity(
          bluetoothIdentityCode(s.peer.local.fingerprint),
        );
        expect(s.transport.starts, 1);
        expect(s.transport.expected, s.peer.local.fingerprint);
      },
    );
    test(
      'failed/uncompleted auth never persists an address-to-identity association',
      () async {
        final s = await setup();
        await s.controller.prepare();
        await ui.selectAndConfirm(s, '112233445566');
        s.transport.connectedDeviceId = '112233445566';
        s.transport.emit('connected');
        await Future<void>.delayed(Duration.zero);
        expect(s.controller.bindings.fingerprintFor('112233445566'), isNull);
        s.transport.emit('error', error: 'Identity signature rejected');
        expect(s.controller.failedStage, '身份认证');
        expect(s.controller.authenticated, isFalse);
      },
    );
    test(
      'authenticated actual endpoint saves a hint for subsequent direct connection',
      () async {
        final s = await setup();
        await b1.trust(s.controller.identity, await b1.identity());
        await s.controller.prepare();
        await ui.selectAndConfirm(s, '112233445566');
        await s.controller.confirmIdentity(
          bluetoothIdentityCode(s.peer.local.fingerprint),
        );
        s.transport.connectedDeviceId = '112233445566';
        s.transport.emit('connected', authenticated: true);
        await Future<void>.delayed(Duration.zero);
        expect(
          s.controller.bindings.fingerprintFor('112233445566'),
          s.peer.local.fingerprint,
        );
        await s.controller.stop();
        await s.controller.prepare();
        await ui.selectAndConfirm(s, '112233445566');
        expect(s.transport.starts, 2);
        expect(s.transport.expected, s.peer.local.fingerprint);
      },
    );
    test(
      'mismatched native endpoint is stopped and never associated',
      () async {
        final s = await setup();
        await s.controller.prepare();
        await ui.selectAndConfirm(s, '112233445566');
        s.transport.connectedDeviceId = 'AABBCCDDEEFF';
        s.transport.emit('connected', authenticated: true);
        await Future<void>.delayed(Duration.zero);
        expect(s.controller.authenticated, isFalse);
        expect(s.controller.bindings.fingerprintFor('112233445566'), isNull);
        expect(s.controller.bindings.fingerprintFor('AABBCCDDEEFF'), isNull);
      },
    );
    test(
      'refresh removes no-longer-returned device and stale selection',
      () async {
        final s = await setup();
        await s.controller.prepare();
        s.controller.selectedDeviceId = '112233445566';
        s.controller.selectedFingerprint = s.peer.local.fingerprint;
        s.native.paired = [
          {'id': 'AABBCCDDEEFF', 'name': '新手机'},
        ];
        await s.controller.prepare();
        expect(s.controller.devices.single.name, '新手机');
        expect(s.controller.selectedDeviceId, isNull);
        expect(s.controller.selectedFingerprint, isNull);
      },
    );
    test(
      'system enumeration failure clears the view and retains failure evidence',
      () async {
        final s = await setup();
        await s.controller.prepare();
        s.native.statusFails = true;
        await s.controller.prepare();
        expect(s.controller.devices, isEmpty);
        expect(s.controller.phase, BluetoothConnectionPhase.failed);
        expect(s.controller.errorDetail, contains('status unavailable'));
      },
    );
    test(
      'cancellation, finite timeout and retry preserve the selected physical target',
      () async {
        final s = await setup();
        await s.controller.prepare();
        await ui.selectAndConfirm(s, '112233445566');
        s.transport.emit('error', error: 'RFCOMM connection timeout');
        expect(s.controller.failedStage, '蓝牙建链或连接');
        await s.controller.stop();
        expect(s.controller.phase, BluetoothConnectionPhase.cancelled);
        await s.controller.prepare();
        await ui.selectAndConfirm(s, '112233445566');
        expect(s.transport.starts, 2);
      },
    );
    test(
      'invalid confirmation cannot create enrollment or start a connection',
      () async {
        final s = await setup();
        await b1.trust(s.controller.identity, await b1.identity());
        await s.controller.prepare();
        await s.controller.connectDevice('112233445566');
        final count = s.controller.identities.length;
        await s.controller.confirmIdentity('0000');
        expect(s.transport.starts, 0);
        expect(s.controller.identities.length, count);
      },
    );
    test(
      'success label uses real friendly name rather than old registration name',
      () async {
        final s = await setup();
        s.native.paired = [
          {'id': '112233445566', 'name': 'ALN真实手机'},
        ];
        await s.controller.prepare();
        await ui.selectAndConfirm(s, '112233445566');
        s.transport.connectedDeviceId = '112233445566';
        s.transport.emit('connected', authenticated: true);
        expect(s.controller.peerLabel, 'ALN真实手机');
        await Future<void>.delayed(Duration.zero);
      },
    );
  });

  testWidgets(
    'physical names first; no historical-identity dropdown or random name suffix',
    (tester) async {
      final s = await ui.Setup.make(android: false);
      addTearDown(s.controller.dispose);
      for (var i = 0; i < 4; i++) {
        await b1.trust(s.controller.identity, await b1.identity());
      }
      s.native.paired = [
        {'id': '112233445566', 'name': 'ALN手机'},
        {'id': 'AABBCCDDEEFF', 'name': 'ALN手机'},
      ];
      await tester.pumpWidget(ui.testHome(s));
      await tester.tap(find.byKey(const Key('connect-device')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bluetooth-connection-option')));
      await tester.pumpAndSettle();
      expect(find.text('ALN手机 · 尾号 44:55:66'), findsOneWidget);
      expect(find.text('ALN手机 · 尾号 DD:EE:FF'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await tester.tap(find.byKey(const ValueKey('paired-112233445566')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('bluetooth-identity-code')),
        bluetoothIdentityCode(s.peer.local.fingerprint),
      );
      await tester.ensureVisible(
        find.byKey(const Key('confirm-bluetooth-identity')),
      );
      await tester.tap(find.byKey(const Key('confirm-bluetooth-identity')));
      await tester.pump();
      expect(s.transport.starts, 1);
      expect(s.transport.expected, s.peer.local.fingerprint);
    },
  );
}
