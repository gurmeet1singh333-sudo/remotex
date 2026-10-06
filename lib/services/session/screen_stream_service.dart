import 'dart:async';
import 'dart:developer' as developer;

import 'package:remotex/core/models/remote_cursor_position.dart';
import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/models/screen_stream_snapshot.dart';
import 'package:remotex/core/models/screen_stream_state.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/protocol/message_type.dart';
import 'package:remotex/core/protocol/received_session_message.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/screen_capture_service.dart';
import 'package:remotex/core/services/session_service.dart';

class ScreenStreamService {
  ScreenStreamService({
    required SessionService sessionService,
    required PairedDevicesService pairedDevicesService,
    required ScreenCaptureService captureService,
    DateTime Function()? clock,
  }) : _sessions = sessionService,
       _pairedDevices = pairedDevicesService,
       _capture = captureService,
       _clock = clock ?? DateTime.now {
    _messageSubscription = _sessions.incomingMessages.listen(
      (message) => unawaited(_handleMessage(message)),
    );
    _frameSubscription = _sessions.incomingFrames.listen(_handleFrame);
    _closedSubscription = _sessions.closedSessions.listen(
      (sessionId) => unawaited(_handleClosedSession(sessionId)),
    );
  }

  static const targetFramesPerSecond = 10;
  static const cursorUpdateInterval = Duration(milliseconds: 66);
  static const maximumQueuedFrameAge = Duration(milliseconds: 250);
  final SessionService _sessions;
  final PairedDevicesService _pairedDevices;
  final ScreenCaptureService _capture;
  final DateTime Function() _clock;
  final _updates = StreamController<ScreenStreamSnapshot>.broadcast();
  StreamSubscription<ReceivedSessionMessage>? _messageSubscription;
  StreamSubscription<ReceivedScreenFrame>? _frameSubscription;
  StreamSubscription<String>? _closedSubscription;
  StreamSubscription<ScreenFrame>? _captureSubscription;
  Timer? _cursorTimer;
  String? _viewerSession;
  String? _hostSession;
  ScreenStreamState _state = ScreenStreamState.idle;
  ScreenFrame? _latestFrame;
  RemoteCursorPosition? _cursor;
  RemoteCursorPosition? _lastSentCursor;
  ScreenDimensions? _dimensions;
  String? _error;
  DateTime? _lastDisplayedAt;
  double _fps = 0;
  ScreenFrame? _pendingHostFrame;
  bool _sendingHostFrame = false;
  bool _cursorPollInFlight = false;
  bool _disposed = false;

  Stream<ScreenStreamSnapshot> get updates => _updates.stream;

  ScreenStreamSnapshot get snapshot => ScreenStreamSnapshot(
    state: _state,
    frame: _latestFrame,
    cursor: _cursor,
    dimensions: _dimensions == null
        ? null
        : '${_dimensions!.width} × ${_dimensions!.height}',
    framesPerSecond: _fps,
    error: _error,
  );

  Future<void> startViewing(String sessionId) async {
    if (_state == ScreenStreamState.requesting ||
        _state == ScreenStreamState.streaming) {
      throw StateError('A screen view is already active.');
    }
    _viewerSession = sessionId;
    _latestFrame = null;
    _cursor = null;
    _error = null;
    _setState(ScreenStreamState.requesting);
    try {
      await _sessions.grantSessionScope(
        sessionId,
        AuthorizationScope.screenView,
      );
      final response = await _sessions.request(
        sessionId,
        MessageType.screenStart,
        payload: const {'maximumWidth': 1280, 'maximumHeight': 720},
      );
      if (response.type != MessageType.sessionReady) {
        throw StateError('The host could not start screen viewing.');
      }
      final width = response.payload['width'];
      final height = response.payload['height'];
      if (width is! int ||
          height is! int ||
          width <= 0 ||
          height <= 0 ||
          width > 1280 ||
          height > 720) {
        throw StateError('The host returned invalid screen dimensions.');
      }
      _dimensions = ScreenDimensions(width: width, height: height);
      _setState(ScreenStreamState.streaming);
    } on Object {
      await _sessions.revokeSessionScope(
        sessionId,
        AuthorizationScope.screenView,
      );
      _setState(ScreenStreamState.failed, 'Screen viewing was not authorized.');
      rethrow;
    }
  }

  Future<void> stopViewing() async {
    final sessionId = _viewerSession;
    if (sessionId == null) return;
    _setState(ScreenStreamState.stopping);
    try {
      if (_sessions.isSessionActive(sessionId)) {
        await _sessions.request(sessionId, MessageType.screenStop);
      }
    } finally {
      await _sessions.revokeSessionScope(
        sessionId,
        AuthorizationScope.screenView,
      );
      _viewerSession = null;
      _dimensions = null;
      _latestFrame = null;
      _cursor = null;
      _setState(ScreenStreamState.idle);
    }
  }

  Future<void> _handleMessage(ReceivedSessionMessage received) async {
    final message = received.envelope;
    if (message.type == MessageType.cursorPosition) {
      if (_viewerSession == received.sessionId &&
          _state == ScreenStreamState.streaming) {
        _cursor = RemoteCursorPosition.fromJson(message.payload);
        _emit();
      }
    } else if (message.type == MessageType.screenStart) {
      await _startHostStream(received);
    } else if (message.type == MessageType.screenStop) {
      await _stopHostStream(received);
    }
  }

  Future<void> _startHostStream(ReceivedSessionMessage received) async {
    final sessionId = received.sessionId;
    try {
      final deviceId = _sessions.peerIdForSession(sessionId);
      if (!_sessions.isSessionActive(sessionId) || deviceId == null) {
        throw StateError('Session is not active.');
      }
      if (await _pairedDevices.isRevoked(deviceId)) {
        throw StateError('Device is revoked.');
      }
      final paired = (await _pairedDevices.getPairedDevices())
          .where((device) => device.id == deviceId)
          .firstOrNull;
      if (paired == null || !paired.hasScope(AuthorizationScope.screenView)) {
        throw StateError('Screen viewing is not authorized.');
      }
      if (_hostSession != null && _hostSession != sessionId) {
        throw StateError('Another screen view is active.');
      }

      _setState(ScreenStreamState.starting);
      final dimensions = await _capture.startCapture();
      _dimensions = dimensions;
      _hostSession = sessionId;
      await _sessions.grantSessionScope(
        sessionId,
        AuthorizationScope.screenView,
      );
      _captureSubscription = _capture.frames.listen(
        (frame) => _queueLatestHostFrame(sessionId, frame),
        onError: (Object error) => unawaited(_captureFailed(sessionId, error)),
      );
      _lastSentCursor = null;
      _cursorTimer = Timer.periodic(cursorUpdateInterval, (_) {
        unawaited(_pollAndSendCursor(sessionId));
      });
      unawaited(_pollAndSendCursor(sessionId));
      _setState(ScreenStreamState.streaming);
      await _sessions.respond(
        sessionId,
        received.envelope,
        type: MessageType.sessionReady,
        payload: {
          'width': dimensions.width,
          'height': dimensions.height,
          'mouseControl': paired.hasScope(AuthorizationScope.mouseControl),
          'keyboardControl': paired.hasScope(
            AuthorizationScope.keyboardControl,
          ),
        },
      );
    } on Object {
      await _stopCapture(sessionId);
      if (_sessions.isSessionActive(sessionId)) {
        await _sessions.respond(
          sessionId,
          received.envelope,
          type: MessageType.sessionError,
          payload: const {'code': 'screen_unavailable'},
        );
      }
      _setState(ScreenStreamState.failed, 'Screen viewing could not start.');
    }
  }

  Future<void> _pollAndSendCursor(String sessionId) async {
    if (_cursorPollInFlight ||
        _hostSession != sessionId ||
        !_sessions.isSessionActive(sessionId)) {
      return;
    }
    _cursorPollInFlight = true;
    try {
      final cursor = await _capture.getCursorPosition();
      if (cursor == null || _hostSession != sessionId) return;
      if (_sameCursor(cursor, _lastSentCursor)) return;
      await _sessions.sendMessage(
        sessionId,
        MessageType.cursorPosition,
        payload: cursor.toJson(),
      );
      _lastSentCursor = cursor;
    } on Object catch (error) {
      developer.log(
        'Cursor position update failed.',
        name: 'remotex.screen_stream',
        error: error.runtimeType,
      );
    } finally {
      _cursorPollInFlight = false;
    }
  }

  bool _sameCursor(
    RemoteCursorPosition current,
    RemoteCursorPosition? previous,
  ) =>
      previous != null &&
      current.x == previous.x &&
      current.y == previous.y &&
      current.width == previous.width &&
      current.height == previous.height &&
      current.visible == previous.visible;

  Future<void> _stopHostStream(ReceivedSessionMessage received) async {
    final sessionId = received.sessionId;
    if (_hostSession == sessionId) await _stopCapture(sessionId);
    if (_sessions.isSessionActive(sessionId)) {
      await _sessions.respond(
        sessionId,
        received.envelope,
        type: MessageType.sessionReady,
        payload: const {'stopped': true},
      );
    }
  }

  void _queueLatestHostFrame(String sessionId, ScreenFrame frame) {
    if (_hostSession != sessionId) return;
    _pendingHostFrame = frame;
    if (!_sendingHostFrame) unawaited(_drainHostFrames(sessionId));
  }

  Future<void> _drainHostFrames(String sessionId) async {
    _sendingHostFrame = true;
    try {
      while (_hostSession == sessionId && _pendingHostFrame != null) {
        final frame = _pendingHostFrame!;
        _pendingHostFrame = null;
        if (_clock().toUtc().difference(frame.timestamp.toUtc()) >
            maximumQueuedFrameAge) {
          continue;
        }
        await _sessions.sendFrame(sessionId, frame);
      }
    } on Object catch (error) {
      await _captureFailed(sessionId, error);
    } finally {
      _sendingHostFrame = false;
      if (_hostSession == sessionId && _pendingHostFrame != null) {
        unawaited(_drainHostFrames(sessionId));
      }
    }
  }

  Future<void> _captureFailed(String sessionId, Object error) async {
    _error = error.toString();
    await _stopCapture(sessionId);
    _setState(ScreenStreamState.failed, 'Screen capture stopped unexpectedly.');
  }

  Future<void> _stopCapture(String sessionId) async {
    if (_hostSession != sessionId) return;
    _cursorTimer?.cancel();
    _cursorTimer = null;
    _lastSentCursor = null;
    await _captureSubscription?.cancel();
    _captureSubscription = null;
    _pendingHostFrame = null;
    await _capture.stopCapture();
    await _sessions.revokeSessionScope(
      sessionId,
      AuthorizationScope.screenView,
    );
    _hostSession = null;
  }

  void _handleFrame(ReceivedScreenFrame received) {
    if (_viewerSession != received.sessionId ||
        _state != ScreenStreamState.streaming) {
      return;
    }
    final currentFrame = _latestFrame;
    if (currentFrame != null && received.frame.sequence <= currentFrame.sequence) {
      return;
    }
    final now = _clock().toUtc();
    final last = _lastDisplayedAt;
    if (last != null) {
      final elapsed = now.difference(last).inMilliseconds;
      if (elapsed > 0) _fps = 1000 / elapsed;
    }
    _lastDisplayedAt = now;
    _latestFrame = received.frame;
    _emit();
  }

  Future<void> _handleClosedSession(String sessionId) async {
    if (_hostSession == sessionId) {
      await _stopCapture(sessionId);
    }
    if (_viewerSession == sessionId) {
      _viewerSession = null;
      _dimensions = null;
      _latestFrame = null;
      _cursor = null;
      _setState(ScreenStreamState.disconnected, 'Session disconnected.');
    }
  }

  void _setState(ScreenStreamState state, [String? error]) {
    _state = state;
    _error = error;
    _emit();
  }

  void _emit() {
    if (!_disposed && !_updates.isClosed) _updates.add(snapshot);
  }

  Future<void> stopAll() async {
    final viewer = _viewerSession;
    if (viewer != null) await stopViewing();
    final host = _hostSession;
    if (host != null) await _stopCapture(host);
    _setState(ScreenStreamState.idle);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stopAll();
    _disposed = true;
    await _messageSubscription?.cancel();
    await _frameSubscription?.cancel();
    await _closedSubscription?.cancel();
    await _updates.close();
  }
}
