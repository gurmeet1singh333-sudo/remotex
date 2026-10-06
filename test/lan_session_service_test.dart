import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/models/remote_cursor_position.dart';
import 'package:remotex/core/models/session_state.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/protocol/message_type.dart';
import 'package:remotex/core/services/screen_capture_service.dart';
import 'package:remotex/core/services/remote_input_service.dart';
import 'package:remotex/core/services/session_transport.dart';
import 'package:remotex/services/identity/cryptographic_device_identity_service.dart';
import 'package:remotex/services/session/cryptographic_session_key_manager.dart';
import 'package:remotex/services/session/lan_session_service.dart';
import 'package:remotex/services/session/lan_session_transport.dart';
import 'package:remotex/services/session/remote_control_service.dart';
import 'package:remotex/services/session/screen_stream_service.dart';
import 'package:remotex/services/session/signed_session_authenticator.dart';
import 'package:remotex/services/storage/secure_paired_devices_service.dart';

import 'support/in_memory_secure_storage.dart';

void main() {
  late _SessionFixture fixture;

  setUp(() async {
    fixture = _SessionFixture();
    await fixture.initialize();
  });

  tearDown(() async {
    await fixture.controller.disconnect();
    await fixture.host.stopHost();
  });

  test('reports the expected controller lifecycle transitions', () async {
    final states = <SessionState>[];
    final subscription = fixture.controller.stateChanges.listen(states.add);

    final info = await fixture.controller.connect(fixture.hostRecord);
    await Future<void>.delayed(Duration.zero);
    expect(info.state, SessionState.connected);
    expect(
      states,
      containsAllInOrder([
        SessionState.connecting,
        SessionState.authenticating,
        SessionState.connected,
      ]),
    );

    await fixture.controller.disconnect();
    await Future<void>.delayed(Duration.zero);
    expect(
      states,
      containsAllInOrder([
        SessionState.disconnecting,
        SessionState.disconnected,
      ]),
    );
    await subscription.cancel();
  });

  test(
    'dispatches control only after host authorization is propagated',
    () async {
      final hostInput = _RecordingRemoteInputService();
      final controllerInput = _RecordingRemoteInputService();
      final hostControl = RemoteControlService(
        sessionService: fixture.host,
        pairedDevicesService: fixture.hostDevices,
        inputService: hostInput,
      );
      final controllerControl = RemoteControlService(
        sessionService: fixture.controller,
        pairedDevicesService: fixture.controllerDevices,
        inputService: controllerInput,
      );
      addTearDown(hostInput.close);
      addTearDown(controllerInput.close);
      addTearDown(hostControl.dispose);
      addTearDown(controllerControl.dispose);

      final session = await fixture.controller.connect(fixture.hostRecord);
      if (fixture.host.state != SessionState.connected) {
        await fixture.host.stateChanges.firstWhere(
          (state) => state == SessionState.connected,
        );
      }
      await expectLater(
        controllerControl.sendMouseMove(session.sessionId, x: 0.5, y: 0.5),
        throwsStateError,
      );
      expect(hostInput.commands, isEmpty);

      final controllerId =
          (await fixture.hostDevices.getPairedDevices()).single.id;
      final scopeUpdate = controllerControl.updates.first;
      await fixture.host.setDeviceScope(
        controllerId,
        AuthorizationScope.mouseControl,
        enabled: true,
      );
      await scopeUpdate.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw StateError('Mouse authorization was not sent.'),
      );

      final dispatched = hostInput.nextCommand;
      await controllerControl.sendMouseMove(
        session.sessionId,
        x: 0.25,
        y: 0.75,
      );
      expect(
        await dispatched.timeout(const Duration(seconds: 3)),
        'move:0.25:0.75',
      );
      expect(controllerControl.canControlMouse(session.sessionId), isTrue);
      expect(controllerControl.canControlKeyboard(session.sessionId), isFalse);

      final keyboardUpdate = controllerControl.updates.first;
      await fixture.host.setDeviceScope(
        controllerId,
        AuthorizationScope.keyboardControl,
        enabled: true,
      );
      await keyboardUpdate.timeout(
        const Duration(seconds: 3),
        onTimeout: () =>
            throw StateError('Keyboard authorization was not sent.'),
      );
      final keyDispatched = hostInput.nextCommand;
      await controllerControl.sendKeyboardKey(
        session.sessionId,
        key: 'Control',
        action: 'down',
      );
      expect(
        await keyDispatched.timeout(
          const Duration(seconds: 3),
          onTimeout: () =>
              throw StateError('Keyboard input was not dispatched.'),
        ),
        'key:Control:down',
      );
      expect(controllerControl.canControlKeyboard(session.sessionId), isTrue);

      final release = hostInput.nextCommand;
      final keyboardRevoked = controllerControl.updates.first;
      await fixture.host.setDeviceScope(
        controllerId,
        AuthorizationScope.keyboardControl,
        enabled: false,
      );
      expect(
        await release.timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw StateError('Held key was not released.'),
        ),
        'key:Control:up',
      );
      await keyboardRevoked.timeout(const Duration(seconds: 3));
      expect(controllerControl.canControlKeyboard(session.sessionId), isFalse);
    },
  );

  test(
    'reconnects with a fresh authenticated session after disconnect',
    () async {
      final secondConnection = Completer<void>();
      final states = <SessionState>[];
      var connectedCount = 0;
      final subscription = fixture.controller.stateChanges.listen((state) {
        states.add(state);
        if (state == SessionState.connected && ++connectedCount == 2) {
          secondConnection.complete();
        }
      });

      await fixture.controller.connect(fixture.hostRecord);
      fixture.endpoint.dropControllerConnection();

      await secondConnection.future.timeout(const Duration(seconds: 8));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        fixture.controller.state,
        SessionState.connected,
        reason: 'Observed transitions: $states',
      );
      expect(states, contains(SessionState.reconnecting));
      expect(fixture.host.state, SessionState.connected);
      await subscription.cancel();
    },
  );

  test('intentional disconnect stops reconnect and reaches disconnected state', () async {
    final states = <SessionState>[];
    final subscription = fixture.controller.stateChanges.listen(states.add);

    await fixture.controller.connect(fixture.hostRecord);
    await fixture.controller.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fixture.controller.state, SessionState.disconnected);
    expect(states.contains(SessionState.disconnecting), isTrue);
    expect(states.last, SessionState.disconnected);
    await subscription.cancel();
  });

  test(
    'exchanges correlated protocol messages inside the encrypted session',
    () async {
      final hostRequest = Completer<void>();
      final hostSubscription = fixture.host.incomingMessages.listen((message) {
        unawaited(
          fixture.host
              .respond(
                message.sessionId,
                message.envelope,
                type: MessageType.pong,
                payload: const {'alive': true},
              )
              .then((_) => hostRequest.complete()),
        );
      });

      final session = await fixture.controller.connect(fixture.hostRecord);
      final response = await fixture.controller.request(
        session.sessionId,
        MessageType.ping,
        payload: const {'probe': 'secure-pipe'},
      );

      expect(response.type, MessageType.pong);
      expect(response.payload['alive'], isTrue);
      await hostRequest.future.timeout(const Duration(seconds: 3));
      await hostSubscription.cancel();
    },
  );

  test(
    'streams and stops authorized frames through the encrypted session',
    () async {
      final controllerId =
          (await fixture.hostDevices.getPairedDevices()).single.id;
      await fixture.hostDevices.setScope(
        controllerId,
        AuthorizationScope.screenView,
        enabled: true,
      );
      final capture = _TestCaptureService();
      capture.cursorPosition = const RemoteCursorPosition(
        x: 320,
        y: 180,
        width: 640,
        height: 360,
        visible: true,
      );
      final hostStream = ScreenStreamService(
        sessionService: fixture.host,
        pairedDevicesService: fixture.hostDevices,
        captureService: capture,
      );
      final controllerStream = ScreenStreamService(
        sessionService: fixture.controller,
        pairedDevicesService: fixture.controllerDevices,
        captureService: _TestCaptureService(),
      );
      addTearDown(hostStream.dispose);
      addTearDown(controllerStream.dispose);

      final session = await fixture.controller.connect(fixture.hostRecord);
      await controllerStream.startViewing(session.sessionId);
      await _waitUntil(() => controllerStream.snapshot.frame != null);
      await _waitUntil(() => controllerStream.snapshot.cursor != null);

      expect(controllerStream.snapshot.state.name, 'streaming');
      expect(controllerStream.snapshot.frame!.width, 640);
      expect(controllerStream.snapshot.cursor!.normalizedX, 0.5);
      expect(controllerStream.snapshot.cursor!.visible, isTrue);
      expect(capture.startCount, 1);

      await controllerStream.stopViewing();
      expect(controllerStream.snapshot.state.name, 'idle');
      expect(controllerStream.snapshot.cursor, isNull);
      expect(capture.stopCount, 1);
    },
  );

  test(
    'drops an expired pending frame and sends a fresh newest frame',
    () async {
      final controllerId =
          (await fixture.hostDevices.getPairedDevices()).single.id;
      await fixture.hostDevices.setScope(
        controllerId,
        AuthorizationScope.screenView,
        enabled: true,
      );
      final capture = _TestCaptureService()..emitFrames = false;
      final hostStream = ScreenStreamService(
        sessionService: fixture.host,
        pairedDevicesService: fixture.hostDevices,
        captureService: capture,
      );
      final controllerStream = ScreenStreamService(
        sessionService: fixture.controller,
        pairedDevicesService: fixture.controllerDevices,
        captureService: _TestCaptureService(),
      );
      addTearDown(hostStream.dispose);
      addTearDown(controllerStream.dispose);

      final session = await fixture.controller.connect(fixture.hostRecord);
      await controllerStream.startViewing(session.sessionId);
      capture.emitFrame(
        DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controllerStream.snapshot.frame, isNull);

      final freshTimestamp = DateTime.now().toUtc();
      capture.emitFrame(freshTimestamp);
      await _waitUntil(() => controllerStream.snapshot.frame != null);
      expect(
        controllerStream.snapshot.frame!.timestamp.millisecondsSinceEpoch,
        freshTimestamp.millisecondsSinceEpoch,
      );
    },
  );

  test('rejects requests when the host has not granted screen_view', () async {
    final capture = _TestCaptureService();
    final hostStream = ScreenStreamService(
      sessionService: fixture.host,
      pairedDevicesService: fixture.hostDevices,
      captureService: capture,
    );
    final controllerStream = ScreenStreamService(
      sessionService: fixture.controller,
      pairedDevicesService: fixture.controllerDevices,
      captureService: _TestCaptureService(),
    );
    addTearDown(hostStream.dispose);
    addTearDown(controllerStream.dispose);

    final session = await fixture.controller.connect(fixture.hostRecord);
    await expectLater(
      controllerStream.startViewing(session.sessionId),
      throwsA(isA<StateError>()),
    );
    expect(capture.startCount, 0);
  });

  test('rejects screen view for a revoked device', () async {
    final controllerId =
        (await fixture.hostDevices.getPairedDevices()).single.id;
    await fixture.hostDevices.setScope(
      controllerId,
      AuthorizationScope.screenView,
      enabled: true,
    );
    final capture = _TestCaptureService();
    final hostStream = ScreenStreamService(
      sessionService: fixture.host,
      pairedDevicesService: fixture.hostDevices,
      captureService: capture,
    );
    final controllerStream = ScreenStreamService(
      sessionService: fixture.controller,
      pairedDevicesService: fixture.controllerDevices,
      captureService: _TestCaptureService(),
    );
    addTearDown(hostStream.dispose);
    addTearDown(controllerStream.dispose);

    final session = await fixture.controller.connect(fixture.hostRecord);
    final controllerClosed = fixture.controller.closedSessions.first;
    await fixture.host.revokeDevice(controllerId);
    await controllerClosed.timeout(const Duration(seconds: 2));
    await expectLater(
      controllerStream.startViewing(session.sessionId),
      throwsA(isA<StateError>()),
    );
    expect(capture.startCount, 0);
  });

  test('disconnect releases host screen-capture resources', () async {
    final controllerId =
        (await fixture.hostDevices.getPairedDevices()).single.id;
    await fixture.hostDevices.setScope(
      controllerId,
      AuthorizationScope.screenView,
      enabled: true,
    );
    final capture = _TestCaptureService()
      ..cursorPosition = const RemoteCursorPosition(
        x: 320,
        y: 180,
        width: 640,
        height: 360,
        visible: true,
      );
    final hostStream = ScreenStreamService(
      sessionService: fixture.host,
      pairedDevicesService: fixture.hostDevices,
      captureService: capture,
    );
    final controllerStream = ScreenStreamService(
      sessionService: fixture.controller,
      pairedDevicesService: fixture.controllerDevices,
      captureService: _TestCaptureService(),
    );
    addTearDown(hostStream.dispose);
    addTearDown(controllerStream.dispose);

    final session = await fixture.controller.connect(fixture.hostRecord);
    await controllerStream.startViewing(session.sessionId);
    await _waitUntil(() => controllerStream.snapshot.cursor != null);
    await fixture.controller.disconnect();
    await _waitUntil(() => capture.stopCount == 1);
    expect(controllerStream.snapshot.cursor, isNull);
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(predicate(), isTrue);
}

class _TestCaptureService implements ScreenCaptureService {
  final _frames = StreamController<ScreenFrame>.broadcast();
  Timer? _timer;
  int startCount = 0;
  int stopCount = 0;
  int _sequence = 0;
  bool emitFrames = true;
  RemoteCursorPosition? cursorPosition = const RemoteCursorPosition(
    x: 0,
    y: 0,
    width: 640,
    height: 360,
    visible: false,
  );

  @override
  Stream<ScreenFrame> get frames => _frames.stream;

  @override
  Object? get lastError => null;

  @override
  Future<RemoteCursorPosition?> getCursorPosition() async => cursorPosition;

  @override
  Future<ScreenDimensions> startCapture() async {
    startCount++;
    if (emitFrames) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 25),
        (_) => emitFrame(DateTime.now().toUtc()),
      );
    }
    return const ScreenDimensions(width: 640, height: 360);
  }

  void emitFrame(DateTime timestamp) {
    _frames.add(
      ScreenFrame(
        sequence: _sequence++,
        timestamp: timestamp,
        width: 640,
        height: 360,
        format: ScreenFrameFormat.jpeg,
        keyFrame: true,
        encodedBytes: Uint8List.fromList([0xff, 0xd8, 1, 2, 0xff, 0xd9]),
      ),
    );
  }

  @override
  Future<void> stopCapture() async {
    stopCount++;
    _timer?.cancel();
    _timer = null;
  }
}

class _SessionFixture {
  final _LoopbackEndpoint endpoint = _LoopbackEndpoint();
  final InMemorySecureStorage hostStorage = InMemorySecureStorage();
  final InMemorySecureStorage controllerStorage = InMemorySecureStorage();
  late final SecurePairedDevicesService hostDevices;
  late final SecurePairedDevicesService controllerDevices;
  late final LanSessionService host;
  late final LanSessionService controller;
  late final PairedDevice hostRecord;

  Future<void> initialize() async {
    final hostIdentityService = CryptographicDeviceIdentityService(hostStorage);
    final controllerIdentityService = CryptographicDeviceIdentityService(
      controllerStorage,
    );
    final hostIdentity = await hostIdentityService.getOrCreateIdentity();
    final controllerIdentity = await controllerIdentityService
        .getOrCreateIdentity();
    hostDevices = SecurePairedDevicesService(hostStorage);
    controllerDevices = SecurePairedDevicesService(controllerStorage);
    hostRecord = PairedDevice(
      id: hostIdentity.id,
      name: 'Windows host',
      hostId: hostIdentity.id,
      publicKey: hostIdentity.publicKey,
      addedAt: DateTime.now().toUtc(),
    );
    await controllerDevices.addPairedDevice(hostRecord);
    await hostDevices.addPairedDevice(
      PairedDevice(
        id: controllerIdentity.id,
        name: 'Android controller',
        hostId: hostIdentity.id,
        publicKey: controllerIdentity.publicKey,
        addedAt: DateTime.now().toUtc(),
      ),
    );
    host = _createService(
      identityService: hostIdentityService,
      devices: hostDevices,
      transport: _LoopbackTransport(endpoint, isHost: true),
    );
    controller = _createService(
      identityService: controllerIdentityService,
      devices: controllerDevices,
      transport: _LoopbackTransport(endpoint, isHost: false),
    );
    await host.startHost();
  }

  LanSessionService _createService({
    required CryptographicDeviceIdentityService identityService,
    required SecurePairedDevicesService devices,
    required SessionTransport transport,
  }) => LanSessionService(
    identityService: identityService,
    pairedDevicesService: devices,
    transport: transport,
    authenticator: SignedSessionAuthenticator(
      identityService: identityService,
      keyManager: CryptographicSessionKeyManager(),
    ),
  );
}

class _RecordingRemoteInputService implements RemoteInputService {
  final commands = <String>[];
  final _commandStream = StreamController<String>.broadcast();

  Future<String> get nextCommand => _commandStream.stream.first;

  Future<void> close() => _commandStream.close();

  void _record(String command) {
    commands.add(command);
    _commandStream.add(command);
  }

  @override
  Future<void> movePointer(double x, double y) async => _record('move:$x:$y');

  @override
  Future<void> mouseButton(String button, String action) async =>
      _record('button:$button:$action');

  @override
  Future<void> scroll(int deltaX, int deltaY) async =>
      _record('scroll:$deltaX:$deltaY');

  @override
  Future<void> keyboardKey(String key, String action) async =>
      _record('key:$key:$action');

  @override
  Future<void> releaseAll() async => _record('releaseAll');
}

class _LoopbackEndpoint {
  final _incoming = StreamController<SessionWire>.broadcast();
  ServerSocket? _server;
  Socket? _controllerSocket;

  Stream<SessionWire> get incomingConnections => _incoming.stream;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((socket) => _incoming.add(JsonSocketSessionWire(socket)));
  }

  Future<SessionWire> connect() async {
    final server = _server;
    if (server == null) throw StateError('Host transport is not started.');
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    _controllerSocket = socket;
    return JsonSocketSessionWire(socket);
  }

  void dropControllerConnection() => _controllerSocket?.destroy();

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

class _LoopbackTransport implements SessionTransport {
  const _LoopbackTransport(this._endpoint, {required this.isHost});

  final _LoopbackEndpoint _endpoint;
  final bool isHost;

  @override
  Stream<SessionWire> get incomingConnections => _endpoint.incomingConnections;

  @override
  Future<void> startHost(String hostId) async {
    if (isHost) await _endpoint.start();
  }

  @override
  Future<SessionWire> connect(PairedDevice host) => _endpoint.connect();

  @override
  Future<void> stopHost() async {
    if (isHost) await _endpoint.stop();
  }
}
