// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:developer' as developer;

import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/authorization_change.dart';
import 'package:remotex/core/models/session_error.dart';
import 'package:remotex/core/models/session_info.dart';
import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/models/session_state.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/protocol/message_envelope.dart';
import 'package:remotex/core/protocol/message_type.dart';
import 'package:remotex/core/protocol/protocol_error.dart';
import 'package:remotex/core/protocol/received_session_message.dart';
import 'package:remotex/core/protocol/session_authorization.dart';
import 'package:remotex/core/protocol/session_packet_multiplexer.dart';
import 'package:remotex/core/protocol/session_message_protocol.dart';
import 'package:remotex/core/services/device_identity_service.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/session_authenticator.dart';
import 'package:remotex/core/services/session_service.dart';
import 'package:remotex/core/services/session_transport.dart';
import 'package:remotex/core/services/secure_frame_transport.dart';
import 'package:remotex/services/session/binary_secure_frame_transport.dart';
import 'package:remotex/services/session/lan_session_transport.dart';

class LanSessionService implements SessionService {
  LanSessionService({
    required DeviceIdentityService identityService,
    required PairedDevicesService pairedDevicesService,
    required SessionTransport transport,
    required SessionAuthenticator authenticator,
    DateTime Function()? clock,
  }) : _identityService = identityService,
       _pairedDevicesService = pairedDevicesService,
       _transport = transport,
       _authenticator = authenticator,
       _clock = clock ?? DateTime.now;

  final DeviceIdentityService _identityService;
  final PairedDevicesService _pairedDevicesService;
  final SessionTransport _transport;
  final SessionAuthenticator _authenticator;
  final DateTime Function() _clock;
  final _stateController = StreamController<SessionState>.broadcast();
  final _messageController =
      StreamController<ReceivedSessionMessage>.broadcast();
  final _frameController = StreamController<ReceivedScreenFrame>.broadcast();
  final _closedSessionController = StreamController<String>.broadcast();
  final _authorizationChangeController =
      StreamController<AuthorizationChange>.broadcast();
  final Map<String, _ActiveSession> _activeSessions = {};
  StreamSubscription<SessionWire>? _hostSubscription;
  SessionState _state = SessionState.disconnected;
  PairedDevice? _lastHost;
  bool _cancelRequested = false;
  bool _intentionalDisconnect = false;
  bool _isReconnecting = false;

  @override
  SessionState get state => _state;

  @override
  String? get controllerSessionId => _activeSessions.values
      .where((active) => active.session.isController)
      .map((active) => active.session.sessionId)
      .firstOrNull;

  @override
  Stream<SessionState> get stateChanges => _stateController.stream;

  @override
  Stream<ReceivedSessionMessage> get incomingMessages =>
      _messageController.stream;

  @override
  Stream<ReceivedScreenFrame> get incomingFrames => _frameController.stream;

  @override
  Stream<String> get closedSessions => _closedSessionController.stream;

  @override
  Stream<AuthorizationChange> get authorizationChanges =>
      _authorizationChangeController.stream;

  @override
  Future<void> startHost() async {
    final identity = await _identityService.getOrCreateIdentity();
    await _transport.startHost(identity.id);
    await _hostSubscription?.cancel();
    _hostSubscription = _transport.incomingConnections.listen(_acceptHostWire);
  }

  Future<void> _acceptHostWire(SessionWire wire) async {
    _setState(SessionState.connecting);
    try {
      _setState(SessionState.authenticating);
      final identity = await _identityService.getOrCreateIdentity();
      final session = await _authenticator.authenticateHost(
        wire,
        _pairedDevicesService,
        identity.id,
      );
      if (wire is JsonSocketSessionWire) wire.allowAuthenticatedFrames();
      if (await _pairedDevicesService.isRevoked(session.peerId)) {
        throw const SessionException(SessionError.revoked);
      }
      if (!await _pairedDevicesService.contains(session.peerId)) {
        throw const SessionException(SessionError.unknownDevice);
      }
      final pairedDevice = (await _pairedDevicesService.getPairedDevices())
          .where((device) => device.id == session.peerId)
          .firstOrNull;
      if (pairedDevice == null) {
        throw const SessionException(SessionError.unknownDevice);
      }
      _activate(session, initialScopes: pairedDevice.authorizationScopes);
    } on SessionException catch (error) {
      _setState(_stateForError(error.error));
      try {
        await wire.writeMessage({'type': 'error', 'code': error.error.name});
      } on Object {
        // Connection may already be gone.
      }
      await wire.close();
    } on Object {
      _setState(SessionState.authenticationFailed);
      await wire.close();
    }
  }

  @override
  Future<SessionInfo> connect(PairedDevice host) async {
    if (_state == SessionState.connected ||
        _state == SessionState.connecting ||
        _state == SessionState.authenticating) {
      throw StateError('A RemoteX session is already active or connecting.');
    }
    _lastHost = host;
    _cancelRequested = false;
    _intentionalDisconnect = false;
    try {
      final session = await _openAuthenticatedSession(host);
      _activate(session, initialScopes: host.authorizationScopes);
      return SessionInfo(
        sessionId: session.sessionId,
        deviceId: session.peerId,
        deviceName: session.peerName,
        state: SessionState.connected,
        establishedAt: _clock().toUtc(),
      );
    } on SessionException catch (error) {
      _setState(_stateForError(error.error));
      rethrow;
    } on Object {
      _setState(SessionState.authenticationFailed);
      rethrow;
    }
  }

  Future<AuthenticatedSession> _openAuthenticatedSession(
    PairedDevice host,
  ) async {
    _setState(SessionState.connecting);
    final wire = await _transport.connect(host);
    if (_cancelRequested) {
      await wire.close();
      throw const SessionException(SessionError.cancelled);
    }
    _setState(SessionState.authenticating);
    try {
      final session = await _authenticator.authenticateClient(wire, host);
      if (wire is JsonSocketSessionWire) wire.allowAuthenticatedFrames();
      return session;
    } on SessionException {
      await wire.close();
      rethrow;
    } on Object {
      await wire.close();
      rethrow;
    }
  }

  void _activate(
    AuthenticatedSession session, {
    Set<AuthorizationScope> initialScopes = const {AuthorizationScope.session},
  }) {
    final authorization = SessionAuthorization(initialScopes: initialScopes);
    final packets = SessionPacketMultiplexer(session.secureChannel);
    final active = _ActiveSession(
      session,
      packets,
      SessionMessageProtocol(packets: packets, authorization: authorization),
      BinarySecureFrameTransport(
        packets: packets,
        authorization: authorization,
      ),
    );
    _activeSessions[session.sessionId] = active;
    _setState(SessionState.connected);
    developer.log(
      'Session authenticated: device=${session.peerId}, session=${session.sessionId}',
      name: 'remotex.session',
    );
    unawaited(_monitor(active));
    unawaited(_monitorFrames(active));
  }

  Future<void> _monitorFrames(_ActiveSession active) async {
    try {
      while (!active.closed) {
        final frame = await active.frameTransport.receiveFrame();
        if (!_frameController.isClosed) {
          _frameController.add(
            ReceivedScreenFrame(
              sessionId: active.session.sessionId,
              frame: frame,
            ),
          );
        }
      }
    } on ProtocolException {
      if (!active.closed) _setState(SessionState.authenticationFailed);
      await _closeActive(active);
    } on FrameTransportException {
      if (!active.closed) _setState(SessionState.authenticationFailed);
      await _closeActive(active);
    } on SessionException catch (error) {
      if (!active.closed &&
          error.error != SessionError.networkDisconnected &&
          !_intentionalDisconnect) {
        _setState(_stateForError(error.error));
      }
    } on Object {
      if (!active.closed && !_intentionalDisconnect) {
        _setState(SessionState.networkDisconnected);
      }
    }
  }

  Future<void> _monitor(_ActiveSession active) async {
    try {
      while (!active.closed) {
        final message = await active.messageProtocol.receiveMessage();
        if (!_messageController.isClosed) {
          _messageController.add(
            ReceivedSessionMessage(
              sessionId: active.session.sessionId,
              envelope: message,
            ),
          );
        }
      }
    } on ProtocolException {
      _setState(SessionState.authenticationFailed);
    } on SessionException catch (error) {
      if (error.error != SessionError.networkDisconnected) {
        _setState(_stateForError(error.error));
      } else if (!_intentionalDisconnect) {
        _setState(SessionState.networkDisconnected);
      }
    } on Object {
      if (!_intentionalDisconnect) _setState(SessionState.networkDisconnected);
    } finally {
      await _closeActive(active);
      if (active.session.isController &&
          !_intentionalDisconnect &&
          !_cancelRequested) {
        unawaited(_reconnect());
      } else if (_activeSessions.isEmpty &&
          !_intentionalDisconnect &&
          _state != SessionState.revoked) {
        _setState(SessionState.disconnected);
      }
    }
  }

  Future<void> _reconnect() async {
    final host = _lastHost;
    if (_isReconnecting ||
        _intentionalDisconnect ||
        _cancelRequested ||
        host == null) {
      return;
    }
    _isReconnecting = true;
    _setState(SessionState.reconnecting);
    const delays = [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ];
    try {
      for (final delay in delays) {
        if (_intentionalDisconnect || _cancelRequested) return;
        await Future<void>.delayed(delay);
        if (_intentionalDisconnect || _cancelRequested) return;
        try {
          final session = await _openAuthenticatedSession(host);
          if (_intentionalDisconnect || _cancelRequested) {
            await session.secureChannel.close();
            return;
          }
          _activate(session);
          return;
        } on SessionException catch (error) {
          _setState(_stateForError(error.error));
          if (error.error == SessionError.revoked ||
              error.error == SessionError.unknownDevice) {
            return;
          }
        } on Object {
          _setState(SessionState.networkDisconnected);
        }
      }
      if (!_intentionalDisconnect) _setState(SessionState.disconnected);
    } finally {
      _isReconnecting = false;
    }
  }

  @override
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _cancelRequested = true;
    _setState(SessionState.disconnecting);
    final sessions = List<_ActiveSession>.from(_activeSessions.values);
    for (final active in sessions) {
      await _closeActive(active);
    }
    _setState(SessionState.disconnected);
  }

  @override
  Future<void> sendMessage(
    String sessionId,
    MessageType type, {
    Map<String, Object?> payload = const {},
  }) async {
    final active = _activeSessions[sessionId];
    if (active == null) throw StateError('Session is not connected.');
    await active.messageProtocol.sendMessage(type, payload: payload);
  }

  @override
  Future<MessageEnvelope> request(
    String sessionId,
    MessageType type, {
    Map<String, Object?> payload = const {},
    Duration timeout = SessionMessageProtocol.requestTimeout,
  }) async {
    final active = _activeSessions[sessionId];
    if (active == null) throw StateError('Session is not connected.');
    return active.messageProtocol.request(
      type,
      payload: payload,
      timeout: timeout,
    );
  }

  @override
  Future<void> respond(
    String sessionId,
    MessageEnvelope request, {
    required MessageType type,
    Map<String, Object?> payload = const {},
  }) async {
    final active = _activeSessions[sessionId];
    if (active == null) throw StateError('Session is not connected.');
    await active.messageProtocol.respond(request, type: type, payload: payload);
  }

  @override
  Future<void> sendFrame(String sessionId, ScreenFrame frame) async {
    final active = _activeSessions[sessionId];
    if (active == null) throw StateError('Session is not connected.');
    await active.frameTransport.sendFrame(frame);
  }

  @override
  Future<void> grantSessionScope(
    String sessionId,
    AuthorizationScope scope,
  ) async {
    final active = _activeSessions[sessionId];
    if (active == null) throw StateError('Session is not connected.');
    active.messageProtocol.authorization.grant(scope);
  }

  @override
  Future<void> revokeSessionScope(
    String sessionId,
    AuthorizationScope scope,
  ) async {
    final active = _activeSessions[sessionId];
    if (active == null) return;
    active.messageProtocol.authorization.revoke(scope);
  }

  @override
  bool isSessionActive(String sessionId) =>
      _activeSessions.containsKey(sessionId);

  @override
  String? peerIdForSession(String sessionId) =>
      _activeSessions[sessionId]?.session.peerId;

  @override
  Future<void> setDeviceScope(
    String deviceId,
    AuthorizationScope scope, {
    required bool enabled,
  }) async {
    await _pairedDevicesService.setScope(deviceId, scope, enabled: enabled);
    if (!_authorizationChangeController.isClosed) {
      _authorizationChangeController.add(
        AuthorizationChange(deviceId: deviceId, scope: scope, enabled: enabled),
      );
    }
    for (final active in _activeSessions.values.where(
      (session) =>
          !session.session.isController && session.session.peerId == deviceId,
    )) {
      if (enabled) {
        active.messageProtocol.authorization.grant(scope);
      } else {
        active.messageProtocol.authorization.revoke(scope);
      }
      if (scope == AuthorizationScope.mouseControl ||
          scope == AuthorizationScope.keyboardControl) {
        final trusted = (await _pairedDevicesService.getPairedDevices())
            .where((device) => device.id == deviceId)
            .firstOrNull;
        if (trusted != null) {
          await active.messageProtocol.sendMessage(
            MessageType.authorizationUpdate,
            payload: {
              'mouseControl': trusted.hasScope(AuthorizationScope.mouseControl),
              'keyboardControl': trusted.hasScope(
                AuthorizationScope.keyboardControl,
              ),
            },
          );
        }
      }
    }
  }

  @override
  Future<List<PairedDevice>> getTrustedDevices() =>
      _pairedDevicesService.getPairedDevices();

  @override
  Future<void> revokeDevice(String deviceId) async {
    final wasConnected = _activeSessions.values.any(
      (active) =>
          !active.session.isController && active.session.peerId == deviceId,
    );
    await _pairedDevicesService.revokePairedDevice(deviceId);
    for (final active in List<_ActiveSession>.from(_activeSessions.values)) {
      if (!active.session.isController && active.session.peerId == deviceId) {
        await _closeActive(active);
      }
    }
    if (wasConnected) _setState(SessionState.revoked);
  }

  @override
  Future<void> stopHost() async {
    await _hostSubscription?.cancel();
    _hostSubscription = null;
    for (final active in List<_ActiveSession>.from(_activeSessions.values)) {
      await _closeActive(active);
    }
    await _transport.stopHost();
    if (_state != SessionState.revoked) _setState(SessionState.disconnected);
  }

  Future<void> _closeActive(_ActiveSession active) async {
    if (active.closed) return;
    active.closed = true;
    _activeSessions.remove(active.session.sessionId);
    if (!_closedSessionController.isClosed) {
      _closedSessionController.add(active.session.sessionId);
    }
    await active.messageProtocol.close();
    await active.packets.close();
    await active.session.secureChannel.close();
  }

  void _setState(SessionState state) {
    _state = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }

  static SessionState _stateForError(SessionError error) => switch (error) {
    SessionError.revoked => SessionState.revoked,
    SessionError.unknownDevice => SessionState.unknownDevice,
    SessionError.networkDisconnected => SessionState.networkDisconnected,
    SessionError.hostUnavailable => SessionState.networkDisconnected,
    _ => SessionState.authenticationFailed,
  };
}

class _ActiveSession {
  _ActiveSession(
    this.session,
    this.packets,
    this.messageProtocol,
    this.frameTransport,
  );

  final AuthenticatedSession session;
  final SessionPacketMultiplexer packets;
  final SessionMessageProtocol messageProtocol;
  final SecureFrameTransport frameTransport;
  bool closed = false;
}
