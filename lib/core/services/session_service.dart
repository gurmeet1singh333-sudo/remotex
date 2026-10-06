import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/authorization_change.dart';
import 'package:remotex/core/models/session_info.dart';
import 'package:remotex/core/models/session_state.dart';
import 'package:remotex/core/protocol/message_envelope.dart';
import 'package:remotex/core/protocol/message_type.dart';
import 'package:remotex/core/protocol/received_session_message.dart';
import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';

abstract interface class SessionService {
  Stream<SessionState> get stateChanges;

  Stream<ReceivedSessionMessage> get incomingMessages;

  Stream<ReceivedScreenFrame> get incomingFrames;

  Stream<String> get closedSessions;

  Stream<AuthorizationChange> get authorizationChanges;

  SessionState get state;

  String? get controllerSessionId;

  Future<void> startHost();

  Future<void> stopHost();

  Future<SessionInfo> connect(PairedDevice host);

  Future<void> sendMessage(
    String sessionId,
    MessageType type, {
    Map<String, Object?> payload = const {},
  });

  Future<MessageEnvelope> request(
    String sessionId,
    MessageType type, {
    Map<String, Object?> payload = const {},
    Duration timeout = const Duration(seconds: 15),
  });

  Future<void> respond(
    String sessionId,
    MessageEnvelope request, {
    required MessageType type,
    Map<String, Object?> payload = const {},
  });

  Future<void> sendFrame(String sessionId, ScreenFrame frame);

  Future<void> grantSessionScope(String sessionId, AuthorizationScope scope);

  Future<void> revokeSessionScope(String sessionId, AuthorizationScope scope);

  bool isSessionActive(String sessionId);

  String? peerIdForSession(String sessionId);

  Future<void> setDeviceScope(
    String deviceId,
    AuthorizationScope scope, {
    required bool enabled,
  });

  Future<void> disconnect();

  Future<List<PairedDevice>> getTrustedDevices();

  Future<void> revokeDevice(String deviceId);
}
