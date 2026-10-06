import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/device_identity.dart';
import 'package:remotex/core/models/session_error.dart';
import 'package:remotex/core/services/session_authenticator.dart';
import 'package:remotex/core/services/session_transport.dart';
import 'package:remotex/services/identity/cryptographic_device_identity_service.dart';
import 'package:remotex/services/session/cryptographic_session_key_manager.dart';
import 'package:remotex/services/session/lan_session_transport.dart';
import 'package:remotex/services/session/signed_session_authenticator.dart';

import 'support/in_memory_secure_storage.dart';

void main() {
  late _SessionHarness harness;

  setUp(() async {
    harness = _SessionHarness();
    await harness.initialize();
  });

  tearDown(() async {
    await harness.close();
  });

  test(
    'authenticates both paired identities and encrypts data bidirectionally',
    () async {
      final session = await harness.connect();
      final hostSession = await harness.nextHostSession;

      expect(session.sessionId, hostSession.sessionId);
      expect(session.peerId, harness.hostIdentity!.id);
      expect(hostSession.peerId, harness.controllerIdentity!.id);

      await session.secureChannel.send(utf8.encode('authenticated payload'));
      expect(
        utf8.decode(await hostSession.secureChannel.receive()),
        'authenticated payload',
      );
      await hostSession.secureChannel.send(utf8.encode('host response'));
      expect(
        utf8.decode(await session.secureChannel.receive()),
        'host response',
      );

      await session.secureChannel.close();
      await hostSession.secureChannel.close();
    },
  );

  test('rejects a paired-host record with the wrong public identity', () async {
    final wrongIdentity = PairedDevice(
      id: harness.hostIdentity!.id,
      name: 'Host',
      hostId: harness.hostIdentity!.id,
      publicKey: base64Encode(List<int>.filled(32, 9)),
      addedAt: DateTime.utc(2026),
    );
    await expectLater(
      harness.connect(trustedHost: wrongIdentity),
      throwsA(
        isA<SessionException>().having(
          (error) => error.error,
          'error',
          SessionError.authenticationFailed,
        ),
      ),
    );
  });

  test('rejects an invalid Ed25519 signature', () async {
    await expectLater(
      harness.connect(mutateClientHelloSignature: true),
      throwsA(
        isA<SessionException>().having(
          (error) => error.error,
          'error',
          SessionError.authenticationFailed,
        ),
      ),
    );
    expect(await harness.nextHostError, SessionError.authenticationFailed);
  });

  test('rejects a replayed client authentication message', () async {
    final recordingWire = _RecordingWire();
    final session = await harness.connect(clientWire: recordingWire);
    final hostSession = await harness.nextHostSession;
    await session.secureChannel.close();
    await hostSession.secureChannel.close();

    final replaySocket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      harness.server.port,
    );
    final replayWire = JsonSocketSessionWire(replaySocket);
    await replayWire.writeMessage(recordingWire.clientHello!);

    final response = await replayWire.readMessage();
    expect(response['type'], 'error');
    expect(response['code'], SessionError.replayedHandshake.name);
    await replayWire.close();
  });

  test('rejects an expired host challenge', () async {
    final clientWire = _AdvanceClockOnChallengeWire(
      onChallenge: () => harness.clientNow = harness.clientNow.add(
        SignedSessionAuthenticator.challengeLifetime +
            const Duration(seconds: 1),
      ),
    );
    await expectLater(
      harness.connect(clientWire: clientWire),
      throwsA(
        isA<SessionException>().having(
          (error) => error.error,
          'error',
          SessionError.expiredChallenge,
        ),
      ),
    );
  });

  test('rejects an unknown and a revoked device', () async {
    await harness.hostDevices.removePairedDevice(
      harness.controllerIdentity!.id,
    );
    await expectLater(
      harness.connect(),
      throwsA(
        isA<SessionException>().having(
          (error) => error.error,
          'error',
          SessionError.unknownDevice,
        ),
      ),
    );

    await harness.hostDevices.addPairedDevice(harness.controllerRecord);
    await harness.hostDevices.revokePairedDevice(
      harness.controllerIdentity!.id,
    );
    await expectLater(
      harness.connect(),
      throwsA(
        isA<SessionException>().having(
          (error) => error.error,
          'error',
          SessionError.revoked,
        ),
      ),
    );
  });

  test('reports a disconnected encrypted session', () async {
    final client = await harness.connect();
    final host = await harness.nextHostSession;

    await host.secureChannel.close();

    await expectLater(
      client.secureChannel.receive(),
      throwsA(
        isA<SessionException>().having(
          (error) => error.error,
          'error',
          SessionError.networkDisconnected,
        ),
      ),
    );
  });

  test('performs a fresh authenticated handshake on reconnect', () async {
    final first = await harness.connect();
    final firstHost = await harness.nextHostSession;
    await first.secureChannel.close();
    await firstHost.secureChannel.close();

    final second = await harness.connect();
    final secondHost = await harness.nextHostSession;

    expect(second.sessionId, isNot(first.sessionId));
    expect(second.peerId, first.peerId);
    expect(secondHost.sessionId, second.sessionId);
    await second.secureChannel.close();
    await secondHost.secureChannel.close();
  });

  test('rejects protocol mismatch and malformed messages', () async {
    final mismatchWire = await harness.openWire();
    await mismatchWire.writeMessage({'type': 'client_hello', 'version': 999});
    final mismatch = await mismatchWire.readMessage();
    expect(mismatch['code'], SessionError.protocolMismatch.name);
    await mismatchWire.close();

    final malformedWire = await harness.openWire();
    await malformedWire.writeMessage({'type': 'unknown'});
    final malformed = await malformedWire.readMessage();
    expect(malformed['code'], SessionError.malformedMessage.name);
    await malformedWire.close();
  });

  test('rejects replayed encrypted frames by sequence number', () async {
    final recordingWire = _RecordingWire();
    final client = await harness.connect(clientWire: recordingWire);
    final host = await harness.nextHostSession;

    await client.secureChannel.send(utf8.encode('once'));
    expect(utf8.decode(await host.secureChannel.receive()), 'once');
    await recordingWire.replayLastWrite();
    await expectLater(
      host.secureChannel.receive(),
      throwsA(
        isA<SessionException>().having(
          (error) => error.error,
          'error',
          SessionError.replayedHandshake,
        ),
      ),
    );
  });
}

class _SessionHarness {
  final hostStorage = InMemorySecureStorage();
  final controllerStorage = InMemorySecureStorage();
  final hostDevices = InMemoryPairedDevicesService();
  final controllerDevices = InMemoryPairedDevicesService();
  final _pendingHostSessions = <AuthenticatedSession>[];
  final _pendingHostErrors = <SessionError>[];
  Completer<AuthenticatedSession>? _nextHostSession;
  Completer<SessionError>? _nextHostError;
  late CryptographicDeviceIdentityService hostIdentityService;
  late CryptographicDeviceIdentityService controllerIdentityService;
  late SignedSessionAuthenticator hostAuthenticator;
  late SignedSessionAuthenticator controllerAuthenticator;
  late ServerSocket server;
  late StreamSubscription<Socket> subscription;
  DeviceIdentity? hostIdentity;
  DeviceIdentity? controllerIdentity;
  late PairedDevice hostRecord;
  late PairedDevice controllerRecord;
  DateTime clientNow = DateTime.now().toUtc();

  Future<AuthenticatedSession> get nextHostSession {
    if (_pendingHostSessions.isNotEmpty) {
      return Future.value(_pendingHostSessions.removeAt(0));
    }
    _nextHostSession ??= Completer<AuthenticatedSession>();
    return _nextHostSession!.future.timeout(const Duration(seconds: 3));
  }

  Future<SessionError> get nextHostError {
    if (_pendingHostErrors.isNotEmpty) {
      return Future.value(_pendingHostErrors.removeAt(0));
    }
    _nextHostError ??= Completer<SessionError>();
    return _nextHostError!.future.timeout(const Duration(seconds: 3));
  }

  Future<void> initialize() async {
    hostIdentityService = CryptographicDeviceIdentityService(hostStorage);
    controllerIdentityService = CryptographicDeviceIdentityService(
      controllerStorage,
    );
    hostIdentity = await hostIdentityService.getOrCreateIdentity();
    controllerIdentity = await controllerIdentityService.getOrCreateIdentity();
    hostRecord = PairedDevice(
      id: hostIdentity!.id,
      name: 'Windows laptop',
      hostId: hostIdentity!.id,
      publicKey: hostIdentity!.publicKey,
      addedAt: DateTime.now().toUtc(),
    );
    controllerRecord = PairedDevice(
      id: controllerIdentity!.id,
      name: 'Android phone',
      hostId: hostIdentity!.id,
      publicKey: controllerIdentity!.publicKey,
      addedAt: DateTime.now().toUtc(),
    );
    await controllerDevices.addPairedDevice(hostRecord);
    await hostDevices.addPairedDevice(controllerRecord);
    hostAuthenticator = SignedSessionAuthenticator(
      identityService: hostIdentityService,
      keyManager: CryptographicSessionKeyManager(),
    );
    controllerAuthenticator = SignedSessionAuthenticator(
      identityService: controllerIdentityService,
      keyManager: CryptographicSessionKeyManager(),
      clock: () => clientNow,
    );
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    subscription = server.listen(_accept);
  }

  void _accept(Socket socket) {
    final wire = JsonSocketSessionWire(socket);
    unawaited(() async {
      try {
        _notifyHostSession(
          await hostAuthenticator.authenticateHost(
            wire,
            hostDevices,
            hostIdentity!.id,
          ),
        );
      } on SessionException catch (error) {
        _notifyHostError(error.error);
        try {
          await wire.writeMessage({'type': 'error', 'code': error.error.name});
        } on Object {
          // The peer may already have closed its connection.
        }
        await wire.close();
      }
    }());
  }

  Future<SessionWire> openWire() async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    return JsonSocketSessionWire(socket);
  }

  Future<AuthenticatedSession> connect({
    PairedDevice? trustedHost,
    bool mutateClientHelloSignature = false,
    SessionWire? clientWire,
  }) async {
    final baseWire = await openWire();
    if (clientWire is _RecordingWire) {
      clientWire.attach(baseWire);
    } else if (clientWire is _AdvanceClockOnChallengeWire) {
      clientWire.attach(baseWire);
    }
    final wire = clientWire ?? baseWire;
    final wrapped = mutateClientHelloSignature
        ? _MutatingSignatureWire(wire)
        : wire;
    try {
      return await controllerAuthenticator.authenticateClient(
        wrapped,
        trustedHost ?? hostRecord,
      );
    } catch (_) {
      await wrapped.close();
      rethrow;
    }
  }

  void _notifyHostSession(AuthenticatedSession session) {
    final completer = _nextHostSession;
    if (completer != null && !completer.isCompleted) {
      _nextHostSession = null;
      completer.complete(session);
    } else {
      _pendingHostSessions.add(session);
    }
  }

  void _notifyHostError(SessionError error) {
    final completer = _nextHostError;
    if (completer != null && !completer.isCompleted) {
      _nextHostError = null;
      completer.complete(error);
    } else {
      _pendingHostErrors.add(error);
    }
  }

  Future<void> close() async {
    await subscription.cancel();
    await server.close();
  }
}

class _RecordingWire implements SessionWire {
  SessionWire? _wire;
  final writes = <Map<String, Object?>>[];

  void attach(SessionWire wire) => _wire = wire;

  @override
  Future<void> close() async => _wire!.close();

  @override
  Future<Map<String, Object?>> readMessage() => _wire!.readMessage();

  @override
  Future<void> writeMessage(Map<String, Object?> message) async {
    writes.add(Map.of(message));
    await _wire!.writeMessage(message);
  }

  Future<void> replayLastWrite() async {
    await _wire!.writeMessage(writes.last);
  }

  Map<String, Object?>? get clientHello =>
      writes.where((message) => message['type'] == 'client_hello').firstOrNull;
}

class _MutatingSignatureWire implements SessionWire {
  _MutatingSignatureWire(this._wire);

  final SessionWire _wire;

  @override
  Future<void> close() => _wire.close();

  @override
  Future<Map<String, Object?>> readMessage() => _wire.readMessage();

  @override
  Future<void> writeMessage(Map<String, Object?> message) async {
    final altered = Map<String, Object?>.of(message);
    if (altered['type'] == 'client_hello') {
      final signature = base64Decode(altered['signature']! as String);
      signature[0] ^= 1;
      altered['signature'] = base64Encode(signature);
    }
    await _wire.writeMessage(altered);
  }
}

class _AdvanceClockOnChallengeWire implements SessionWire {
  _AdvanceClockOnChallengeWire({required this.onChallenge});

  final void Function() onChallenge;
  SessionWire? _wire;

  void attach(SessionWire wire) => _wire = wire;

  @override
  Future<void> close() async => _wire?.close();

  @override
  Future<Map<String, Object?>> readMessage() async {
    final message = await _wire!.readMessage();
    if (message['type'] == 'host_challenge') onChallenge();
    return message;
  }

  @override
  Future<void> writeMessage(Map<String, Object?> message) async {
    if (_wire == null) throw StateError('Wire is not connected.');
    await _wire!.writeMessage(message);
  }
}
