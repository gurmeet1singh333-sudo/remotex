import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/protocol/disconnect_reason.dart';
import 'package:remotex/core/protocol/message_envelope.dart';
import 'package:remotex/core/protocol/message_type.dart';
import 'package:remotex/core/protocol/message_validator.dart';
import 'package:remotex/core/protocol/protocol_error.dart';
import 'package:remotex/core/protocol/session_message_codec.dart';
import 'package:remotex/core/protocol/session_message_protocol.dart';
import 'package:remotex/core/protocol/session_authorization.dart';
import 'package:remotex/core/protocol/session_packet_multiplexer.dart';
import 'package:remotex/core/services/secure_session_channel.dart';

void main() {
  late SessionMessageCodec codec;
  late MessageValidator validator;
  final now = DateTime.utc(2026, 10, 3, 12);

  setUp(() {
    validator = MessageValidator(clock: () => now);
    codec = SessionMessageCodec(validator: validator);
    _testCodec = codec;
  });

  test('encodes and decodes a valid versioned message', () {
    final envelope = _message(
      timestamp: now.millisecondsSinceEpoch,
      type: MessageType.ping,
      sequence: 4,
      payload: const {'probe': 'alive'},
    );

    final decoded = codec.decode(
      bytes: codec.encode(envelope),
      expectedSequence: 4,
    );

    expect(decoded.type, MessageType.ping);
    expect(decoded.sequence, 4);
    expect(decoded.payload, {'probe': 'alive'});
    expect(decoded.payloadLength, utf8.encode('{"probe":"alive"}').length);
  });

  test('rejects an unknown message type and protocol version', () {
    expect(
      () => _decodeRaw({'type': 'future_unknown'}),
      throwsA(_protocolError(ProtocolError.unknownMessageType)),
    );
    expect(
      () => _decodeRaw({'version': 99}),
      throwsA(_protocolError(ProtocolError.unsupportedVersion)),
    );
  });

  test('rejects missing fields, malformed payloads, and invalid IDs', () {
    expect(
      () => _decodeRaw({'sequence': null}),
      throwsA(_protocolError(ProtocolError.invalidSequence)),
    );
    expect(
      () => _decodeRaw({'payload': 'not-an-object'}),
      throwsA(_protocolError(ProtocolError.invalidPayload)),
    );
    expect(
      () => _decodeRaw({'messageId': 'bad-id'}),
      throwsA(_protocolError(ProtocolError.invalidMessageId)),
    );
    final missing = _base();
    missing.remove('messageId');
    expect(
      () => codec.decode(
        bytes: utf8.encode(jsonEncode(missing)),
        expectedSequence: 0,
      ),
      throwsA(_protocolError(ProtocolError.invalidMessageId)),
    );
    expect(
      () => codec.decode(bytes: utf8.encode('{broken'), expectedSequence: 0),
      throwsA(_protocolError(ProtocolError.malformedMessage)),
    );
  });

  test('rejects unexpected and duplicate sequence numbers', () async {
    expect(
      () => _decodeRaw({'sequence': 1}, expectedSequence: 0),
      throwsA(_protocolError(ProtocolError.invalidSequence)),
    );

    final (sender, receiver) = _protocolPair();
    await sender.sendMessage(
      MessageType.disconnect,
      payload: const {'reason': 'user_requested'},
    );
    expect((await receiver.receiveMessage()).sequence, 0);
    replayLastSend!();
    await expectLater(
      receiver.receiveMessage(),
      throwsA(_protocolError(ProtocolError.invalidSequence)),
    );
  });

  test('rejects a repeated message ID even with a new sequence', () async {
    final (_, receiver) = _protocolPair();
    final first = _MemoryChannel.lastCreated!.peer!;
    final message = utf8.encode(
      jsonEncode({
        'version': 1,
        'type': 'ping',
        'messageId': '0123456789abcdef0123456789abcdef',
        'sequence': 0,
        'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
        'payloadLength': 2,
        'payload': <String, Object?>{},
      }),
    );
    first.pushRaw(message);
    await receiver.receiveMessage();

    final replayWithNextSequence = Map<String, Object?>.from(
      jsonDecode(utf8.decode(message)) as Map,
    )..['sequence'] = 1;
    first.pushRaw(utf8.encode(jsonEncode(replayWithNextSequence)));
    await expectLater(
      receiver.receiveMessage(),
      throwsA(_protocolError(ProtocolError.replayedMessage)),
    );
  });

  test('rejects oversized payloads before protocol JSON decoding', () {
    final bytes = List<int>.filled(
      MessageValidator.maximumEncodedMessageBytes + 1,
      65,
    );
    expect(
      () => codec.decode(bytes: bytes, expectedSequence: 0),
      throwsA(_protocolError(ProtocolError.payloadTooLarge)),
    );

    final largeEnvelope = _message(
      timestamp: now.millisecondsSinceEpoch,
      type: MessageType.ping,
      payload: {'data': 'x' * 3000},
    );
    expect(
      () => codec.encode(largeEnvelope),
      throwsA(_protocolError(ProtocolError.payloadTooLarge)),
    );
  });

  test('strictly validates bounded mouse and keyboard payloads', () {
    final controlCodec = SessionMessageCodec(
      validator: validator,
      authorization: SessionAuthorization(
        initialScopes: const {
          AuthorizationScope.session,
          AuthorizationScope.mouseControl,
          AuthorizationScope.keyboardControl,
        },
      ),
    );
    expect(
      () => controlCodec.encode(
        _message(
          type: MessageType.mouseMove,
          payload: const {'x': 0.5, 'y': 1.0},
        ),
      ),
      returnsNormally,
    );
    expect(
      () => controlCodec.encode(
        _message(
          type: MessageType.mouseButton,
          payload: const {'button': 'right', 'action': 'double_click'},
        ),
      ),
      returnsNormally,
    );
    expect(
      () => controlCodec.encode(
        _message(
          type: MessageType.keyboardKey,
          payload: const {'key': 'Control', 'action': 'down'},
        ),
      ),
      returnsNormally,
    );
    for (final payload in [
      const {'x': -0.1, 'y': 0.5},
      const {'x': 0.5, 'y': 0.5, 'command': 'shell'},
    ]) {
      expect(
        () => controlCodec.encode(
          _message(type: MessageType.mouseMove, payload: payload),
        ),
        throwsA(_protocolError(ProtocolError.invalidPayload)),
      );
    }
    expect(
      () => controlCodec.encode(
        _message(
          type: MessageType.keyboardKey,
          payload: const {'key': 'not-a-key', 'action': 'press'},
        ),
      ),
      throwsA(_protocolError(ProtocolError.invalidPayload)),
    );
    expect(
      () => controlCodec.encode(
        _message(
          type: MessageType.mouseScroll,
          payload: const {'deltaX': 0, 'deltaY': 2001},
        ),
      ),
      throwsA(_protocolError(ProtocolError.invalidPayload)),
    );
  });

  test(
    'validates typed remote cursor updates and rejects out-of-range data',
    () {
      final cursorCodec = SessionMessageCodec(
        validator: validator,
        authorization: SessionAuthorization(
          initialScopes: const {
            AuthorizationScope.session,
            AuthorizationScope.screenView,
          },
        ),
      );
      expect(
        () => cursorCodec.encode(
          _message(
            type: MessageType.cursorPosition,
            payload: const {
              'x': 320,
              'y': 180,
              'width': 640,
              'height': 360,
              'visible': true,
            },
          ),
        ),
        returnsNormally,
      );
      expect(
        () => cursorCodec.encode(
          _message(
            type: MessageType.cursorPosition,
            payload: const {
              'x': 640,
              'y': 180,
              'width': 640,
              'height': 360,
              'visible': true,
            },
          ),
        ),
        throwsA(_protocolError(ProtocolError.invalidPayload)),
      );
    },
  );

  test('rejects stale timestamps and unknown disconnect reasons', () {
    expect(
      () => codec.encode(
        _message(
          timestamp: now
              .subtract(const Duration(minutes: 6))
              .millisecondsSinceEpoch,
          type: MessageType.ping,
        ),
      ),
      throwsA(_protocolError(ProtocolError.invalidTimestamp)),
    );
    expect(
      () => codec.encode(
        _message(
          timestamp: now.millisecondsSinceEpoch,
          type: MessageType.disconnect,
          payload: const {'reason': 'secret_reason'},
        ),
      ),
      throwsA(_protocolError(ProtocolError.invalidPayload)),
    );
    expect(
      DisconnectReason.values.map((reason) => reason.wireName),
      containsAll([
        'user_requested',
        'timeout',
        'network_error',
        'authentication_failed',
        'revoked',
        'protocol_error',
        'remote_closed',
      ]),
    );
  });

  test(
    'enforces authorization scopes without enabling future capabilities',
    () {
      final (sender, receiver) = _protocolPair();
      expect(
        sender.sendMessage(MessageType.mouseMove),
        throwsA(_protocolError(ProtocolError.unauthorized)),
      );
      final privilegedCodec = SessionMessageCodec(
        validator: validator,
        grantedScopes: const {
          AuthorizationScope.session,
          AuthorizationScope.screenView,
        },
      );
      expect(
        privilegedCodec.grantedScopes,
        contains(AuthorizationScope.screenView),
      );
      expect(
        privilegedCodec.grantedScopes,
        isNot(contains(AuthorizationScope.mouseControl)),
      );
      expect(receiver, isNotNull);
    },
  );

  test('correlates responses with bounded request IDs', () async {
    final (client, host) = _protocolPair();
    final requestFuture = client.request(MessageType.ping);
    final clientResponse = client.receiveMessage();
    final request = await host.receiveMessage();
    expect(request.type, MessageType.ping);

    await host.respond(
      request,
      type: MessageType.pong,
      payload: const {'alive': true},
    );
    expect((await clientResponse).requestId, request.messageId);
    final response = await requestFuture;
    expect(response.payload['alive'], isTrue);

    await expectLater(
      host.respond(request, type: MessageType.pong),
      throwsA(_protocolError(ProtocolError.invalidCorrelation)),
    );
  });

  test('bounds outstanding request-response correlations', () async {
    final (protocol, _) = _protocolPair();
    final pending = <Future<void>>[];
    for (
      var index = 0;
      index < SessionMessageProtocol.maximumPendingRequests;
      index++
    ) {
      pending.add(
        protocol
            .request(MessageType.ping)
            .then<void>((_) {}, onError: (Object error) {}),
      );
    }
    await expectLater(
      protocol.request(MessageType.ping),
      throwsA(_protocolError(ProtocolError.tooManyPendingRequests)),
    );
    await protocol.close();
    await Future.wait(pending);
  });
}

void Function()? replayLastSend;

(SessionMessageProtocol, SessionMessageProtocol) _protocolPair() {
  final first = _MemoryChannel();
  final second = _MemoryChannel();
  first.peer = second;
  second.peer = first;
  replayLastSend = first.replayLastSend;
  return (
    SessionMessageProtocol(packets: SessionPacketMultiplexer(first)),
    SessionMessageProtocol(packets: SessionPacketMultiplexer(second)),
  );
}

MessageEnvelope _message({
  int timestamp = 1791028800000,
  MessageType type = MessageType.ping,
  int sequence = 0,
  Map<String, Object?> payload = const {},
}) => MessageEnvelope(
  type: type,
  messageId: '0123456789abcdef0123456789abcdef',
  sequence: sequence,
  timestamp: timestamp,
  payloadLength: utf8.encode(jsonEncode(payload)).length,
  payload: payload,
);

Map<String, Object?> _base() => {
  'version': 1,
  'type': 'ping',
  'messageId': '0123456789abcdef0123456789abcdef',
  'sequence': 0,
  'timestamp': 1791028800000,
  'payloadLength': 2,
  'payload': <String, Object?>{},
};

MessageEnvelope _decodeRaw(
  Map<String, Object?> changes, {
  int expectedSequence = 0,
}) {
  final json = _base()..addAll(changes);
  return codec.decode(
    bytes: utf8.encode(jsonEncode(json)),
    expectedSequence: expectedSequence,
  );
}

SessionMessageCodec get codec => _testCodec;
late SessionMessageCodec _testCodec;

Matcher _protocolError(ProtocolError error) => isA<ProtocolException>().having(
  (exception) => exception.error,
  'error',
  error,
);

class _MemoryChannel implements SecureSessionChannel {
  static _MemoryChannel? lastCreated;

  _MemoryChannel() {
    lastCreated = this;
  }

  final _queued = Queue<List<int>>();
  Completer<List<int>>? _waiting;
  _MemoryChannel? peer;
  List<int>? _lastSend;
  bool _closed = false;

  @override
  Future<void> send(List<int> plaintext) async {
    if (_closed) throw StateError('Channel closed.');
    _lastSend = List.of(plaintext);
    peer!._push(plaintext);
  }

  void replayLastSend() {
    peer!._push(_lastSend!);
  }

  void pushRaw(List<int> bytes) => peer!._push(bytes);

  void _push(List<int> bytes) {
    final waiter = _waiting;
    if (waiter != null) {
      _waiting = null;
      waiter.complete(List.of(bytes));
    } else {
      _queued.add(List.of(bytes));
    }
  }

  @override
  Future<List<int>> receive() {
    if (_closed) throw StateError('Channel closed.');
    if (_queued.isNotEmpty) return Future.value(_queued.removeFirst());
    _waiting ??= Completer<List<int>>();
    return _waiting!.future;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _waiting?.completeError(StateError('Channel closed.'));
    _waiting = null;
  }
}
