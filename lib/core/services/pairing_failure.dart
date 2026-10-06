enum PairingFailure {
  hostUnavailable,
  invalidBootstrap,
  expiredPairingSession,
  tooManyAttempts,
  incompatibleHost,
  alreadyPaired,
  networkChanged,
  cancelled,
  invalidRequest,
}

class PairingException implements Exception {
  const PairingException(this.failure);

  final PairingFailure failure;

  String get userMessage => switch (failure) {
    PairingFailure.hostUnavailable => 'The laptop is unavailable. Check that both devices are on the same Wi-Fi network.',
    PairingFailure.invalidBootstrap =>
      'The pairing QR session could not be verified.',
    PairingFailure.expiredPairingSession =>
      'The pairing QR expired or was cancelled. Generate a new QR on the laptop.',
    PairingFailure.tooManyAttempts =>
      'Too many pairing attempts. Generate a new QR on the laptop.',
    PairingFailure.incompatibleHost =>
      'This host uses an unsupported RemoteX pairing protocol.',
    PairingFailure.alreadyPaired => 'This device is already paired.',
    PairingFailure.networkChanged =>
      'The network changed during pairing. Retry on the same Wi-Fi network.',
    PairingFailure.cancelled => 'Pairing was cancelled.',
    PairingFailure.invalidRequest =>
      'The pairing request could not be completed.',
  };
}
