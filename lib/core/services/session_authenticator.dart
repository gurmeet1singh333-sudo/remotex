import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/secure_session_channel.dart';
import 'package:remotex/core/services/session_transport.dart';

abstract interface class SessionAuthenticator {
  Future<AuthenticatedSession> authenticateClient(
    SessionWire wire,
    PairedDevice trustedHost,
  );

  Future<AuthenticatedSession> authenticateHost(
    SessionWire wire,
    PairedDevicesService trustedDevices,
    String hostId,
  );
}

class AuthenticatedSession {
  const AuthenticatedSession({
    required this.sessionId,
    required this.peerId,
    required this.peerName,
    required this.isController,
    required this.wire,
    required this.secureChannel,
  });

  final String sessionId;
  final String peerId;
  final String peerName;
  final bool isController;
  final SessionWire wire;
  final SecureSessionChannel secureChannel;
}
