import 'package:remotex/core/models/session_state.dart';

class SessionInfo {
  const SessionInfo({
    required this.sessionId,
    required this.deviceId,
    required this.deviceName,
    required this.state,
    required this.establishedAt,
  });

  final String sessionId;
  final String deviceId;
  final String deviceName;
  final SessionState state;
  final DateTime establishedAt;
}
