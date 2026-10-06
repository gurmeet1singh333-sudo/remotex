import 'dart:convert';

import 'authorization_scope.dart';
import 'message_envelope.dart';
import 'message_validator.dart';
import 'protocol_error.dart';
import 'session_authorization.dart';

class SessionMessageCodec {
  SessionMessageCodec({
    MessageValidator? validator,
    SessionAuthorization? authorization,
    Set<AuthorizationScope> grantedScopes = const {AuthorizationScope.session},
  }) : _validator = validator ?? MessageValidator(),
       _authorization =
           authorization ?? SessionAuthorization(initialScopes: grantedScopes);

  final MessageValidator _validator;
  SessionAuthorization _authorization;

  Set<AuthorizationScope> get grantedScopes => _authorization.scopes;

  void bindAuthorization(SessionAuthorization authorization) {
    _authorization = authorization;
  }

  List<int> encode(MessageEnvelope envelope) {
    final message = envelope.toJson();
    _validator.validate(
      json: message,
      expectedSequence: envelope.sequence,
      scopes: _authorization.scopes,
    );
    final encoded = utf8.encode(jsonEncode(message));
    if (encoded.length > MessageValidator.maximumEncodedMessageBytes) {
      throw const ProtocolException(ProtocolError.payloadTooLarge);
    }
    return encoded;
  }

  MessageEnvelope decode({
    required List<int> bytes,
    required int expectedSequence,
  }) {
    if (bytes.length > MessageValidator.maximumEncodedMessageBytes) {
      throw const ProtocolException(ProtocolError.payloadTooLarge);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      throw const ProtocolException(ProtocolError.malformedMessage);
    }
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const ProtocolException(ProtocolError.malformedMessage);
    }
    return _validator.validate(
      json: Map<String, Object?>.from(decoded),
      expectedSequence: expectedSequence,
      scopes: _authorization.scopes,
    );
  }
}
