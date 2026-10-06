import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/device_identity.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/pairing_session.dart';
import 'package:remotex/core/models/remote_device.dart';
import 'package:remotex/core/models/remote_host.dart';
import 'package:remotex/services/identity/cryptographic_device_identity_service.dart';

import 'support/in_memory_secure_storage.dart';

void main() {
  test(
    'creates a persistent Ed25519 identity and verifies signatures',
    () async {
      final storage = InMemorySecureStorage();
      final identities = CryptographicDeviceIdentityService(storage);

      final first = await identities.getOrCreateIdentity();
      final second = await identities.getOrCreateIdentity();
      final message = utf8.encode('pairing identity test');
      final signature = await identities.sign(message);

      expect(second.id, first.id);
      expect(second.publicKey, first.publicKey);
      expect(
        await identities.verify(
          publicKey: first.publicKey,
          message: message,
          signature: signature,
        ),
        isTrue,
      );
      expect(
        await identities.verify(
          publicKey: first.publicKey,
          message: utf8.encode('changed message'),
          signature: signature,
        ),
        isFalse,
      );
      expect(storage.values.keys, isNot(contains('remotex.paired_devices.v1')));
    },
  );

  test(
    'serializes and restores host, paired-device, and public identity data',
    () {
      final now = DateTime.utc(2026, 10, 3, 10);
      final host = RemoteHost(
        id: 'host-id',
        name: 'Laptop',
        port: 4321,
        protocolVersion: 1,
        addresses: const ['192.168.1.12'],
      );
      final paired = PairedDevice(
        id: 'host-id',
        name: 'Laptop',
        hostId: 'host-id',
        publicKey: 'public-key',
        addedAt: now,
      );
      const identity = DeviceIdentity(id: 'device-id', publicKey: 'public-key');

      expect(RemoteHost.fromJson(host.toJson()).id, host.id);
      expect(
        RemoteDevice.fromJson(
          const RemoteDevice(id: 'id', name: 'name').toJson(),
        ).name,
        'name',
      );
      expect(PairedDevice.fromJson(paired.toJson()).addedAt, paired.addedAt);
      final restoredIdentity = DeviceIdentity.fromJson(identity.toJson());
      expect(restoredIdentity.id, identity.id);
      expect(restoredIdentity.publicKey, identity.publicKey);
      const session = PairingSession(
        state: PairingSessionState.pairing,
        host: 'Laptop',
      );
      expect(
        PairingSession.fromJson(session.toJson()).state,
        PairingSessionState.pairing,
      );
    },
  );
}
