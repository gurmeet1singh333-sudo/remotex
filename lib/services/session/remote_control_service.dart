import 'dart:async';
import 'dart:developer' as developer;

import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/authorization_change.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/protocol/message_type.dart';
import 'package:remotex/core/protocol/received_session_message.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/remote_input_service.dart';
import 'package:remotex/core/services/session_service.dart';

class RemoteControlService {
  RemoteControlService({
    required SessionService sessionService,
    required PairedDevicesService pairedDevicesService,
    required RemoteInputService inputService,
  }) : _sessions = sessionService,
       _pairedDevices = pairedDevicesService,
       _input = inputService {
    _messageSubscription = _sessions.incomingMessages.listen(
      (message) => _enqueue(() => _handleMessage(message)),
    );
    _closedSubscription = _sessions.closedSessions.listen(
      (sessionId) => _enqueue(() => _handleClosed(sessionId)),
    );
    _authorizationSubscription = _sessions.authorizationChanges.listen(
      (change) => _enqueue(() => _handleAuthorizationChange(change)),
    );
  }

  final SessionService _sessions;
  final PairedDevicesService _pairedDevices;
  final RemoteInputService _input;
  final Map<String, Set<AuthorizationScope>> _controllerScopes = {};
  final Map<String, Set<String>> _pressedKeys = {};
  final Map<String, Set<String>> _pressedButtons = {};
  final _updates = StreamController<String>.broadcast();
  StreamSubscription<ReceivedSessionMessage>? _messageSubscription;
  StreamSubscription<String>? _closedSubscription;
  StreamSubscription<AuthorizationChange>? _authorizationSubscription;
  Future<void> _messageQueue = Future<void>.value();

  bool canControlMouse(String sessionId) =>
      _controllerScopes[sessionId]?.contains(AuthorizationScope.mouseControl) ??
      false;

  bool canControlKeyboard(String sessionId) =>
      _controllerScopes[sessionId]?.contains(
        AuthorizationScope.keyboardControl,
      ) ??
      false;

  Stream<String> get updates => _updates.stream;

  void _enqueue(Future<void> Function() operation) {
    _messageQueue = _messageQueue.then((_) => operation()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      developer.log(
        'Remote control message rejected.',
        name: 'remotex.remote_control',
        error: error.runtimeType,
      );
    });
  }

  Future<void> sendMouseMove(
    String sessionId, {
    required double x,
    required double y,
  }) => _send(
    sessionId,
    AuthorizationScope.mouseControl,
    MessageType.mouseMove,
    {'x': x, 'y': y},
  );

  Future<void> sendMouseButton(
    String sessionId, {
    required String button,
    required String action,
  }) => _send(
    sessionId,
    AuthorizationScope.mouseControl,
    MessageType.mouseButton,
    {'button': button, 'action': action},
  );

  Future<void> sendMouseScroll(
    String sessionId, {
    required int deltaX,
    required int deltaY,
  }) => _send(
    sessionId,
    AuthorizationScope.mouseControl,
    MessageType.mouseScroll,
    {'deltaX': deltaX, 'deltaY': deltaY},
  );

  Future<void> sendKeyboardKey(
    String sessionId, {
    required String key,
    required String action,
  }) => _send(
    sessionId,
    AuthorizationScope.keyboardControl,
    MessageType.keyboardKey,
    {'key': key, 'action': action},
  );

  Future<void> _send(
    String sessionId,
    AuthorizationScope scope,
    MessageType type,
    Map<String, Object?> payload,
  ) async {
    final authorized = scope == AuthorizationScope.mouseControl
        ? canControlMouse(sessionId)
        : canControlKeyboard(sessionId);
    if (!authorized) throw StateError('Remote control is not authorized.');
    await _sessions.sendMessage(sessionId, type, payload: payload);
  }

  Future<void> _handleMessage(ReceivedSessionMessage received) async {
    final message = received.envelope;
    if (message.type == MessageType.sessionReady) {
      _applyControllerScopes(received.sessionId, message.payload);
      return;
    }
    if (message.type == MessageType.authorizationUpdate) {
      _applyControllerScopes(received.sessionId, message.payload);
      return;
    }
    if (!_isInputMessage(message.type)) return;

    final sessionId = received.sessionId;
    if (!_sessions.isSessionActive(sessionId)) return;
    final deviceId = _sessions.peerIdForSession(sessionId);
    if (deviceId == null || await _pairedDevices.isRevoked(deviceId)) {
      return;
    }
    final device = (await _pairedDevices.getPairedDevices())
        .where((paired) => paired.id == deviceId)
        .firstOrNull;
    if (device == null) return;
    final requiredScope = message.type.requiredScope;
    if (!device.hasScope(requiredScope)) return;

    final payload = message.payload;
    switch (message.type) {
      case MessageType.mouseMove:
        await _input.movePointer(
          (payload['x']! as num).toDouble(),
          (payload['y']! as num).toDouble(),
        );
        break;
      case MessageType.mouseButton:
        final button = payload['button']! as String;
        final action = payload['action']! as String;
        await _input.mouseButton(button, action);
        final pressed = _pressedButtons.putIfAbsent(sessionId, () => {});
        if (action == 'down') pressed.add(button);
        if (action == 'up') pressed.remove(button);
        break;
      case MessageType.mouseScroll:
        await _input.scroll(
          payload['deltaX']! as int,
          payload['deltaY']! as int,
        );
        break;
      case MessageType.keyboardKey:
        final key = payload['key']! as String;
        final action = payload['action']! as String;
        await _input.keyboardKey(key, action);
        final pressed = _pressedKeys.putIfAbsent(sessionId, () => {});
        if (action == 'down') pressed.add(key);
        if (action == 'up') pressed.remove(key);
        break;
      default:
        return;
    }
  }

  void _applyControllerScopes(String sessionId, Map<String, Object?> payload) {
    final mouse = payload['mouseControl'];
    final keyboard = payload['keyboardControl'];
    if (mouse is! bool || keyboard is! bool) return;
    final scopes = _controllerScopes.putIfAbsent(
      sessionId,
      () => {AuthorizationScope.screenView},
    );
    _setScope(sessionId, scopes, AuthorizationScope.mouseControl, mouse);
    _setScope(sessionId, scopes, AuthorizationScope.keyboardControl, keyboard);
    if (!_updates.isClosed) _updates.add(sessionId);
  }

  void _setScope(
    String sessionId,
    Set<AuthorizationScope> scopes,
    AuthorizationScope scope,
    bool enabled,
  ) {
    if (enabled) {
      scopes.add(scope);
      unawaited(_sessions.grantSessionScope(sessionId, scope));
    } else {
      scopes.remove(scope);
      unawaited(_sessions.revokeSessionScope(sessionId, scope));
    }
  }

  static bool _isInputMessage(MessageType type) => const {
    MessageType.mouseMove,
    MessageType.mouseButton,
    MessageType.mouseScroll,
    MessageType.keyboardKey,
  }.contains(type);

  Future<void> _handleClosed(String sessionId) async {
    _controllerScopes.remove(sessionId);
    if (!_updates.isClosed) _updates.add(sessionId);
    for (final button
        in _pressedButtons.remove(sessionId) ?? const <String>{}) {
      await _input.mouseButton(button, 'up');
    }
    for (final key in _pressedKeys.remove(sessionId) ?? const <String>{}) {
      await _input.keyboardKey(key, 'up');
    }
  }

  Future<void> _handleAuthorizationChange(AuthorizationChange change) async {
    if (change.enabled ||
        (change.scope != AuthorizationScope.mouseControl &&
            change.scope != AuthorizationScope.keyboardControl)) {
      return;
    }
    final activeInputSessions = {..._pressedButtons.keys, ..._pressedKeys.keys}
        .where(
          (sessionId) =>
              _sessions.peerIdForSession(sessionId) == change.deviceId,
        );
    for (final sessionId in activeInputSessions) {
      if (change.scope == AuthorizationScope.mouseControl) {
        for (final button
            in _pressedButtons.remove(sessionId) ?? const <String>{}) {
          await _input.mouseButton(button, 'up');
        }
      } else {
        for (final key in _pressedKeys.remove(sessionId) ?? const <String>{}) {
          await _input.keyboardKey(key, 'up');
        }
      }
    }
  }

  Future<void> dispose() async {
    await _messageSubscription?.cancel();
    await _closedSubscription?.cancel();
    await _authorizationSubscription?.cancel();
    await _messageQueue;
    await _input.releaseAll();
    await _updates.close();
  }
}

extension on Iterable<PairedDevice> {
  PairedDevice? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
