// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/session_error.dart';
import 'package:remotex/core/services/device_identity_service.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/session_authenticator.dart';
import 'package:remotex/core/services/session_key_manager.dart';
import 'package:remotex/core/services/session_transport.dart';
import 'package:remotex/services/session/aes_gcm_session_channel.dart';

class SignedSessionAuthenticator implements SessionAuthenticator {
  SignedSessionAuthenticator({
    required DeviceIdentityService identityService,
    required SessionKeyManager keyManager,
    DateTime Function()? clock,
    Random? random,
  }) : _identityService = identityService,
       _keyManager = keyManager,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  static const protocolVersion = 1;
  static const challengeLifetime = Duration(seconds: 45);
  static const _nonceLength = 32;
  static const _sessionIdLength = 24;

  final DeviceIdentityService _identityService;
  final SessionKeyManager _keyManager;
  final DateTime Function() _clock;
  final Random _random;
  final Map<String, DateTime> _seenClientNonces = {};

  @override
  Future<AuthenticatedSession> authenticateClient(
    SessionWire wire,
    PairedDevice trustedHost,
  ) async {
    final identity = await _identityService.getOrCreateIdentity();
    final ephemeral = await _keyManager.createEphemeralKey();
    final clientNonce = _randomBytes(_nonceLength);
    final sessionId = _randomId(_sessionIdLength);
    final issuedAt = _clock().toUtc().millisecondsSinceEpoch;
    final initTranscript = _clientTranscript(
      sessionId: sessionId,
      clientId: identity.id,
      clientName: 'Android controller',
      clientPublicKey: identity.publicKey,
      clientEphemeralKey: ephemeral.publicKey,
      clientNonce: clientNonce,
      issuedAt: issuedAt,
    );
    await wire.writeMessage({
      'type': 'client_hello',
      'version': protocolVersion,
      'sessionId': sessionId,
      'clientId': identity.id,
      'clientName': 'Android controller',
      'clientPublicKey': identity.publicKey,
      'clientEphemeralKey': ephemeral.publicKey,
      'clientNonce': base64Encode(clientNonce),
      'issuedAt': issuedAt,
      'signature': base64Encode(await _identityService.sign(initTranscript)),
    });

    final challenge = await wire.readMessage();
    _throwRemoteError(challenge);
    _requireType(challenge, 'host_challenge');
    if (challenge['version'] != protocolVersion) {
      throw const SessionException(SessionError.protocolMismatch);
    }
    final responseSessionId = _requiredString(challenge, 'sessionId');
    final hostId = _requiredString(challenge, 'hostId');
    final hostName = _requiredString(challenge, 'hostName');
    final hostPublicKey = _requiredString(challenge, 'hostPublicKey');
    final hostEphemeralKey = _requiredString(challenge, 'hostEphemeralKey');
    final echoedClientNonce = _decode(challenge, 'clientNonce');
    final hostNonce = _decode(challenge, 'hostNonce');
    final hostIssuedAt = _requiredInt(challenge, 'issuedAt');
    final signature = _decode(challenge, 'signature');
    if (!_isFresh(hostIssuedAt)) {
      throw const SessionException(SessionError.expiredChallenge);
    }
    if (responseSessionId != sessionId ||
        hostId != trustedHost.id ||
        hostId != trustedHost.hostId ||
        hostPublicKey != trustedHost.publicKey ||
        hostNonce.length != _nonceLength ||
        !_sameBytes(clientNonce, echoedClientNonce)) {
      throw const SessionException(SessionError.authenticationFailed);
    }
    final transcript = _fullTranscript(
      sessionId: sessionId,
      clientId: identity.id,
      clientName: 'Android controller',
      clientPublicKey: identity.publicKey,
      clientEphemeralKey: ephemeral.publicKey,
      clientNonce: clientNonce,
      clientIssuedAt: issuedAt,
      hostId: hostId,
      hostName: hostName,
      hostPublicKey: hostPublicKey,
      hostEphemeralKey: hostEphemeralKey,
      hostNonce: hostNonce,
      hostIssuedAt: hostIssuedAt,
    );
    if (!await _identityService.verify(
      publicKey: hostPublicKey,
      message: transcript,
      signature: signature,
    )) {
      throw const SessionException(SessionError.authenticationFailed);
    }
    final keys = await _keyManager.deriveKeys(
      localKey: ephemeral,
      remotePublicKey: hostEphemeralKey,
      salt: [...clientNonce, ...hostNonce],
      context: transcript,
    );
    await wire.writeMessage({
      'type': 'client_finish',
      'sessionId': sessionId,
      'signature': base64Encode(await _identityService.sign(transcript)),
      'confirmation': await _confirmation(
        keys.confirmation,
        'client-finish',
        transcript,
      ),
    });
    final established = await wire.readMessage();
    _throwRemoteError(established);
    _requireType(established, 'session_established');
    if (established['sessionId'] != sessionId ||
        !await _verifyConfirmation(
          keys.confirmation,
          'host-finish',
          transcript,
          _requiredString(established, 'confirmation'),
        )) {
      throw const SessionException(SessionError.authenticationFailed);
    }
    return AuthenticatedSession(
      sessionId: sessionId,
      peerId: hostId,
      peerName: hostName,
      isController: true,
      wire: wire,
      secureChannel: AesGcmSessionChannel(
        wire: wire,
        sessionId: sessionId,
        sendKey: keys.controllerToHost,
        receiveKey: keys.hostToController,
        sendDirection: 'controller-to-host',
        receiveDirection: 'host-to-controller',
      ),
    );
  }

  @override
  Future<AuthenticatedSession> authenticateHost(
    SessionWire wire,
    PairedDevicesService trustedDevices,
    String hostId,
  ) async {
    final hello = await wire.readMessage();
    _requireType(hello, 'client_hello');
    if (hello['version'] != protocolVersion) {
      throw const SessionException(SessionError.protocolMismatch);
    }
    final sessionId = _requiredString(hello, 'sessionId');
    final clientId = _requiredString(hello, 'clientId');
    final clientPublicKey = _requiredString(hello, 'clientPublicKey');
    final clientName = _requiredString(hello, 'clientName');
    final clientEphemeralKey = _requiredString(hello, 'clientEphemeralKey');
    final clientNonce = _decode(hello, 'clientNonce');
    final issuedAt = _requiredInt(hello, 'issuedAt');
    final signature = _decode(hello, 'signature');
    if (sessionId.length != _sessionIdLength * 2 ||
        clientNonce.length != _nonceLength ||
        !_isFresh(issuedAt)) {
      throw const SessionException(SessionError.expiredChallenge);
    }
    final trusted = await trustedDevices.getPairedDevices();
    final peer = trusted.where((device) => device.id == clientId).firstOrNull;
    if (peer == null || peer.hostId != hostId) {
      if (await trustedDevices.isRevoked(clientId)) {
        throw const SessionException(SessionError.revoked);
      }
      throw const SessionException(SessionError.unknownDevice);
    }
    if (peer.publicKey != clientPublicKey ||
        await _identityService.idForPublicKey(clientPublicKey) != clientId) {
      throw const SessionException(SessionError.authenticationFailed);
    }
    final nonceKey = '$clientId:${base64Encode(clientNonce)}';
    _discardExpiredNonces();
    if (_seenClientNonces.containsKey(nonceKey)) {
      throw const SessionException(SessionError.replayedHandshake);
    }
    if (_seenClientNonces.length >= 4096) {
      _seenClientNonces.remove(_seenClientNonces.keys.first);
    }
    _seenClientNonces[nonceKey] = _clock().toUtc().add(challengeLifetime);
    final initTranscript = _clientTranscript(
      sessionId: sessionId,
      clientId: clientId,
      clientName: clientName,
      clientPublicKey: clientPublicKey,
      clientEphemeralKey: clientEphemeralKey,
      clientNonce: clientNonce,
      issuedAt: issuedAt,
    );
    if (!await _identityService.verify(
      publicKey: clientPublicKey,
      message: initTranscript,
      signature: signature,
    )) {
      throw const SessionException(SessionError.authenticationFailed);
    }

    final identity = await _identityService.getOrCreateIdentity();
    if (identity.id != hostId) {
      throw const SessionException(SessionError.authenticationFailed);
    }
    final ephemeral = await _keyManager.createEphemeralKey();
    final hostNonce = _randomBytes(_nonceLength);
    final hostIssuedAt = _clock().toUtc().millisecondsSinceEpoch;
    final transcript = _fullTranscript(
      sessionId: sessionId,
      clientId: clientId,
      clientName: clientName,
      clientPublicKey: clientPublicKey,
      clientEphemeralKey: clientEphemeralKey,
      clientNonce: clientNonce,
      clientIssuedAt: issuedAt,
      hostId: identity.id,
      hostName: Platform.localHostname,
      hostPublicKey: identity.publicKey,
      hostEphemeralKey: ephemeral.publicKey,
      hostNonce: hostNonce,
      hostIssuedAt: hostIssuedAt,
    );
    await wire.writeMessage({
      'type': 'host_challenge',
      'version': protocolVersion,
      'sessionId': sessionId,
      'hostId': identity.id,
      'hostName': Platform.localHostname,
      'hostPublicKey': identity.publicKey,
      'hostEphemeralKey': ephemeral.publicKey,
      'clientNonce': base64Encode(clientNonce),
      'hostNonce': base64Encode(hostNonce),
      'issuedAt': hostIssuedAt,
      'signature': base64Encode(await _identityService.sign(transcript)),
    });
    final keys = await _keyManager.deriveKeys(
      localKey: ephemeral,
      remotePublicKey: clientEphemeralKey,
      salt: [...clientNonce, ...hostNonce],
      context: transcript,
    );
    final finish = await wire.readMessage();
    _requireType(finish, 'client_finish');
    if (finish['sessionId'] != sessionId ||
        !await _identityService.verify(
          publicKey: clientPublicKey,
          message: transcript,
          signature: _decode(finish, 'signature'),
        ) ||
        !await _verifyConfirmation(
          keys.confirmation,
          'client-finish',
          transcript,
          _requiredString(finish, 'confirmation'),
        )) {
      throw const SessionException(SessionError.authenticationFailed);
    }
    if (!await trustedDevices.contains(clientId)) {
      if (await trustedDevices.isRevoked(clientId)) {
        throw const SessionException(SessionError.revoked);
      }
      throw const SessionException(SessionError.unknownDevice);
    }
    await wire.writeMessage({
      'type': 'session_established',
      'sessionId': sessionId,
      'confirmation': await _confirmation(
        keys.confirmation,
        'host-finish',
        transcript,
      ),
    });
    return AuthenticatedSession(
      sessionId: sessionId,
      peerId: clientId,
      peerName: peer.name,
      isController: false,
      wire: wire,
      secureChannel: AesGcmSessionChannel(
        wire: wire,
        sessionId: sessionId,
        sendKey: keys.hostToController,
        receiveKey: keys.controllerToHost,
        sendDirection: 'host-to-controller',
        receiveDirection: 'controller-to-host',
      ),
    );
  }

  Future<String> _confirmation(
    List<int> key,
    String label,
    List<int> transcript,
  ) async {
    final mac = await Hmac.sha256().calculateMac([
      ...utf8.encode(label),
      ...transcript,
    ], secretKey: SecretKey(key));
    return base64Encode(mac.bytes);
  }

  Future<bool> _verifyConfirmation(
    List<int> key,
    String label,
    List<int> transcript,
    String provided,
  ) async {
    final List<int> actual;
    try {
      actual = base64Decode(provided);
    } on FormatException {
      return false;
    }
    final expected = base64Decode(await _confirmation(key, label, transcript));
    return _sameBytes(expected, actual);
  }

  void _discardExpiredNonces() {
    final now = _clock().toUtc();
    _seenClientNonces.removeWhere((_, expires) => !now.isBefore(expires));
  }

  bool _isFresh(int timestamp) {
    final now = _clock().toUtc().millisecondsSinceEpoch;
    return (now - timestamp).abs() <= challengeLifetime.inMilliseconds;
  }

  List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256));

  String _randomId(int bytes) =>
      _randomBytes(bytes)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();

  static List<int> _clientTranscript({
    required String sessionId,
    required String clientId,
    required String clientName,
    required String clientPublicKey,
    required String clientEphemeralKey,
    required List<int> clientNonce,
    required int issuedAt,
  }) => utf8.encode(
    jsonEncode([
      'remotex-session-client-v1',
      protocolVersion,
      sessionId,
      clientId,
      clientName,
      clientPublicKey,
      clientEphemeralKey,
      base64Encode(clientNonce),
      issuedAt,
    ]),
  );

  static List<int> _fullTranscript({
    required String sessionId,
    required String clientId,
    required String clientName,
    required String clientPublicKey,
    required String clientEphemeralKey,
    required List<int> clientNonce,
    required int clientIssuedAt,
    required String hostId,
    required String hostName,
    required String hostPublicKey,
    required String hostEphemeralKey,
    required List<int> hostNonce,
    required int hostIssuedAt,
  }) => utf8.encode(
    jsonEncode([
      'remotex-session-transcript-v1',
      protocolVersion,
      sessionId,
      clientId,
      clientName,
      clientPublicKey,
      clientEphemeralKey,
      base64Encode(clientNonce),
      clientIssuedAt,
      hostId,
      hostName,
      hostPublicKey,
      hostEphemeralKey,
      base64Encode(hostNonce),
      hostIssuedAt,
    ]),
  );

  static String _requiredString(Map<String, Object?> values, String key) {
    final value = values[key];
    if (value is! String || value.isEmpty || value.length > 4096) {
      throw const SessionException(SessionError.malformedMessage);
    }
    return value;
  }

  static int _requiredInt(Map<String, Object?> values, String key) {
    final value = values[key];
    if (value is! int || value < 0) {
      throw const SessionException(SessionError.malformedMessage);
    }
    return value;
  }

  static List<int> _decode(Map<String, Object?> values, String key) {
    try {
      return base64Decode(_requiredString(values, key));
    } on FormatException {
      throw const SessionException(SessionError.malformedMessage);
    }
  }

  static void _requireType(Map<String, Object?> message, String type) {
    if (message['type'] == 'error') {
      _throwRemoteError(message);
    }
    if (message['type'] != type) {
      throw const SessionException(SessionError.malformedMessage);
    }
  }

  static void _throwRemoteError(Map<String, Object?> message) {
    if (message['type'] != 'error') return;
    final error = SessionError.values.where(
      (value) => value.name == message['code'],
    );
    throw SessionException(
      error.firstOrNull ?? SessionError.authenticationFailed,
    );
  }

  static bool _sameBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first[index] ^ second[index];
    }
    return difference == 0;
  }
}
