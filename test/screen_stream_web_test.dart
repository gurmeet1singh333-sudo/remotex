import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/remote_cursor_position.dart';
import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/models/screen_stream_state.dart';
import 'package:remotex/core/services/screen_capture_service.dart';
import 'package:remotex/services/session/screen_stream_service.dart';

import 'support/test_helpers.dart';

void main() {
  late MockSessionService sessionService;
  late MockPairedDevicesService pairedDevicesService;
  late MockScreenCaptureService captureService;
  late ScreenStreamService streamService;

  setUp(() {
    sessionService = MockSessionService();
    pairedDevicesService = MockPairedDevicesService();
    captureService = MockScreenCaptureService();

    streamService = ScreenStreamService(
      sessionService: sessionService,
      pairedDevicesService: pairedDevicesService,
      captureService: captureService,
    );
  });

  tearDown(() async {
    await streamService.dispose();
  });

  test('starts viewing screen and receives binary screen frame snapshot', () async {
    final sessionId = 'view_1';
    final frame = ScreenFrame(
      sequence: 1,
      timestamp: DateTime.now().toUtc(),
      width: 1920,
      height: 1080,
      format: ScreenFrameFormat.jpeg,
      keyFrame: true,
      encodedBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
    );

    await streamService.startViewing(sessionId);
    expect(streamService.snapshot.state, ScreenStreamState.streaming);

    sessionService.incomingFramesController.add(
      ReceivedScreenFrame(sessionId: sessionId, frame: frame),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(streamService.snapshot.frame, isNotNull);
    expect(streamService.snapshot.frame!.encodedBytes, equals([0xFF, 0xD8, 0xFF, 0xE0]));
  });

  test('ignores incoming frames for inactive or stopped viewer session', () async {
    final sessionId = 'view_2';
    await streamService.startViewing(sessionId);
    await streamService.stopViewing();

    expect(streamService.snapshot.state, ScreenStreamState.idle);

    final frame = ScreenFrame(
      sequence: 2,
      timestamp: DateTime.now().toUtc(),
      width: 1920,
      height: 1080,
      format: ScreenFrameFormat.jpeg,
      keyFrame: true,
      encodedBytes: Uint8List.fromList([1, 2, 3]),
    );

    sessionService.incomingFramesController.add(
      ReceivedScreenFrame(sessionId: sessionId, frame: frame),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(streamService.snapshot.frame, isNull);
  });

  test('prefers newest frame and drops stale out-of-order frames', () async {
    final sessionId = 'view_3';
    await streamService.startViewing(sessionId);

    final frame10 = ScreenFrame(
      sequence: 10,
      timestamp: DateTime.now().toUtc(),
      width: 1920,
      height: 1080,
      format: ScreenFrameFormat.jpeg,
      keyFrame: true,
      encodedBytes: Uint8List.fromList([10]),
    );

    final frame5 = ScreenFrame(
      sequence: 5,
      timestamp: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      width: 1920,
      height: 1080,
      format: ScreenFrameFormat.jpeg,
      keyFrame: true,
      encodedBytes: Uint8List.fromList([5]),
    );

    sessionService.incomingFramesController.add(
      ReceivedScreenFrame(sessionId: sessionId, frame: frame10),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(streamService.snapshot.frame!.sequence, 10);

    // Send older frame sequence 5
    sessionService.incomingFramesController.add(
      ReceivedScreenFrame(sessionId: sessionId, frame: frame5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // Snapshot should still retain frame 10 (stale frame dropped)
    expect(streamService.snapshot.frame!.sequence, 10);
  });
}

class MockScreenCaptureService implements ScreenCaptureService {
  final _framesController = StreamController<ScreenFrame>.broadcast();

  @override
  Stream<ScreenFrame> get frames => _framesController.stream;

  @override
  Object? get lastError => null;

  @override
  Future<ScreenDimensions> startCapture() async {
    return const ScreenDimensions(width: 1920, height: 1080);
  }

  @override
  Future<void> stopCapture() async {}

  @override
  Future<RemoteCursorPosition?> getCursorPosition() async => null;
}
