import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/pairing_qr_payload.dart';
import 'package:remotex/core/services/pairing_failure.dart';
import 'package:remotex/core/services/pairing_service.dart';
import 'package:remotex/services/identity/cryptographic_device_identity_service.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/services/discovery/bonjour_host_advertiser.dart';
import 'package:remotex/services/pairing/lan_pairing_service.dart';
import 'package:remotex/services/storage/secure_paired_devices_service.dart';

import 'support/in_memory_secure_storage.dart';

void main() {
  late InMemorySecureStorage hostStorage;
  late InMemorySecureStorage controllerStorage;
  late LanPairingService host;
  late LanPairingService controller;

  setUp(() {
    hostStorage = InMemorySecureStorage();
    controllerStorage = InMemorySecureStorage();
    host = LanPairingService(
      identityService: CryptographicDeviceIdentityService(hostStorage),
      pairedDevicesService: SecurePairedDevicesService(hostStorage),
      advertiser: _TestAdvertiser(),
      bindAddress: InternetAddress.loopbackIPv4,
    );
    controller = LanPairingService(
      identityService: CryptographicDeviceIdentityService(controllerStorage),
      pairedDevicesService: SecurePairedDevicesService(controllerStorage),
      advertiser: _TestAdvertiser(),
    );
  });

  tearDown(() async {
    await controller.stop();
    await host.stop();
  });

  test(
    'pairs over the real TCP implementation and consumes the QR session',
    () async {
      await host.start();
      await host.startPairingSession();
      final hostStatus = host.status!;

      final paired = await controller.pair(
        _payload(hostStatus, addresses: const ['127.0.0.1']),
      );

      expect(paired.id, hostStatus.hostId);
      expect(
        await SecurePairedDevicesService(controllerStorage).getPairedDevices(),
        hasLength(1),
      );
      expect(
        await SecurePairedDevicesService(hostStorage).getPairedDevices(),
        hasLength(1),
      );
      expect(
        paired.authorizationScopes,
        containsAll({
          AuthorizationScope.session,
          AuthorizationScope.screenView,
        }),
      );
      expect(paired.hasScope(AuthorizationScope.mouseControl), isFalse);
      expect(paired.hasScope(AuthorizationScope.keyboardControl), isFalse);
      final hostPaired = (await SecurePairedDevicesService(
        hostStorage,
      ).getPairedDevices()).single;
      expect(hostPaired.hasScope(AuthorizationScope.screenView), isTrue);
      expect(hostPaired.hasScope(AuthorizationScope.mouseControl), isFalse);
      expect(hostPaired.hasScope(AuthorizationScope.keyboardControl), isFalse);
      expect(host.status!.pairingNonce, isNull);
      expect(host.status!.pairedDeviceCount, 1);
      expect(
        hostStorage.values.keys,
        contains('remotex.identity.ed25519.seed.v1'),
      );
      expect(
        controllerStorage.values.keys,
        contains('remotex.identity.ed25519.seed.v1'),
      );

      final replayController = LanPairingService(
        identityService: CryptographicDeviceIdentityService(
          InMemorySecureStorage(),
        ),
        pairedDevicesService: SecurePairedDevicesService(
          InMemorySecureStorage(),
        ),
        advertiser: _TestAdvertiser(),
      );
      addTearDown(replayController.stop);
      await expectLater(
        replayController.pair(
          _payload(hostStatus, addresses: const ['127.0.0.1']),
        ),
        throwsA(
          isA<PairingException>().having(
            (error) => error.failure,
            'failure',
            PairingFailure.expiredPairingSession,
          ),
        ),
      );
    },
  );

  test(
    'cancels and regenerates QR sessions without accepting replay',
    () async {
      await host.start();
      await host.startPairingSession();
      final firstPayload = _payload(
        host.status!,
        addresses: const ['127.0.0.1'],
      );

      await host.cancelPairingSession();
      await expectLater(
        controller.pair(firstPayload),
        throwsA(
          isA<PairingException>().having(
            (error) => error.failure,
            'failure',
            PairingFailure.expiredPairingSession,
          ),
        ),
      );

      await host.startPairingSession();
      final regeneratedPayload = _payload(
        host.status!,
        addresses: const ['127.0.0.1'],
      );
      expect(regeneratedPayload.pairingNonce, isNot(firstPayload.pairingNonce));
      await expectLater(
        controller.pair(firstPayload),
        throwsA(isA<PairingException>()),
      );

      final paired = await controller.pair(regeneratedPayload);
      expect(paired.id, host.status!.hostId);
    },
  );

  test(
    'rejects a wrong QR nonce and locks after five real pairing attempts',
    () async {
      await host.start();
      await host.startPairingSession();
      final hostStatus = host.status!;
      final badPayload = _payload(
        hostStatus,
        addresses: const ['127.0.0.1'],
        pairingNonce: 'A' * 43,
      );

      for (var attempt = 1; attempt <= 5; attempt++) {
        final expectedFailure = attempt == 5
            ? PairingFailure.tooManyAttempts
            : PairingFailure.invalidBootstrap;
        await expectLater(
          controller.pair(badPayload),
          throwsA(
            isA<PairingException>().having(
              (error) => error.failure,
              'failure',
              expectedFailure,
            ),
          ),
        );
      }
      expect(
        await SecurePairedDevicesService(hostStorage).getPairedDevices(),
        isEmpty,
      );
      expect(host.status!.pairingNonce, isNull);
      expect(host.status!.isPairingLocked, isTrue);
    },
  );

  test(
    'rejects a QR host identity that does not match its public key',
    () async {
      await host.start();
      await host.startPairingSession();
      final status = host.status!;
      final wrongIdentityPayload = PairingQrPayload(
        hostId: status.hostId,
        hostName: status.hostName,
        hostPublicKey: base64Encode(List<int>.filled(32, 7)),
        pairingNonce: status.pairingNonce!,
        addresses: const ['127.0.0.1'],
        port: status.port,
        expiresAt: status.expiresAt!,
      );

      await expectLater(
        controller.pair(wrongIdentityPayload),
        throwsA(
          isA<PairingException>().having(
            (error) => error.failure,
            'failure',
            PairingFailure.invalidRequest,
          ),
        ),
      );
      expect(
        await SecurePairedDevicesService(hostStorage).getPairedDevices(),
        isEmpty,
      );
    },
  );

  test('cancels an in-flight TCP pairing request', () async {
    final hostIdentity = await CryptographicDeviceIdentityService(hostStorage)
        .getOrCreateIdentity();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    final subscription = server.listen(accepted.complete);
    final pairing = controller.pair(
      PairingQrPayload(
        hostId: hostIdentity.id,
        hostName: 'Test host',
        hostPublicKey: hostIdentity.publicKey,
        pairingNonce: 'A' * 43,
        addresses: const ['127.0.0.1'],
        port: server.port,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
      ),
    );

    final acceptedSocket = await accepted.future;
    await controller.cancelPairing();
    await expectLater(
      pairing,
      throwsA(
        isA<PairingException>().having(
          (error) => error.failure,
          'failure',
          PairingFailure.cancelled,
        ),
      ),
    );
    acceptedSocket.destroy();
    await subscription.cancel();
    await server.close();
  });
}

PairingQrPayload _payload(
  HostPairingStatus status, {
  List<String> addresses = const [],
  String? pairingNonce,
}) => PairingQrPayload(
  hostId: status.hostId,
  hostName: status.hostName,
  hostPublicKey: status.hostPublicKey,
  pairingNonce: pairingNonce ?? status.pairingNonce!,
  addresses: addresses.isEmpty ? status.addresses : addresses,
  port: status.port,
  expiresAt: status.expiresAt!,
);

class _TestAdvertiser implements HostAdvertiser {
  @override
  Future<void> start({
    required String hostId,
    required String hostName,
    required int port,
  }) async {}

  @override
  Future<void> stop() async {}
}
