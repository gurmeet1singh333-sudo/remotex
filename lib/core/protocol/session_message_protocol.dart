import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'message_envelope.dart';
import 'message_type.dart';
import 'protocol_error.dart';
import 'session_authorization.dart';
import 'session_packet_multiplexer.dart';
import 'session_message_codec.dart';

class SessionMessageProtocol {
  SessionMessageProtocol({
    required this._packets,
    SessionAuthorization? authorization,
    SessionMessageCodec? codec,
    Random? random,
    DateTime Function()? clock,
  }) : authorization = authorization ?? SessionAuthorization(),
       _codec = codec ?? SessionMessageCodec(),
       _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now {
    _codec.bindAuthorization(this.authorization);
  }

  static const maximumPendingRequests = 32;
  static const maximumRecentMessageIds = 1024;
  static const requestTimeout = Duration(seconds: 15);

  final SessionPacketMultiplexer _packets;
  final SessionAuthorization authorization;
  final SessionMessageCodec _codec;
  final Random _random;
  final DateTime Function() _clock;
  final Map<String, Completer<MessageEnvelope>> _pendingRequests = {};
  final Map<String, DateTime> _inboundRequests = {};
  final Set<String> _recentMessageIds = {};
  final List<String> _messageIdOrder = [];
  Future<void> _sendQueue = Future<void>.value();
  int _sendSequence = 0;
  int _receiveSequence = 0;
  bool _closed = false;

  Future<void> sendMessage(
    MessageType type, {
    Map<String, Object?> payload = const {},
  }) async {
    _checkOpen();
    if (type.isRequest || type.isResponse) {
      throw const ProtocolException(ProtocolError.invalidCorrelation);
    }
    _requireScope(type);
    await _serializeSend(() async {
      final envelope = _createEnvelope(type, payload);
      await _packets.sendControl(_codec.encode(envelope));
      _sendSequence++;
    });
  }

  Future<MessageEnvelope> request(
    MessageType type, {
    Map<String, Object?> payload = const {},
    Duration timeout = requestTimeout,
  }) async {
    _checkOpen();
    if (!type.isRequest) {
      throw const ProtocolException(ProtocolError.invalidCorrelation);
    }
    if (_pendingRequests.length >= maximumPendingRequests) {
      throw const ProtocolException(ProtocolError.tooManyPendingRequests);
    }
    _requireScope(type);
    final completer = Completer<MessageEnvelope>();
    String? messageId;
    try {
      await _serializeSend(() async {
        if (_pendingRequests.length >= maximumPendingRequests) {
          throw const ProtocolException(ProtocolError.tooManyPendingRequests);
        }
        final envelope = _createEnvelope(type, payload);
        final id = envelope.messageId;
        messageId = id;
        _pendingRequests[id] = completer;
        await _packets.sendControl(_codec.encode(envelope));
        _sendSequence++;
      });
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw const ProtocolException(ProtocolError.requestTimedOut);
    } finally {
      final id = messageId;
      if (id != null) _pendingRequests.remove(id);
    }
  }

  Future<void> respond(
    MessageEnvelope request, {
    required MessageType type,
    Map<String, Object?> payload = const {},
  }) async {
    _checkOpen();
    _discardExpiredInboundRequests();
    if (!request.type.isRequest ||
        !type.isResponse ||
        !_inboundRequests.containsKey(request.messageId)) {
      throw const ProtocolException(ProtocolError.invalidCorrelation);
    }
    _requireScope(type);
    await _serializeSend(() async {
      if (!_inboundRequests.containsKey(request.messageId)) {
        throw const ProtocolException(ProtocolError.invalidCorrelation);
      }
      final response = _createEnvelope(
        type,
        payload,
        requestId: request.messageId,
      );
      await _packets.sendControl(_codec.encode(response));
      _sendSequence++;
      _inboundRequests.remove(request.messageId);
    });
  }

  Future<MessageEnvelope> receiveMessage() async {
    _checkOpen();
    final bytes = await _packets.receiveControl();
    final envelope = _codec.decode(
      bytes: bytes,
      expectedSequence: _receiveSequence,
    );
    if (_recentMessageIds.contains(envelope.messageId)) {
      throw const ProtocolException(ProtocolError.replayedMessage);
    }
    if (envelope.type.isResponse) {
      final pending = _pendingRequests[envelope.requestId];
      if (pending == null || pending.isCompleted) {
        throw const ProtocolException(ProtocolError.invalidCorrelation);
      }
      pending.complete(envelope);
    } else if (envelope.type.isRequest) {
      _discardExpiredInboundRequests();
      if (_inboundRequests.length >= maximumPendingRequests) {
        throw const ProtocolException(ProtocolError.tooManyPendingRequests);
      }
      _inboundRequests[envelope.messageId] = _clock().toUtc().add(
        requestTimeout,
      );
      _discardExpiredInboundRequests();
    }
    _rememberMessageId(envelope.messageId);
    _receiveSequence++;
    return envelope;
  }

  MessageEnvelope _createEnvelope(
    MessageType type,
    Map<String, Object?> payload, {
    String? requestId,
  }) {
    final payloadLength = utf8.encode(jsonEncode(payload)).length;
    return MessageEnvelope(
      type: type,
      messageId: _newMessageId(),
      requestId: requestId,
      sequence: _sendSequence,
      timestamp: _clock().toUtc().millisecondsSinceEpoch,
      payloadLength: payloadLength,
      payload: Map.unmodifiable(payload),
    );
  }

  String _newMessageId() => List<int>.generate(
    16,
    (_) => _random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  void _requireScope(MessageType type) {
    if (!authorization.allows(type.requiredScope)) {
      throw const ProtocolException(ProtocolError.unauthorized);
    }
  }

  Future<void> _serializeSend(Future<void> Function() action) {
    final result = Completer<void>();
    _sendQueue = _sendQueue.then((_) async {
      try {
        await action();
        result.complete();
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  void _rememberMessageId(String id) {
    _recentMessageIds.add(id);
    _messageIdOrder.add(id);
    if (_messageIdOrder.length > maximumRecentMessageIds) {
      _recentMessageIds.remove(_messageIdOrder.removeAt(0));
    }
  }

  void _discardExpiredInboundRequests() {
    final now = _clock().toUtc();
    _inboundRequests.removeWhere((_, expiresAt) => !now.isBefore(expiresAt));
  }

  void _checkOpen() {
    if (_closed) throw const ProtocolException(ProtocolError.closed);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pendingRequests.values) {
      if (!pending.isCompleted) {
        pending.completeError(const ProtocolException(ProtocolError.closed));
      }
    }
    _pendingRequests.clear();
    _inboundRequests.clear();
    await _packets.close();
  }
}
