import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/app/remote_x_services.dart';
import 'package:remotex/app/remotex_app.dart';
import 'package:remotex/core/models/device_identity.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/authorization_change.dart';
import 'package:remotex/core/models/pairing_qr_payload.dart';
import 'package:remotex/core/models/remote_host.dart';
import 'package:remotex/core/services/device_identity_service.dart';
import 'package:remotex/core/services/discovery_service.dart';
import 'package:remotex/core/services/pairing_service.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/secure_storage_service.dart';
import 'package:remotex/core/models/session_info.dart';
import 'package:remotex/core/models/session_state.dart';
import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/services/session_service.dart';
import 'package:remotex/core/protocol/message_envelope.dart';
import 'package:remotex/core/protocol/message_type.dart';
import 'package:remotex/core/protocol/received_session_message.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/services/session/screen_stream_service.dart';
import 'package:remotex/services/session/remote_control_service.dart';
import 'package:remotex/services/session/windows_remote_input_service.dart';
import 'package:remotex/services/session/windows_screen_capture_service.dart';

void main() {
  testWidgets('Android shows the controller home screen', (tester) async {
    await tester.pumpWidget(
      RemoteXApp(
        targetPlatform: TargetPlatform.android,
        services: _fakeServices(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('RemoteX'), findsOneWidget);
    expect(find.text('Connection status'), findsOneWidget);
    expect(find.text('Add / Pair Laptop'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('No laptops paired'), findsOneWidget);
  });

  testWidgets('Windows shows host status and pairing controls', (tester) async {
    await tester.pumpWidget(
      RemoteXApp(
        targetPlatform: TargetPlatform.windows,
        services: _fakeServices(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('RemoteX Host'), findsOneWidget);
    expect(find.text('Host status'), findsOneWidget);
    expect(find.text('Test Laptop'), findsOneWidget);
    expect(find.text('Pair New Device'), findsOneWidget);
    expect(find.text('Stop hosting'), findsOneWidget);
    await tester.ensureVisible(find.text('Pairing'));
    expect(find.text('Pairing'), findsOneWidget);
    await tester.ensureVisible(find.text('Pair New Device'));
    await tester.tap(find.text('Pair New Device'));
    await tester.pumpAndSettle();
    expect(
      find.text('Scan this QR code with RemoteX on your phone.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('LAN endpoint'));
    await tester.pumpAndSettle();
    expect(find.text('LAN endpoint'), findsOneWidget);
    expect(find.text('192.168.1.10:5555'), findsOneWidget);
    await tester.ensureVisible(find.text('Regenerate QR'));
    await tester.pumpAndSettle();
    expect(find.text('Regenerate QR'), findsOneWidget);
    await tester.ensureVisible(find.text('Cancel QR'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel QR'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Pair New Device'));
    await tester.pumpAndSettle();
    expect(find.text('Pair New Device'), findsOneWidget);
  });
}

RemoteXServices _fakeServices() {
  final identity = _FakeIdentityService();
  final paired = _FakePairedDevicesService();
  final pairing = _FakePairingService();
  final hostPairing = _FakeHostPairingService();
  final session = _FakeSessionService(paired);
  return RemoteXServices(
    discoveryService: _FakeDiscoveryService(),
    pairingService: pairing,
    hostPairingService: hostPairing,
    identityService: identity,
    pairedDevicesService: paired,
    secureStorageService: _FakeSecureStorageService(),
    sessionService: session,
    screenStreamService: ScreenStreamService(
      sessionService: session,
      pairedDevicesService: paired,
      captureService: UnavailableScreenCaptureService(),
    ),
    remoteControlService: RemoteControlService(
      sessionService: session,
      pairedDevicesService: paired,
      inputService: UnavailableRemoteInputService(),
    ),
  );
}

class _FakeDiscoveryService implements DiscoveryService {
  @override
  Stream<List<RemoteHost>> get discoveredHosts => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _FakePairingService implements PairingService {
  @override
  Future<PairedDevice> pair(PairingQrPayload payload) async => PairedDevice(
    id: payload.hostId,
    hostId: payload.hostId,
    name: payload.hostName,
    publicKey: 'public-key',
    addedAt: DateTime.utc(2026),
  );

  @override
  Future<void> cancelPairing() async {}
}

class _FakeHostPairingService implements HostPairingService {
  HostPairingStatus _status = HostPairingStatus(
    hostName: 'Test Laptop',
    hostId: 'host-id',
    hostPublicKey: 'public-key',
    port: 5555,
    addresses: const ['192.168.1.10'],
    isRunning: true,
  );

  @override
  HostPairingStatus get status => _status;

  @override
  Stream<HostPairingStatus> get statusChanges => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> startPairingSession() async {
    _status = _status.copyWith(
      pairingNonce: 'A' * 43,
      expiresAt: DateTime.now().add(const Duration(minutes: 2)),
    );
  }

  @override
  Future<void> cancelPairingSession() async {
    _status = _status.copyWith(clearPairingSession: true);
  }

  @override
  Future<void> stop() async {
    _status = _status.copyWith(isRunning: false, clearPairingSession: true);
  }
}

class _FakeIdentityService implements DeviceIdentityService {
  @override
  Future<String> createProof(String secret, List<int> message) async => '';

  @override
  Future<DeviceIdentity> getOrCreateIdentity() async =>
      const DeviceIdentity(id: 'identity-id', publicKey: 'public-key');

  @override
  Future<String> idForPublicKey(String publicKey) async => 'identity-id';

  @override
  Future<List<int>> sign(List<int> message) async => const [];

  @override
  Future<bool> verify({
    required String publicKey,
    required List<int> message,
    required List<int> signature,
  }) async => true;

  @override
  Future<bool> verifyProof({
    required String secret,
    required List<int> message,
    required String proof,
  }) async => true;
}

class _FakePairedDevicesService implements PairedDevicesService {
  @override
  Future<void> addPairedDevice(PairedDevice device) async {}

  @override
  Future<bool> isRevoked(String deviceId) async => false;

  @override
  Future<void> removePairedDevice(String deviceId) async {}

  @override
  Future<void> revokePairedDevice(String deviceId) async {}

  @override
  Future<bool> contains(String deviceId) async => false;

  @override
  Future<List<PairedDevice>> getPairedDevices() async => const [];

  @override
  Future<void> setScope(
    String deviceId,
    AuthorizationScope scope, {
    required bool enabled,
  }) async {}
}

class _FakeSessionService implements SessionService {
  _FakeSessionService(this._pairedDevices);

  final _FakePairedDevicesService _pairedDevices;

  @override
  Stream<SessionState> get stateChanges => const Stream.empty();

  @override
  Stream<ReceivedSessionMessage> get incomingMessages => const Stream.empty();

  @override
  Stream<ReceivedScreenFrame> get incomingFrames => const Stream.empty();

  @override
  Stream<String> get closedSessions => const Stream.empty();

  @override
  Stream<AuthorizationChange> get authorizationChanges => const Stream.empty();

  @override
  SessionState get state => SessionState.disconnected;

  @override
  String? get controllerSessionId => null;

  @override
  Future<SessionInfo> connect(PairedDevice host) async => SessionInfo(
    sessionId: 'session',
    deviceId: host.id,
    deviceName: host.name,
    state: SessionState.connected,
    establishedAt: DateTime.utc(2026),
  );

  @override
  Future<void> sendMessage(
    String sessionId,
    MessageType type, {
    Map<String, Object?> payload = const {},
  }) async {}

  @override
  Future<MessageEnvelope> request(
    String sessionId,
    MessageType type, {
    Map<String, Object?> payload = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async => throw UnimplementedError();

  @override
  Future<void> respond(
    String sessionId,
    MessageEnvelope request, {
    required MessageType type,
    Map<String, Object?> payload = const {},
  }) async {}

  @override
  Future<void> sendFrame(String sessionId, ScreenFrame frame) async {}

  @override
  Future<void> grantSessionScope(
    String sessionId,
    AuthorizationScope scope,
  ) async {}

  @override
  Future<void> revokeSessionScope(
    String sessionId,
    AuthorizationScope scope,
  ) async {}

  @override
  bool isSessionActive(String sessionId) => false;

  @override
  String? peerIdForSession(String sessionId) => null;

  @override
  Future<void> setDeviceScope(
    String deviceId,
    AuthorizationScope scope, {
    required bool enabled,
  }) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<PairedDevice>> getTrustedDevices() =>
      _pairedDevices.getPairedDevices();

  @override
  Future<void> revokeDevice(String deviceId) async {}

  @override
  Future<void> startHost() async {}

  @override
  Future<void> stopHost() async {}
}

class _FakeSecureStorageService implements SecureStorageService {
  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}
}
