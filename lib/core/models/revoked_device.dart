class RevokedDevice {
  const RevokedDevice({
    required this.deviceId,
    required this.deviceName,
    required this.revokedAt,
  });

  final String deviceId;
  final String deviceName;
  final DateTime revokedAt;
}
