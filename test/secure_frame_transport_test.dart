import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/protocol/protocol_error.dart';
import 'package:remotex/core/protocol/session_authorization.dart';
import 'package:remotex/core/protocol/session_packet_multiplexer.dart';
import 'package:remotex/core/services/secure_session_channel.dart';
import 'package:remotex/services/session/binary_secure_frame_transport.dart';

void main() {
  test('requires screen_view authorization on the binary frame lane', () async {
    final channel = _MemoryChannel();
    final packets = SessionPacketMultiplexer(channel);
    final frames = BinarySecureFrameTransport(
      packets: packets,
      authorization: SessionAuthorization(),
    );

    await expectLater(
      frames.sendFrame(_jpegFrame()),
      throwsA(
        isA<ProtocolException>().having(
          (error) => error.error,
          'error',
          ProtocolError.unauthorized,
        ),
      ),
    );
    await packets.close();
    await channel.close();
  });

  test(
    'validates frame metadata and encrypted-lane sequence numbers',
    () async {
      final (sender, receiver, senderWire) = _pair();
      final frame = _jpegFrame();
      await sender.sendFrame(frame);
      final received = await receiver.receiveFrame();
      expect(received.sequence, 0);
      expect(received.width, 640);
      expect(received.height, 360);
      expect(received.encodedBytes, frame.encodedBytes);

      senderWire.replayLastSend();
      await expectLater(
        receiver.receiveFrame(),
        throwsA(isA<FrameTransportException>()),
      );
      await senderMux!.close();
      await receiverMux!.close();
    },
  );

  test('rejects oversized frames and invalid JPEG format bytes', () async {
    final (sender, receiver, _) = _pair();
    final tooLarge = Uint8List(
      BinarySecureFrameTransport.maximumEncodedFrameBytes + 1,
    )..fillRange(0, BinarySecureFrameTransport.maximumEncodedFrameBytes + 1, 1);
    tooLarge[0] = 0xff;
    tooLarge[1] = 0xd8;
    tooLarge[tooLarge.length - 2] = 0xff;
    tooLarge[tooLarge.length - 1] = 0xd9;
    await expectLater(
      sender.sendFrame(_jpegFrame(encodedBytes: tooLarge)),
      throwsA(isA<FrameTransportException>()),
    );

    final badJpeg = _jpegFrame(encodedBytes: Uint8List.fromList([1, 2, 3, 4]));
    await expectLater(
      sender.sendFrame(badJpeg),
      throwsA(isA<FrameTransportException>()),
    );
    await senderMux!.close();
    await receiverMux!.close();
  });

  test('rejects invalid frame format and untrusted frame metadata', () async {
    final (_, receiver, _) = _pair();
    final metadata = [
      ...'{"sequence":0,"timestamp":${DateTime.now().millisecondsSinceEpoch},"width":640,"height":360,"format":"png","encodedSize":6,"keyFrame":true}'
          .codeUnits,
    ];
    final packet = <int>[
      metadata.length >> 8,
      metadata.length & 0xff,
      ...metadata,
      0xff,
      0xd8,
      1,
      2,
      0xff,
      0xd9,
    ];
    await senderMux!.sendFrame(packet);
    await expectLater(
      receiver.receiveFrame(),
      throwsA(isA<FrameTransportException>()),
    );
    await senderMux!.close();
    await receiverMux!.close();
  });

  test('multiplexer drops queued stale frames to bound backpressure', () async {
    _pair();
    for (var index = 1; index <= 5; index++) {
      await senderMux!.sendFrame([index]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await receiverMux!.receiveFrame(), [5]);
    await senderMux!.close();
    await receiverMux!.close();
  });

  test('control sends take priority over queued stale video frames', () async {
    final channel = _BlockingChannel();
    final packets = SessionPacketMultiplexer(channel);
    final firstFrame = packets.sendFrame([1]);
    await channel.firstSendStarted.future;
    final droppedFrame = packets.sendFrame([2]);
    final newestFrame = packets.sendFrame([3]);
    final control = packets.sendControl([0x7b]);
    channel.releaseFirstSend.complete();

    expect(await firstFrame, isTrue);
    expect(await droppedFrame, isFalse);
    expect(await newestFrame, isTrue);
    await control;
    expect(channel.sent, [
      [...SessionPacketMultiplexer.frameMagic, 1],
      [0x7b],
      [...SessionPacketMultiplexer.frameMagic, 3],
    ]);
    await packets.close();
    await channel.close();
  });
}

late SessionPacketMultiplexer? senderMux;
late SessionPacketMultiplexer? receiverMux;

(BinarySecureFrameTransport, BinarySecureFrameTransport, _MemoryChannel)
_pair() {
  final firstWire = _MemoryChannel();
  final secondWire = _MemoryChannel();
  firstWire.peer = secondWire;
  secondWire.peer = firstWire;
  senderMux = SessionPacketMultiplexer(firstWire);
  receiverMux = SessionPacketMultiplexer(secondWire);
  final senderAuthorization = SessionAuthorization(
    initialScopes: const {
      AuthorizationScope.session,
      AuthorizationScope.screenView,
    },
  );
  final receiverAuthorization = SessionAuthorization(
    initialScopes: const {
      AuthorizationScope.session,
      AuthorizationScope.screenView,
    },
  );
  return (
    BinarySecureFrameTransport(
      packets: senderMux!,
      authorization: senderAuthorization,
    ),
    BinarySecureFrameTransport(
      packets: receiverMux!,
      authorization: receiverAuthorization,
    ),
    firstWire,
  );
}

ScreenFrame _jpegFrame({Uint8List? encodedBytes}) => ScreenFrame(
  sequence: 0,
  timestamp: DateTime.now().toUtc(),
  width: 640,
  height: 360,
  format: ScreenFrameFormat.jpeg,
  keyFrame: true,
  encodedBytes:
      encodedBytes ?? Uint8List.fromList([0xff, 0xd8, 1, 2, 0xff, 0xd9]),
);

class _MemoryChannel implements SecureSessionChannel {
  final _queued = Queue<List<int>>();
  Completer<List<int>>? _waiting;
  _MemoryChannel? peer;
  List<int>? _lastSent;

  @override
  Future<void> send(List<int> plaintext) async {
    _lastSent = List.of(plaintext);
    peer!._push(plaintext);
  }

  void replayLastSend() => peer!._push(_lastSent!);

  void _push(List<int> packet) {
    final waiter = _waiting;
    if (waiter != null) {
      _waiting = null;
      waiter.complete(List.of(packet));
    } else {
      _queued.add(List.of(packet));
    }
  }

  @override
  Future<List<int>> receive() {
    if (_queued.isNotEmpty) return Future.value(_queued.removeFirst());
    _waiting ??= Completer<List<int>>();
    return _waiting!.future;
  }

  @override
  Future<void> close() async {
    if (_waiting != null && !_waiting!.isCompleted) {
      _waiting!.completeError(StateError('closed'));
    }
  }
}

class _BlockingChannel implements SecureSessionChannel {
  final firstSendStarted = Completer<void>();
  final releaseFirstSend = Completer<void>();
  final sent = <List<int>>[];
  final neverReceived = Completer<List<int>>();

  @override
  Future<void> send(List<int> plaintext) async {
    if (sent.isEmpty) {
      firstSendStarted.complete();
      await releaseFirstSend.future;
    }
    sent.add(List.of(plaintext));
  }

  @override
  Future<List<int>> receive() => neverReceived.future;

  @override
  Future<void> close() async {
    if (!neverReceived.isCompleted) {
      neverReceived.completeError(StateError('closed'));
    }
  }
}
