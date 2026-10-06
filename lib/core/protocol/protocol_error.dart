enum ProtocolError {
  malformedMessage,
  unsupportedVersion,
  unknownMessageType,
  invalidMessageId,
  invalidSequence,
  replayedMessage,
  invalidTimestamp,
  invalidPayload,
  payloadTooLarge,
  unauthorized,
  invalidCorrelation,
  tooManyPendingRequests,
  requestTimedOut,
  closed,
}

class ProtocolException implements Exception {
  const ProtocolException(this.error);

  final ProtocolError error;
}
