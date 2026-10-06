import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/web_pairing_payload.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/services/pairing_failure.dart';
import 'package:remotex/core/services/session_transport.dart';
import 'package:remotex/services/identity/cryptographic_device_identity_service.dart';
import 'package:remotex/services/pairing/web_pairing_service.dart';
import 'package:remotex/services/storage/secure_paired_devices_service.dart';

import 'support/in_memory_secure_storage.dart';

void main() {
  late InMemorySecureStorage hostStorage;
  late InMemorySecureStorage clientStorage;
  late WebPairingService hostService;
  late WebPairingService clientService;

  setUp(() {
    hostStorage = InMemorySecureStorage();
    clientStorage = InMemorySecureStorage();

    hostService = WebPairingService(
      identityService: CryptographicDeviceIdentityService(hostStorage),
      pairedDevicesService: SecurePairedDevicesService(hostStorage),
    );

    clientService = WebPairingService(
      identityService: CryptographicDeviceIdentityService(clientStorage),
      pairedDevicesService: SecurePairedDevicesService(clientStorage),
    );
  });

  test('successfully pairs web client with host and verifies scopes', () async {
    final payload = await hostService.startWebPairingSession(
      relayUrl: 'ws://127.0.0.1:8080',
    );

    final wire = _LoopbackSessionWire();

    final hostFuture = hostService.handleIncomingWebPairingWire(wire.hostWire);
    final clientFuture = clientService.pairWebClient(
      payload: payload,
      wire: wire.clientWire,
    );

    final pairedDevice = await clientFuture;
    await hostFuture;

    expect(pairedDevice.hostId, payload.hostId);
    expect(
      pairedDevice.hasScope(AuthorizationScope.screenView),
      isTrue,
    );
    expect(
      pairedDevice.hasScope(AuthorizationScope.mouseControl),
      isFalse,
    );
    expect(
      pairedDevice.hasScope(AuthorizationScope.keyboardControl),
      isFalse,
    );

    final hostPairedDevices = await SecurePairedDevicesService(hostStorage).getPairedDevices();
    expect(hostPairedDevices, hasLength(1));
    expect(
      hostPairedDevices.single.hasScope(AuthorizationScope.screenView),
      isTrue,
    );
    expect(
      hostPairedDevices.single.hasScope(AuthorizationScope.mouseControl),
      isFalse,
    );
  });

  test('single-use web pairing nonce cannot be reused', () async {
    final payload = await hostService.startWebPairingSession(
      relayUrl: 'ws://127.0.0.1:8080',
    );

    final wire1 = _LoopbackSessionWire();
    await Future.wait([
      hostService.handleIncomingWebPairingWire(wire1.hostWire),
      clientService.pairWebClient(payload: payload, wire: wire1.clientWire),
    ]);

    final wire2 = _LoopbackSessionWire();
    final clientFuture2 = clientService.pairWebClient(
      payload: payload,
      wire: wire2.clientWire,
    );
    final hostFuture2 = hostService.handleIncomingWebPairingWire(wire2.hostWire);

    await expectLater(clientFuture2, throwsA(isA<PairingException>()));
    await hostFuture2;
  });

  test('cancelling web pairing session invalidates payload', () async {
    final payload = await hostService.startWebPairingSession(
      relayUrl: 'ws://127.0.0.1:8080',
    );

    await hostService.cancelWebPairingSession();

    final wire = _LoopbackSessionWire();
    final clientFuture = clientService.pairWebClient(
      payload: payload,
      wire: wire.clientWire,
    );
    final hostFuture = hostService.handleIncomingWebPairingWire(wire.hostWire);

    await expectLater(clientFuture, throwsA(isA<PairingException>()));
    await hostFuture;
  });

  test('rejects pairing with wrong host identity', () async {
    final payload = await hostService.startWebPairingSession(
      relayUrl: 'ws://127.0.0.1:8080',
    );

    final wrongPayload = WebPairingPayload(
      hostId: 'f' * 32,
      hostName: payload.hostName,
      hostPublicKey: payload.hostPublicKey,
      relayUrl: payload.relayUrl,
      pairingNonce: payload.pairingNonce,
      sessionId: payload.sessionId,
      expiresAt: payload.expiresAt,
    );

    final wire = _LoopbackSessionWire();
    final clientFuture = clientService.pairWebClient(
      payload: wrongPayload,
      wire: wire.clientWire,
    );
    final hostFuture = hostService.handleIncomingWebPairingWire(wire.hostWire);

    await expectLater(clientFuture, throwsA(isA<PairingException>()));
    await hostFuture;
  });

  test('revoking paired device prevents subsequent access', () async {
    final pairedDevicesService = SecurePairedDevicesService(hostStorage);
    await pairedDevicesService.addPairedDevice(
      PairedDevice(
        id: 'revoked_device',
        name: 'Revoked Web',
        hostId: 'host_1',
        publicKey: 'pk',
        addedAt: DateTime.now().toUtc(),
      ),
    );

    await pairedDevicesService.revokePairedDevice('revoked_device');
    expect(await pairedDevicesService.isRevoked('revoked_device'), isTrue);
  });
}

class _LoopbackSessionWire {
  _LoopbackSessionWire() {
    hostWire = _SideWire(_hostToClient, _clientToHost.stream);
    clientWire = _SideWire(_clientToHost, _hostToClient.stream);
  }

  final _hostToClient = StreamController<Map<String, Object?>>.broadcast();
  final _clientToHost = StreamController<Map<String, Object?>>.broadcast();

  late final SessionWire hostWire;
  late final SessionWire clientWire;
}

class _SideWire implements SessionWire {
  _SideWire(this._out, Stream<Map<String, Object?>> inStream) {
    _sub = inStream.listen((msg) {
      if (_completers.isNotEmpty) {
        _completers.removeAt(0).complete(msg);
      } else {
        _buffered.add(msg);
      }
    });
  }

  final StreamController<Map<String, Object?>> _out;
  late final StreamSubscription<Map<String, Object?>> _sub;
  final _buffered = <Map<String, Object?>>[];
  final _completers = <Completer<Map<String, Object?>>>[];
  bool _closed = false;

  @override
  Future<Map<String, Object?>> readMessage() async {
    if (_closed) throw StateError('Closed');
    if (_buffered.isNotEmpty) {
      return _buffered.removeAt(0);
    }
    final completer = Completer<Map<String, Object?>>();
    _completers.add(completer);
    return completer.future;
  }

  @override
  Future<void> writeMessage(Map<String, Object?> message) async {
    if (_closed) throw StateError('Closed');
    _out.add(Map<String, Object?>.from(message));
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _sub.cancel();
  }
}
