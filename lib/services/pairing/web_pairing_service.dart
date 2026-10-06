// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/web_pairing_payload.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/services/device_identity_service.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/pairing_failure.dart';
import 'package:remotex/core/services/session_transport.dart';
import 'package:remotex/services/pairing/pairing_nonce_manager.dart';

class WebPairingService {
  WebPairingService({
    required DeviceIdentityService identityService,
    required PairedDevicesService pairedDevicesService,
    PairingNonceManager? nonceManager,
    DateTime Function()? clock,
  })  : _identityService = identityService,
        _pairedDevicesService = pairedDevicesService,
        _nonceManager = nonceManager ?? PairingNonceManager(clock: clock),
        _clock = clock ?? DateTime.now;

  static const protocolVersion = 1;
  static const _requestTimeout = Duration(seconds: 10);

  final DeviceIdentityService _identityService;
  final PairedDevicesService _pairedDevicesService;
  final PairingNonceManager _nonceManager;
  final DateTime Function() _clock;
  final _statusController = StreamController<WebPairingStatus>.broadcast();

  Timer? _expiryTimer;
  WebPairingStatus? _status;

  WebPairingStatus? get status => _status;
  Stream<WebPairingStatus> get statusChanges => _statusController.stream;

  Future<WebPairingPayload> startWebPairingSession({
    required String relayUrl,
  }) async {
    final identity = await _identityService.getOrCreateIdentity();

    final nonce = _nonceManager.generate();
    _expiryTimer?.cancel();

    final expiresAt = _nonceManager.expiresAt!;
    final sessionId = _randomHex(24);

    final payload = WebPairingPayload(
      hostId: identity.id,
      hostName: Platform.localHostname,
      hostPublicKey: identity.publicKey,
      relayUrl: relayUrl,
      pairingNonce: nonce,
      sessionId: sessionId,
      expiresAt: expiresAt,
    );

    final newStatus = WebPairingStatus(
      hostName: Platform.localHostname,
      hostId: identity.id,
      hostPublicKey: identity.publicKey,
      relayUrl: relayUrl,
      pairingNonce: nonce,
      sessionId: sessionId,
      expiresAt: expiresAt,
      isRunning: true,
    );

    _status = newStatus;
    _statusController.add(newStatus);

    _expiryTimer = Timer(expiresAt.difference(_clock()), () {
      if (_nonceManager.currentNonce == nonce) {
        cancelWebPairingSession();
      }
    });

    return payload;
  }

  Future<void> cancelWebPairingSession() async {
    _nonceManager.invalidate();
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final current = _status;
    if (current != null) {
      final updated = current.copyWith(clearPairingSession: true);
      _status = updated;
      _statusController.add(updated);
    }
  }

  Future<void> handleIncomingWebPairingWire(SessionWire wire) async {
    final nonce = _nonceManager.currentNonce;
    if (nonce == null) {
      await wire.writeMessage({
        'type': 'error',
        'code': PairingFailure.expiredPairingSession.name,
      });
      await wire.close();
      return;
    }

    try {
      final identity = await _identityService.getOrCreateIdentity();
      final hello = await wire.readMessage().timeout(_requestTimeout);

      if (hello['type'] != 'hello' ||
          hello['version'] != protocolVersion ||
          hello['hostId'] != identity.id) {
        throw const PairingException(PairingFailure.incompatibleHost);
      }

      final clientId = _requiredString(hello, 'clientId');
      final clientName = _requiredString(hello, 'clientName');
      final clientPublicKey = _requiredString(hello, 'clientPublicKey');
      final clientNonce = _requiredString(hello, 'clientNonce');
      final clientProof = _requiredString(hello, 'clientProof');

      final initialTranscript = _clientProofTranscript(
        hostId: identity.id,
        clientNonce: clientNonce,
        clientId: clientId,
        clientName: clientName,
        clientPublicKey: clientPublicKey,
      );

      final codeMatches = await _identityService.verifyProof(
        secret: nonce,
        message: initialTranscript,
        proof: clientProof,
      );

      final codeValidation = _nonceManager.recordAttempt(codeMatches);
      if (codeValidation != PairingNonceValidation.valid) {
        throw const PairingException(PairingFailure.invalidBootstrap);
      }

      final hostNonce = _randomHex(32);
      final hostTranscript = _hostProofTranscript(
        hostId: identity.id,
        hostName: Platform.localHostname,
        hostPublicKey: identity.publicKey,
        clientNonce: clientNonce,
        hostNonce: hostNonce,
        clientId: clientId,
        clientPublicKey: clientPublicKey,
      );

      final hostProof =
          await _identityService.createProof(nonce, hostTranscript);

      await wire.writeMessage({
        'type': 'challenge',
        'version': protocolVersion,
        'hostId': identity.id,
        'hostName': Platform.localHostname,
        'hostPublicKey': identity.publicKey,
        'hostNonce': hostNonce,
        'hostProof': hostProof,
        'hostSignature': base64Encode(
          await _identityService.sign(hostTranscript),
        ),
      });

      final finish = await wire.readMessage().timeout(_requestTimeout);
      if (finish['type'] != 'finish') {
        throw const PairingException(PairingFailure.invalidRequest);
      }

      final finishProof = _requiredString(finish, 'proof');
      final finishTranscript = _finishTranscript(
        hostId: identity.id,
        clientId: clientId,
        clientNonce: clientNonce,
        hostNonce: hostNonce,
      );

      final finishValid = await _identityService.verifyProof(
        secret: nonce,
        message: finishTranscript,
        proof: finishProof,
      );

      final clientSignature = base64Decode(
        _requiredString(finish, 'clientSignature'),
      );

      final identityValid = await _identityService.verify(
        publicKey: clientPublicKey,
        message: finishTranscript,
        signature: clientSignature,
      );

      if (!finishValid || !identityValid) {
        throw const PairingException(PairingFailure.invalidBootstrap);
      }

      await _pairedDevicesService.addPairedDevice(
        PairedDevice(
          id: clientId,
          name: clientName,
          hostId: identity.id,
          publicKey: clientPublicKey,
          addedAt: _clock().toUtc(),
          authorizationScopes: const {
            AuthorizationScope.session,
            AuthorizationScope.screenView,
          },
        ),
      );

      _nonceManager.invalidate();
      await cancelWebPairingSession();

      await wire.writeMessage({'type': 'paired'});
    } on PairingException catch (error) {
      await wire.writeMessage({'type': 'error', 'code': error.failure.name});
    } on Object {
      await wire.writeMessage({
        'type': 'error',
        'code': PairingFailure.invalidRequest.name,
      });
    }
  }

  Future<PairedDevice> pairWebClient({
    required WebPairingPayload payload,
    required SessionWire wire,
  }) async {
    final identity = await _identityService.getOrCreateIdentity();
    final clientNonce = _randomHex(32);

    final initialTranscript = _clientProofTranscript(
      hostId: payload.hostId,
      clientNonce: clientNonce,
      clientId: identity.id,
      clientName: 'Web Browser Remote',
      clientPublicKey: identity.publicKey,
    );

    await wire.writeMessage({
      'type': 'hello',
      'version': protocolVersion,
      'hostId': payload.hostId,
      'clientId': identity.id,
      'clientName': 'Web Browser Remote',
      'clientPublicKey': identity.publicKey,
      'clientNonce': clientNonce,
      'clientProof': await _identityService.createProof(
        payload.pairingNonce,
        initialTranscript,
      ),
    });

    final challenge = await wire.readMessage().timeout(_requestTimeout);
    _throwForRemoteError(challenge);
    if (challenge['type'] != 'challenge' ||
        challenge['version'] != protocolVersion ||
        challenge['hostId'] != payload.hostId) {
      throw const PairingException(PairingFailure.incompatibleHost);
    }

    final hostName = _requiredString(challenge, 'hostName');
    final hostPublicKey = _requiredString(challenge, 'hostPublicKey');
    final hostNonce = _requiredString(challenge, 'hostNonce');
    final hostProof = _requiredString(challenge, 'hostProof');
    final hostSignature = base64Decode(
      _requiredString(challenge, 'hostSignature'),
    );

    final hostTranscript = _hostProofTranscript(
      hostId: payload.hostId,
      hostName: hostName,
      hostPublicKey: hostPublicKey,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      clientId: identity.id,
      clientPublicKey: identity.publicKey,
    );

    final hostProofValid = await _identityService.verifyProof(
      secret: payload.pairingNonce,
      message: hostTranscript,
      proof: hostProof,
    );

    final hostIdentityValid = await _identityService.verify(
      publicKey: hostPublicKey,
      message: hostTranscript,
      signature: hostSignature,
    );

    if (!hostProofValid || !hostIdentityValid) {
      throw const PairingException(PairingFailure.invalidBootstrap);
    }

    final finishTranscript = _finishTranscript(
      hostId: payload.hostId,
      clientId: identity.id,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
    );

    await wire.writeMessage({
      'type': 'finish',
      'proof': await _identityService.createProof(
        payload.pairingNonce,
        finishTranscript,
      ),
      'clientSignature': base64Encode(
        await _identityService.sign(finishTranscript),
      ),
    });

    final response = await wire.readMessage().timeout(_requestTimeout);
    _throwForRemoteError(response);
    if (response['type'] != 'paired') {
      throw const PairingException(PairingFailure.invalidRequest);
    }

    final pairedDevice = PairedDevice(
      id: payload.hostId,
      name: hostName,
      hostId: payload.hostId,
      publicKey: hostPublicKey,
      addedAt: _clock().toUtc(),
      authorizationScopes: const {
        AuthorizationScope.session,
        AuthorizationScope.screenView,
      },
    );

    await _pairedDevicesService.addPairedDevice(pairedDevice);
    return pairedDevice;
  }

  static void _throwForRemoteError(Map<String, Object?> response) {
    if (response['type'] != 'error') return;
    final code = response['code'];
    final failure = PairingFailure.values.where((value) => value.name == code);
    throw PairingException(
      failure.isEmpty ? PairingFailure.invalidRequest : failure.first,
    );
  }

  static String _requiredString(Map<String, Object?> values, String key) {
    final value = values[key];
    if (value is! String || value.isEmpty) {
      throw const PairingException(PairingFailure.invalidRequest);
    }
    return value;
  }

  static List<int> _clientProofTranscript({
    required String hostId,
    required String clientNonce,
    required String clientId,
    required String clientName,
    required String clientPublicKey,
  }) =>
      utf8.encode(
        jsonEncode([
          'remotex-web-pair-client-v1',
          hostId,
          clientNonce,
          clientId,
          clientName,
          clientPublicKey,
        ]),
      );

  static List<int> _hostProofTranscript({
    required String hostId,
    required String hostName,
    required String hostPublicKey,
    required String clientNonce,
    required String hostNonce,
    required String clientId,
    required String clientPublicKey,
  }) =>
      utf8.encode(
        jsonEncode([
          'remotex-web-pair-host-v1',
          hostId,
          hostName,
          hostPublicKey,
          clientNonce,
          hostNonce,
          clientId,
          clientPublicKey,
        ]),
      );

  static List<int> _finishTranscript({
    required String hostId,
    required String clientId,
    required String clientNonce,
    required String hostNonce,
  }) =>
      utf8.encode(
        jsonEncode([
          'remotex-web-pair-finish-v1',
          hostId,
          clientId,
          clientNonce,
          hostNonce,
        ]),
      );

  static String _randomHex(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

class WebPairingStatus {
  const WebPairingStatus({
    required this.hostName,
    required this.hostId,
    required this.hostPublicKey,
    required this.relayUrl,
    required this.isRunning,
    this.pairingNonce,
    this.sessionId,
    this.expiresAt,
  });

  final String hostName;
  final String hostId;
  final String hostPublicKey;
  final String relayUrl;
  final bool isRunning;
  final String? pairingNonce;
  final String? sessionId;
  final DateTime? expiresAt;

  WebPairingStatus copyWith({
    bool clearPairingSession = false,
  }) =>
      WebPairingStatus(
        hostName: hostName,
        hostId: hostId,
        hostPublicKey: hostPublicKey,
        relayUrl: relayUrl,
        isRunning: isRunning,
        pairingNonce: clearPairingSession ? null : pairingNonce,
        sessionId: clearPairingSession ? null : sessionId,
        expiresAt: clearPairingSession ? null : expiresAt,
      );
}
