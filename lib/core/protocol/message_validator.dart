import 'dart:convert';

import 'authorization_scope.dart';
import 'disconnect_reason.dart';
import 'message_envelope.dart';
import 'message_type.dart';
import 'protocol_error.dart';
import 'protocol_version.dart';

class MessageValidator {
  MessageValidator({
    DateTime Function()? clock,
    this.maximumClockSkew = const Duration(minutes: 5),
  }) : _clock = clock ?? DateTime.now;

  static const maximumEncodedMessageBytes = 8192;
  static const maximumPendingRequests = 32;
  static const maximumSeenMessageIds = 1024;
  static final _messageIdPattern = RegExp(r'^[a-f0-9]{32}$');

  final DateTime Function() _clock;
  final Duration maximumClockSkew;

  MessageEnvelope validate({
    required Map<String, Object?> json,
    required int expectedSequence,
    required Set<AuthorizationScope> scopes,
  }) {
    if (json.keys.toSet().difference({
      'version',
      'type',
      'messageId',
      'sequence',
      'timestamp',
      'payloadLength',
      'payload',
      'requestId',
    }).isNotEmpty) {
      throw const ProtocolException(ProtocolError.malformedMessage);
    }
    final version = json['version'];
    if (version != ProtocolVersion.current) {
      throw const ProtocolException(ProtocolError.unsupportedVersion);
    }
    final type = MessageType.fromWireName(json['type']);
    if (type == null) {
      throw const ProtocolException(ProtocolError.unknownMessageType);
    }
    if (!scopes.contains(type.requiredScope)) {
      throw const ProtocolException(ProtocolError.unauthorized);
    }

    final messageId = json['messageId'];
    final requestId = json['requestId'];
    if (messageId is! String || !_messageIdPattern.hasMatch(messageId)) {
      throw const ProtocolException(ProtocolError.invalidMessageId);
    }
    if (type.isResponse) {
      if (requestId is! String || !_messageIdPattern.hasMatch(requestId)) {
        throw const ProtocolException(ProtocolError.invalidCorrelation);
      }
    } else if (requestId != null) {
      throw const ProtocolException(ProtocolError.invalidCorrelation);
    }

    final sequence = json['sequence'];
    if (sequence is! int || sequence < 0 || sequence != expectedSequence) {
      throw const ProtocolException(ProtocolError.invalidSequence);
    }
    final timestamp = json['timestamp'];
    if (timestamp is! int || timestamp <= 0 || !_isFresh(timestamp)) {
      throw const ProtocolException(ProtocolError.invalidTimestamp);
    }

    final payload = json['payload'];
    if (payload is! Map || payload.keys.any((key) => key is! String)) {
      throw const ProtocolException(ProtocolError.invalidPayload);
    }
    final typedPayload = Map<String, Object?>.from(payload);
    if (!_isValidJsonValue(typedPayload, 0)) {
      throw const ProtocolException(ProtocolError.invalidPayload);
    }
    final payloadBytes = utf8.encode(jsonEncode(typedPayload)).length;
    final declaredLength = json['payloadLength'];
    if (payloadBytes > type.maximumPayloadBytes ||
        payloadBytes > maximumEncodedMessageBytes) {
      throw const ProtocolException(ProtocolError.payloadTooLarge);
    }
    if (declaredLength is! int || declaredLength != payloadBytes) {
      throw const ProtocolException(ProtocolError.invalidPayload);
    }
    if (!_isValidPayloadForType(type, typedPayload)) {
      throw const ProtocolException(ProtocolError.invalidPayload);
    }

    return MessageEnvelope(
      protocolVersion: ProtocolVersion.current,
      type: type,
      messageId: messageId,
      requestId: requestId as String?,
      sequence: sequence,
      timestamp: timestamp,
      payloadLength: declaredLength,
      payload: typedPayload,
    );
  }

  bool _isFresh(int timestamp) {
    final now = _clock().toUtc().millisecondsSinceEpoch;
    return (now - timestamp).abs() <= maximumClockSkew.inMilliseconds;
  }

  bool _isValidPayloadForType(MessageType type, Map<String, Object?> payload) =>
      switch (type) {
        MessageType.hello =>
          payload['deviceId'] is String &&
              (payload['deviceId']! as String).isNotEmpty &&
              (payload['deviceId']! as String).length <= 128,
        MessageType.disconnect =>
          DisconnectReason.fromWireName(payload['reason']) != null,
        MessageType.sessionError =>
          payload['code'] is String &&
              (payload['code']! as String).isNotEmpty &&
              (payload['code']! as String).length <= 64,
        MessageType.mouseMove =>
          _isNormalizedCoordinate(payload['x']) &&
              _isNormalizedCoordinate(payload['y']) &&
              payload.length == 2,
        MessageType.mouseButton =>
          const {'left', 'right', 'middle'}.contains(payload['button']) &&
              const {
                'down',
                'up',
                'click',
                'double_click',
              }.contains(payload['action']) &&
              payload.length == 2,
        MessageType.mouseScroll =>
          _isScrollDelta(payload['deltaX']) &&
              _isScrollDelta(payload['deltaY']) &&
              (payload['deltaX'] != 0 || payload['deltaY'] != 0) &&
              payload.length == 2,
        MessageType.cursorPosition =>
          payload['x'] is int &&
              payload['y'] is int &&
              payload['width'] is int &&
              payload['height'] is int &&
              (payload['width']! as int) > 0 &&
              (payload['height']! as int) > 0 &&
              (payload['width']! as int) <= 16384 &&
              (payload['height']! as int) <= 16384 &&
              (payload['x']! as int) >= 0 &&
              (payload['x']! as int) < (payload['width']! as int) &&
              (payload['y']! as int) >= 0 &&
              (payload['y']! as int) < (payload['height']! as int) &&
              payload['visible'] is bool &&
              payload.length == 5,
        MessageType.keyboardKey =>
          _isValidKey(payload['key']) &&
              const {'down', 'up', 'press'}.contains(payload['action']) &&
              payload.length == 2,
        MessageType.authorizationUpdate =>
          payload['mouseControl'] is bool &&
              payload['keyboardControl'] is bool &&
              payload.length == 2,
        MessageType.sessionReady =>
          payload['stopped'] == true && payload.length == 1 ||
              payload['width'] is int &&
                  payload['height'] is int &&
                  payload['mouseControl'] is bool &&
                  payload['keyboardControl'] is bool &&
                  payload.length == 4,
        _ => true,
      };

  bool _isNormalizedCoordinate(Object? value) =>
      value is num && value.isFinite && value >= 0 && value <= 1;

  bool _isScrollDelta(Object? value) => value is int && value.abs() <= 2000;

  bool _isValidKey(Object? value) {
    if (value is! String || value.isEmpty || value.length > 16) return false;
    if (value.length == 1) {
      final code = value.codeUnitAt(0);
      return code >= 0x20 && code <= 0x7e;
    }
    return const {
      'Space',
      'Enter',
      'Backspace',
      'Tab',
      'Escape',
      'ArrowUp',
      'ArrowDown',
      'ArrowLeft',
      'ArrowRight',
      'Shift',
      'Control',
      'Alt',
      'Meta',
    }.contains(value);
  }

  bool _isValidJsonValue(Object? value, int depth) {
    if (depth > 16) return false;
    if (value == null || value is String || value is bool || value is int) {
      return value is! String || value.length <= maximumEncodedMessageBytes;
    }
    if (value is double) return value.isFinite;
    if (value is List) {
      return value.length <= maximumEncodedMessageBytes &&
          value.every((item) => _isValidJsonValue(item, depth + 1));
    }
    if (value is Map) {
      return value.length <= maximumEncodedMessageBytes &&
          value.entries.every(
            (entry) =>
                entry.key is String &&
                (entry.key as String).length <= 256 &&
                _isValidJsonValue(entry.value, depth + 1),
          );
    }
    return false;
  }
}
