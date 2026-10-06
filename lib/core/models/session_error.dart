enum SessionError {
  hostUnavailable,
  authenticationFailed,
  unknownDevice,
  revoked,
  replayedHandshake,
  expiredChallenge,
  protocolMismatch,
  malformedMessage,
  networkDisconnected,
  cancelled,
}

class SessionException implements Exception {
  const SessionException(this.error);

  final SessionError error;

  String get userMessage => switch (error) {
    SessionError.hostUnavailable =>
      'The paired laptop is unavailable on this local network.',
    SessionError.authenticationFailed =>
      'The device identity could not be authenticated.',
    SessionError.unknownDevice =>
      'This device is not trusted by the Windows host.',
    SessionError.revoked => 'This device has been revoked on the Windows host.',
    SessionError.replayedHandshake =>
      'The session request was rejected as a replay.',
    SessionError.expiredChallenge =>
      'The authentication request expired. Try connecting again.',
    SessionError.protocolMismatch =>
      'The devices use incompatible session protocols.',
    SessionError.malformedMessage => 'The session request was malformed.',
    SessionError.networkDisconnected =>
      'The secure session was interrupted by a network change.',
    SessionError.cancelled => 'The connection attempt was cancelled.',
  };
}
