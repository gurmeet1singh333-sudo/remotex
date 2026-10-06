// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/pairing_qr_payload.dart';
import 'package:remotex/core/models/remote_host.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/services/device_identity_service.dart';
import 'package:remotex/core/services/pairing_failure.dart';
import 'package:remotex/core/services/pairing_service.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/services/discovery/bonjour_host_advertiser.dart';
import 'package:remotex/services/pairing/pairing_nonce_manager.dart';

class LanPairingService implements PairingService, HostPairingService {
  LanPairingService({
    required DeviceIdentityService identityService,
    required PairedDevicesService pairedDevicesService,
    HostAdvertiser? advertiser,
    PairingNonceManager? nonceManager,
    InternetAddress? bindAddress,
    DateTime Function()? clock,
  }) : _identityService = identityService,
       _pairedDevicesService = pairedDevicesService,
       _advertiser = advertiser ?? BonjourHostAdvertiser(),
       _nonceManager = nonceManager ?? PairingNonceManager(clock: clock),
       _clock = clock ?? DateTime.now,
       _bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  static const protocolVersion = 1;
  static const _requestTimeout = Duration(seconds: 8);
  static const _maximumMessageLength = 4096;

  final DeviceIdentityService _identityService;
  final PairedDevicesService _pairedDevicesService;
  final HostAdvertiser _advertiser;
  final PairingNonceManager _nonceManager;
  final DateTime Function() _clock;
  final InternetAddress _bindAddress;
  final _statusController = StreamController<HostPairingStatus>.broadcast();

  ServerSocket? _server;
  Timer? _pairingExpiryTimer;
  HostPairingStatus? _status;
  Future<void> _pairingQueue = Future<void>.value();
  int _activeClients = 0;
  ConnectionTask<Socket>? _clientConnectionTask;
  Socket? _clientSocket;
  bool _cancelRequested = false;

  @override
  HostPairingStatus? get status {
    return _status;
  }

  @override
  Stream<HostPairingStatus> get statusChanges => _statusController.stream;

  @override
  Future<void> start() async {
    if (_server != null) return;
    final identity = await _identityService.getOrCreateIdentity();
    final existingDevices = await _pairedDevicesService.getPairedDevices();
    final addresses = await _localIpv4Addresses();
    final server = await ServerSocket.bind(_bindAddress, 0);
    final hostName = Platform.localHostname;
    final initialStatus = HostPairingStatus(
      hostName: hostName,
      hostId: identity.id,
      hostPublicKey: identity.publicKey,
      port: server.port,
      addresses: addresses,
      isRunning: true,
      pairedDeviceCount: existingDevices.length,
    );
    try {
      await _advertiser.start(
        hostId: identity.id,
        hostName: hostName,
        port: server.port,
      );
    } catch (error) {
      await server.close();
      _nonceManager.invalidate();
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    _server = server;
    _status = initialStatus;
    server.listen(_acceptClient, onError: _onServerError);
    _statusController.add(initialStatus);
  }

  void _acceptClient(Socket socket) {
    if (_activeClients >= 8) {
      socket.destroy();
      return;
    }
    _activeClients++;
    unawaited(
      _runQueuedPairing(socket).whenComplete(() {
        _activeClients--;
        socket.destroy();
      }),
    );
  }

  Future<void> _runQueuedPairing(Socket socket) async {
    final previous = _pairingQueue;
    final finished = Completer<void>();
    _pairingQueue = finished.future;
    await previous;
    final channel = _JsonSocketChannel(socket);
    try {
      await _servePairingRequest(channel);
    } on PairingException catch (error) {
      final status = _status;
      if (status != null) {
        final nonce = _nonceManager.currentNonce;
        _emitStatus(
          status.copyWith(
            pairingNonce: nonce,
            expiresAt: _nonceManager.expiresAt,
            clearPairingSession: nonce == null,
            isPairingLocked: _nonceManager.isLocked,
          ),
        );
      }
      await channel.write({'type': 'error', 'code': error.failure.name});
    } on FormatException {
      await channel.write({
        'type': 'error',
        'code': PairingFailure.invalidRequest.name,
      });
    } on TimeoutException {
      await channel.write({
        'type': 'error',
        'code': PairingFailure.hostUnavailable.name,
      });
    } on SocketException {
      _emitStatus(
        _status!.copyWith(errorMessage: 'A network pairing request failed.'),
      );
    } finally {
      await channel.close();
      finished.complete();
    }
  }

  Future<void> _servePairingRequest(_JsonSocketChannel channel) async {
    final status = _status;
    if (status == null || !status.isRunning) {
      throw const PairingException(PairingFailure.hostUnavailable);
    }
    final request = await channel.read();
    if (request['type'] != 'hello' ||
        request['version'] != protocolVersion ||
        request['hostId'] != status.hostId) {
      throw const PairingException(PairingFailure.incompatibleHost);
    }
    final clientId = _requiredString(request, 'clientId');
    final clientName = _requiredString(request, 'clientName');
    final clientPublicKey = _requiredString(request, 'clientPublicKey');
    final clientNonce = _requiredString(request, 'clientNonce');
    final clientProof = _requiredString(request, 'clientProof');
    if (clientName.length > 80 || clientNonce.length > 128) {
      throw const PairingException(PairingFailure.invalidRequest);
    }
    if (await _identityService.idForPublicKey(clientPublicKey) != clientId) {
      throw const PairingException(PairingFailure.invalidRequest);
    }

    final nonce = _nonceManager.currentNonce;
    if (nonce == null) {
      throw const PairingException(PairingFailure.expiredPairingSession);
    }
    final identity = await _identityService.getOrCreateIdentity();
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
    switch (codeValidation) {
      case PairingNonceValidation.valid:
        break;
      case PairingNonceValidation.invalid:
        throw const PairingException(PairingFailure.invalidBootstrap);
      case PairingNonceValidation.expired:
      case PairingNonceValidation.invalidated:
        throw const PairingException(PairingFailure.expiredPairingSession);
      case PairingNonceValidation.locked:
        throw const PairingException(PairingFailure.tooManyAttempts);
    }
    if (await _pairedDevicesService.contains(clientId)) {
      throw const PairingException(PairingFailure.alreadyPaired);
    }

    final hostNonce = _randomNonce();
    final hostTranscript = _hostProofTranscript(
      hostId: identity.id,
      hostName: status.hostName,
      hostPublicKey: identity.publicKey,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      clientId: clientId,
      clientPublicKey: clientPublicKey,
    );
    final hostProof = await _identityService.createProof(nonce, hostTranscript);
    await channel.write({
      'type': 'challenge',
      'version': protocolVersion,
      'hostId': identity.id,
      'hostName': status.hostName,
      'hostPublicKey': identity.publicKey,
      'hostNonce': hostNonce,
      'hostProof': hostProof,
      'hostSignature': base64Encode(
        await _identityService.sign(hostTranscript),
      ),
    });

    final finish = await channel.read();
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
    if (_nonceManager.currentNonce != nonce) {
      throw const PairingException(PairingFailure.expiredPairingSession);
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
    _pairingExpiryTimer?.cancel();
    _pairingExpiryTimer = null;
    final deviceCount = (await _pairedDevicesService.getPairedDevices()).length;
    _emitStatus(
      _status!.copyWith(
        clearPairingSession: true,
        pairedDeviceCount: deviceCount,
      ),
    );
    await channel.write({'type': 'paired'});
  }

  @override
  Future<PairedDevice> pair(PairingQrPayload payload) async {
    _cancelRequested = false;
    final validatedPayload = PairingQrPayload.parse(
      payload.encode(),
      clock: _clock,
    );
    final host = RemoteHost(
      id: validatedPayload.hostId,
      name: validatedPayload.hostName,
      port: validatedPayload.port,
      protocolVersion: validatedPayload.protocolVersion,
      addresses: validatedPayload.addresses,
    );
    if (host.protocolVersion != protocolVersion) {
      throw const PairingException(PairingFailure.incompatibleHost);
    }
    if (await _identityService.idForPublicKey(
          validatedPayload.hostPublicKey,
        ) !=
        host.id) {
      throw const PairingException(PairingFailure.invalidRequest);
    }
    if (await _pairedDevicesService.contains(host.id)) {
      throw const PairingException(PairingFailure.alreadyPaired);
    }
    if (_cancelRequested) {
      throw const PairingException(PairingFailure.cancelled);
    }
    final identity = await _identityService.getOrCreateIdentity();
    if (_cancelRequested) {
      throw const PairingException(PairingFailure.cancelled);
    }
    Socket? socket;
    _JsonSocketChannel? channel;
    try {
      final addresses = host.addresses
          .map(InternetAddress.tryParse)
          .whereType<InternetAddress>()
          .toList(growable: false);
      if (addresses.isEmpty) {
        throw const PairingException(PairingFailure.hostUnavailable);
      }
      for (final address in addresses) {
        try {
          final task = await Socket.startConnect(address, host.port);
          _clientConnectionTask = task;
          if (_cancelRequested) {
            task.cancel();
            throw const PairingException(PairingFailure.cancelled);
          }
          try {
            socket = await task.socket.timeout(_requestTimeout);
          } on TimeoutException {
            task.cancel();
            continue;
          } finally {
            if (identical(_clientConnectionTask, task)) {
              _clientConnectionTask = null;
            }
          }
          _clientSocket = socket;
          break;
        } on PairingException {
          if (_cancelRequested) {
            throw const PairingException(PairingFailure.cancelled);
          }
          rethrow;
        } on SocketException {
          continue;
        }
      }
      if (_cancelRequested) {
        throw const PairingException(PairingFailure.cancelled);
      }
      if (socket == null) {
        throw const PairingException(PairingFailure.hostUnavailable);
      }
      channel = _JsonSocketChannel(socket);
      final clientNonce = _randomNonce();
      final initialTranscript = _clientProofTranscript(
        hostId: host.id,
        clientNonce: clientNonce,
        clientId: identity.id,
        clientName: 'Android controller',
        clientPublicKey: identity.publicKey,
      );
      await channel.write({
        'type': 'hello',
        'version': protocolVersion,
        'hostId': host.id,
        'clientId': identity.id,
        'clientName': 'Android controller',
        'clientPublicKey': identity.publicKey,
        'clientNonce': clientNonce,
        'clientProof': await _identityService.createProof(
          validatedPayload.pairingNonce,
          initialTranscript,
        ),
      });
      final challenge = await channel.read();
      _throwForRemoteError(challenge);
      if (challenge['type'] != 'challenge' ||
          challenge['version'] != protocolVersion ||
          challenge['hostId'] != host.id) {
        throw const PairingException(PairingFailure.incompatibleHost);
      }
      final hostName = _requiredString(challenge, 'hostName');
      final hostPublicKey = _requiredString(challenge, 'hostPublicKey');
      final hostNonce = _requiredString(challenge, 'hostNonce');
      final hostProof = _requiredString(challenge, 'hostProof');
      final hostSignature = base64Decode(
        _requiredString(challenge, 'hostSignature'),
      );
      if (hostName != validatedPayload.hostName ||
          hostPublicKey != validatedPayload.hostPublicKey ||
          await _identityService.idForPublicKey(hostPublicKey) != host.id) {
        throw const PairingException(PairingFailure.invalidRequest);
      }
      final hostTranscript = _hostProofTranscript(
        hostId: host.id,
        hostName: hostName,
        hostPublicKey: hostPublicKey,
        clientNonce: clientNonce,
        hostNonce: hostNonce,
        clientId: identity.id,
        clientPublicKey: identity.publicKey,
      );
      final hostProofValid = await _identityService.verifyProof(
        secret: validatedPayload.pairingNonce,
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
        hostId: host.id,
        clientId: identity.id,
        clientNonce: clientNonce,
        hostNonce: hostNonce,
      );
      await channel.write({
        'type': 'finish',
        'proof': await _identityService.createProof(
          validatedPayload.pairingNonce,
          finishTranscript,
        ),
        'clientSignature': base64Encode(
          await _identityService.sign(finishTranscript),
        ),
      });
      if (_cancelRequested) {
        throw const PairingException(PairingFailure.cancelled);
      }
      final response = await channel.read();
      _throwForRemoteError(response);
      if (response['type'] != 'paired') {
        throw const PairingException(PairingFailure.invalidRequest);
      }
      final pairedDevice = PairedDevice(
        id: host.id,
        name: hostName,
        hostId: host.id,
        publicKey: hostPublicKey,
        addedAt: _clock().toUtc(),
        authorizationScopes: const {
          AuthorizationScope.session,
          AuthorizationScope.screenView,
        },
      );
      await _pairedDevicesService.addPairedDevice(pairedDevice);
      return pairedDevice;
    } on PairingException {
      if (_cancelRequested) {
        throw const PairingException(PairingFailure.cancelled);
      }
      rethrow;
    } on SocketException {
      if (_cancelRequested) {
        throw const PairingException(PairingFailure.cancelled);
      }
      throw const PairingException(PairingFailure.hostUnavailable);
    } on TimeoutException {
      if (_cancelRequested) {
        throw const PairingException(PairingFailure.cancelled);
      }
      throw const PairingException(PairingFailure.hostUnavailable);
    } on FormatException {
      throw const PairingException(PairingFailure.invalidRequest);
    } finally {
      await channel?.close();
      socket?.destroy();
      if (identical(_clientSocket, socket)) _clientSocket = null;
      _clientConnectionTask = null;
      _cancelRequested = false;
    }
  }

  @override
  Future<void> cancelPairing() {
    _cancelRequested = true;
    _clientConnectionTask?.cancel();
    _clientSocket?.destroy();
    return Future<void>.value();
  }

  @override
  Future<void> startPairingSession() async {
    final current = _status;
    if (_server == null || current == null) {
      throw StateError('The LAN pairing host is not running.');
    }
    if (current.addresses.isEmpty) {
      throw StateError('No LAN network address is available for pairing.');
    }
    final nonce = _nonceManager.generate();
    _pairingExpiryTimer?.cancel();
    _emitStatus(HostPairingStatus(
      hostName: current.hostName,
      hostId: current.hostId,
      hostPublicKey: current.hostPublicKey,
      port: current.port,
      addresses: current.addresses,
      pairingNonce: nonce,
      expiresAt: _nonceManager.expiresAt,
      isRunning: current.isRunning,
      pairedDeviceCount: current.pairedDeviceCount,
    ));
    final expiresAt = _nonceManager.expiresAt!;
    _pairingExpiryTimer = Timer(expiresAt.difference(_clock()), () {
      if (_server != null && _nonceManager.currentNonce == null) {
        _pairingExpiryTimer = null;
        _emitStatus(_status!.copyWith(
          clearPairingSession: true,
          isPairingLocked: _nonceManager.isLocked,
        ));
      }
    });
  }

  @override
  Future<void> cancelPairingSession() async {
    final current = _status;
    if (current == null) return;
    _nonceManager.invalidate();
    _pairingExpiryTimer?.cancel();
    _pairingExpiryTimer = null;
    _emitStatus(current.copyWith(clearPairingSession: true));
  }

  @override
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _nonceManager.invalidate();
    _pairingExpiryTimer?.cancel();
    _pairingExpiryTimer = null;
    await _advertiser.stop();
    await server?.close();
    final current = _status;
    if (current != null) {
      _emitStatus(
        current.copyWith(isRunning: false, clearPairingSession: true),
      );
    }
  }

  void _onServerError(Object error) {
    _emitStatus(
      _status!.copyWith(
        isRunning: false,
        clearPairingSession: true,
        errorMessage: 'The local pairing service stopped unexpectedly.',
      ),
    );
  }

  void _emitStatus(HostPairingStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
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
  }) => utf8.encode(
    jsonEncode([
      'remotex-pair-client-v1',
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
  }) => utf8.encode(
    jsonEncode([
      'remotex-pair-host-v1',
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
  }) => utf8.encode(
    jsonEncode([
      'remotex-pair-finish-v1',
      hostId,
      clientId,
      clientNonce,
      hostNonce,
    ]),
  );

  static Future<List<String>> _localIpv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final addresses = <String>{};
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (PairingQrPayload.isLanAddress(address) &&
            !address.isLoopback &&
            !address.isLinkLocal) {
          addresses.add(address.address);
        }
      }
    }
    return List.unmodifiable(addresses.take(8));
  }

  static String _randomNonce() {
    final random = Random.secure();
    return base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  static void _throwForRemoteError(Map<String, Object?> response) {
    if (response['type'] != 'error') return;
    final code = response['code'];
    final failure = PairingFailure.values.where((value) => value.name == code);
    throw PairingException(
      failure.isEmpty ? PairingFailure.invalidRequest : failure.first,
    );
  }
}

class _JsonSocketChannel {
  _JsonSocketChannel(this._socket)
    : _lines = StreamIterator<String>(
        _socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

  final Socket _socket;
  final StreamIterator<String> _lines;

  Future<Map<String, Object?>> read() async {
    if (!await _lines.moveNext().timeout(LanPairingService._requestTimeout)) {
      throw const PairingException(PairingFailure.hostUnavailable);
    }
    final line = _lines.current;
    if (line.length > LanPairingService._maximumMessageLength) {
      throw const PairingException(PairingFailure.invalidRequest);
    }
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      throw const FormatException('Pairing message must be a JSON object.');
    }
    try {
      return Map<String, Object?>.from(decoded);
    } on TypeError {
      throw const FormatException('Pairing message has invalid fields.');
    }
  }

  Future<void> write(Map<String, Object?> message) async {
    final encoded = jsonEncode(message);
    if (encoded.length > LanPairingService._maximumMessageLength) {
      throw const PairingException(PairingFailure.invalidRequest);
    }
    _socket.write('$encoded\n');
    await _socket.flush();
  }

  Future<void> close() => _lines.cancel();
}
