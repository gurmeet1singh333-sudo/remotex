import 'dart:async';

import 'package:remotex/core/models/authorization_change.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/models/session_info.dart';
import 'package:remotex/core/models/session_state.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/protocol/message_envelope.dart';
import 'package:remotex/core/protocol/message_type.dart';
import 'package:remotex/core/protocol/protocol_version.dart';
import 'package:remotex/core/protocol/received_session_message.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/session_service.dart';

MessageEnvelope createTestEnvelope({
  required MessageType type,
  Map<String, Object?> payload = const {},
  String? requestId,
}) {
  return MessageEnvelope(
    protocolVersion: ProtocolVersion.current,
    type: type,
    messageId: 'msg_1',
    sequence: 1,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    payloadLength: payload.length,
    payload: payload,
    requestId: requestId,
  );
}

class MockSessionService implements SessionService {
  final activeSessions = <String, String>{};
  final incomingMessagesController =
      StreamController<ReceivedSessionMessage>.broadcast();
  final incomingFramesController =
      StreamController<ReceivedScreenFrame>.broadcast();
  final closedSessionsController = StreamController<String>.broadcast();
  final authorizationChangesController =
      StreamController<AuthorizationChange>.broadcast();

  @override
  SessionState get state => SessionState.connected;

  @override
  String? get controllerSessionId => null;

  @override
  Stream<SessionState> get stateChanges => const Stream.empty();

  @override
  Stream<ReceivedSessionMessage> get incomingMessages =>
      incomingMessagesController.stream;

  @override
  Stream<ReceivedScreenFrame> get incomingFrames =>
      incomingFramesController.stream;

  @override
  Stream<String> get closedSessions => closedSessionsController.stream;

  @override
  Stream<AuthorizationChange> get authorizationChanges =>
      authorizationChangesController.stream;

  @override
  Future<void> startHost() async {}

  @override
  Future<SessionInfo> connect(PairedDevice host) async {
    return SessionInfo(
      sessionId: 'test_session',
      deviceId: host.id,
      deviceName: host.name,
      state: SessionState.connected,
      establishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> sendMessage(
    String sessionId,
    MessageType type, {
    Map<String, Object?> payload = const {},
  }) async {}

  @override
  Future<MessageEnvelope> request(
    String sessionId,
    MessageType type, {
    Map<String, Object?> payload = const {},
    Duration timeout = const Duration(seconds: 5),
  }) async {
    return createTestEnvelope(
      type: MessageType.sessionReady,
      payload: const {'width': 1280, 'height': 720},
    );
  }

  @override
  Future<void> respond(
    String sessionId,
    MessageEnvelope request, {
    required MessageType type,
    Map<String, Object?> payload = const {},
  }) async {}

  @override
  Future<void> sendFrame(String sessionId, ScreenFrame frame) async {}

  @override
  Future<void> grantSessionScope(
    String sessionId,
    AuthorizationScope scope,
  ) async {}

  @override
  Future<void> revokeSessionScope(
    String sessionId,
    AuthorizationScope scope,
  ) async {}

  @override
  bool isSessionActive(String sessionId) => activeSessions.containsKey(sessionId);

  @override
  String? peerIdForSession(String sessionId) => activeSessions[sessionId];

  @override
  Future<void> setDeviceScope(
    String deviceId,
    AuthorizationScope scope, {
    required bool enabled,
  }) async {}

  @override
  Future<List<PairedDevice>> getTrustedDevices() async => const [];

  @override
  Future<void> revokeDevice(String deviceId) async {}

  @override
  Future<void> stopHost() async {}
}

class MockPairedDevicesService implements PairedDevicesService {
  final devices = <String, PairedDevice>{};

  @override
  Future<void> addPairedDevice(PairedDevice device) async {
    devices[device.id] = device;
  }

  @override
  Future<bool> contains(String deviceId) async => devices.containsKey(deviceId);

  @override
  Future<List<PairedDevice>> getPairedDevices() async =>
      List.unmodifiable(devices.values);

  @override
  Future<bool> isRevoked(String deviceId) async => false;

  @override
  Future<void> removePairedDevice(String deviceId) async {
    devices.remove(deviceId);
  }

  @override
  Future<void> revokePairedDevice(String deviceId) async {
    devices.remove(deviceId);
  }

  @override
  Future<void> setScope(
    String deviceId,
    AuthorizationScope scope, {
    required bool enabled,
  }) async {}
}
