enum DisconnectReason {
  userRequested('user_requested'),
  timeout('timeout'),
  networkError('network_error'),
  authenticationFailed('authentication_failed'),
  revoked('revoked'),
  protocolError('protocol_error'),
  remoteClosed('remote_closed');

  const DisconnectReason(this.wireName);

  final String wireName;

  static DisconnectReason? fromWireName(Object? value) {
    for (final reason in values) {
      if (reason.wireName == value) return reason;
    }
    return null;
  }
}
