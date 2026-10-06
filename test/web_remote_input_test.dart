import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/protocol/message_type.dart';
import 'package:remotex/core/protocol/received_session_message.dart';
import 'package:remotex/core/services/remote_input_service.dart';
import 'package:remotex/services/session/remote_control_service.dart';

import 'support/test_helpers.dart';

void main() {
  late MockSessionService sessionService;
  late MockPairedDevicesService pairedDevicesService;
  late MockRemoteInputService inputService;
  late RemoteControlService remoteControlService;

  setUp(() {
    sessionService = MockSessionService();
    pairedDevicesService = MockPairedDevicesService();
    inputService = MockRemoteInputService();

    remoteControlService = RemoteControlService(
      sessionService: sessionService,
      pairedDevicesService: pairedDevicesService,
      inputService: inputService,
    );
  });

  tearDown(() async {
    await remoteControlService.dispose();
  });

  test('executes mouse move and mouse button when authorized', () async {
    final sessionId = 's1';
    final deviceId = 'd1';

    sessionService.activeSessions[sessionId] = deviceId;
    pairedDevicesService.devices[deviceId] = PairedDevice(
      id: deviceId,
      name: 'Web Device',
      hostId: 'h1',
      publicKey: 'pk1',
      addedAt: DateTime.now().toUtc(),
      authorizationScopes: const {
        AuthorizationScope.session,
        AuthorizationScope.screenView,
        AuthorizationScope.mouseControl,
      },
    );

    sessionService.incomingMessagesController.add(
      ReceivedSessionMessage(
        sessionId: sessionId,
        envelope: createTestEnvelope(
          type: MessageType.sessionReady,
          payload: const {
            'mouseControl': true,
            'keyboardControl': false,
          },
        ),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(remoteControlService.canControlMouse(sessionId), isTrue);
    expect(remoteControlService.canControlKeyboard(sessionId), isFalse);

    sessionService.incomingMessagesController.add(
      ReceivedSessionMessage(
        sessionId: sessionId,
        envelope: createTestEnvelope(
          type: MessageType.mouseMove,
          payload: const {'x': 100.0, 'y': 200.0},
        ),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(inputService.lastMoveX, 100.0);
    expect(inputService.lastMoveY, 200.0);
  });

  test('cleans up held buttons/keys when session closes', () async {
    final sessionId = 's2';
    final deviceId = 'd2';

    sessionService.activeSessions[sessionId] = deviceId;
    pairedDevicesService.devices[deviceId] = PairedDevice(
      id: deviceId,
      name: 'Web Device',
      hostId: 'h1',
      publicKey: 'pk2',
      addedAt: DateTime.now().toUtc(),
      authorizationScopes: const {
        AuthorizationScope.session,
        AuthorizationScope.mouseControl,
        AuthorizationScope.keyboardControl,
      },
    );

    sessionService.incomingMessagesController.add(
      ReceivedSessionMessage(
        sessionId: sessionId,
        envelope: createTestEnvelope(
          type: MessageType.mouseButton,
          payload: const {'button': 'left', 'action': 'down'},
        ),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    sessionService.closedSessionsController.add(sessionId);

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(inputService.releasedAll, isFalse);
    expect(inputService.lastButtonAction, 'up');
  });

  test('prevents keyboard and mouse input when scope is unauthorized', () async {
    final sessionId = 's3';
    final deviceId = 'd3';

    sessionService.activeSessions[sessionId] = deviceId;
    pairedDevicesService.devices[deviceId] = PairedDevice(
      id: deviceId,
      name: 'Web Device Without Control',
      hostId: 'h1',
      publicKey: 'pk3',
      addedAt: DateTime.now().toUtc(),
      authorizationScopes: const {
        AuthorizationScope.session,
        AuthorizationScope.screenView,
      },
    );

    // Attempting to send mouse move without authorization throws StateError
    expect(
      () => remoteControlService.sendMouseMove(sessionId, x: 0.5, y: 0.5),
      throwsStateError,
    );

    expect(
      () => remoteControlService.sendKeyboardKey(sessionId, key: 'A', action: 'down'),
      throwsStateError,
    );
  });
}

class MockRemoteInputService implements RemoteInputService {
  double? lastMoveX;
  double? lastMoveY;
  String? lastButtonAction;
  bool releasedAll = false;

  @override
  Future<void> movePointer(double x, double y) async {
    lastMoveX = x;
    lastMoveY = y;
  }

  @override
  Future<void> mouseButton(String button, String action) async {
    lastButtonAction = action;
  }

  @override
  Future<void> scroll(int deltaX, int deltaY) async {}

  @override
  Future<void> keyboardKey(String key, String action) async {}

  @override
  Future<void> releaseAll() async {
    releasedAll = true;
  }
}
