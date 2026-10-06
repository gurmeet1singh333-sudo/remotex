import 'message_type.dart';
import 'protocol_version.dart';

class MessageEnvelope {
  const MessageEnvelope({
    this.protocolVersion = ProtocolVersion.current,
    required this.type,
    required this.messageId,
    required this.sequence,
    required this.timestamp,
    required this.payloadLength,
    required this.payload,
    this.requestId,
  });

  final int protocolVersion;
  final MessageType type;
  final String messageId;
  final int sequence;
  final int timestamp;
  final int payloadLength;
  final Map<String, Object?> payload;
  final String? requestId;

  Map<String, Object?> toJson() => {
    'version': protocolVersion,
    'type': type.wireName,
    'messageId': messageId,
    'sequence': sequence,
    'timestamp': timestamp,
    'payloadLength': payloadLength,
    'payload': payload,
    if (requestId != null) 'requestId': requestId,
  };
}
