import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/pairing_qr_payload.dart';

abstract interface class PairingService {
  Future<PairedDevice> pair(PairingQrPayload payload);

  Future<void> cancelPairing();
}

abstract interface class HostPairingService {
  Stream<HostPairingStatus> get statusChanges;

  HostPairingStatus? get status;

  Future<void> start();

  Future<void> startPairingSession();

  Future<void> cancelPairingSession();

  Future<void> stop();
}

class HostPairingStatus {
  const HostPairingStatus({
    required this.hostName,
    required this.hostId,
    required this.hostPublicKey,
    required this.port,
    required this.addresses,
    required this.isRunning,
    this.pairingNonce,
    this.expiresAt,
    this.pairedDeviceCount = 0,
    this.errorMessage,
    this.isPairingLocked = false,
  });

  final String hostName;
  final String hostId;
  final String hostPublicKey;
  final int port;
  final List<String> addresses;
  final String? pairingNonce;
  final DateTime? expiresAt;
  final bool isRunning;
  final int pairedDeviceCount;
  final String? errorMessage;
  final bool isPairingLocked;

  HostPairingStatus copyWith({
    String? pairingNonce,
    DateTime? expiresAt,
    int? pairedDeviceCount,
    String? errorMessage,
    bool? isRunning,
    bool clearPairingSession = false,
    bool? isPairingLocked,
  }) => HostPairingStatus(
    hostName: hostName,
    hostId: hostId,
    hostPublicKey: hostPublicKey,
    port: port,
    addresses: addresses,
    pairingNonce: clearPairingSession
        ? null
        : pairingNonce ?? this.pairingNonce,
    expiresAt: clearPairingSession ? null : expiresAt ?? this.expiresAt,
    isRunning: isRunning ?? this.isRunning,
    pairedDeviceCount: pairedDeviceCount ?? this.pairedDeviceCount,
    errorMessage: errorMessage,
    isPairingLocked: clearPairingSession
        ? isPairingLocked ?? false
        : isPairingLocked ?? this.isPairingLocked,
  );
}
