import 'message_envelope.dart';

class ReceivedSessionMessage {
  const ReceivedSessionMessage({
    required this.sessionId,
    required this.envelope,
  });

  final String sessionId;
  final MessageEnvelope envelope;
}
