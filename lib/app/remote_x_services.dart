import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:remotex/core/services/device_identity_service.dart';
import 'package:remotex/core/services/discovery_service.dart';
import 'package:remotex/core/services/pairing_service.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/secure_storage_service.dart';
import 'package:remotex/core/services/session_service.dart';
import 'package:remotex/services/session/screen_stream_service.dart';
import 'package:remotex/services/discovery/bonjour_discovery_service.dart';
import 'package:remotex/services/identity/cryptographic_device_identity_service.dart';
import 'package:remotex/services/pairing/lan_pairing_service.dart';
import 'package:remotex/services/pairing/web_pairing_service.dart';
import 'package:remotex/services/relay/web_relay_host_client.dart';
import 'package:remotex/services/storage/platform_secure_storage_service.dart';
import 'package:remotex/services/storage/secure_paired_devices_service.dart';
import 'package:remotex/services/session/cryptographic_session_key_manager.dart';
import 'package:remotex/services/session/lan_session_service.dart';
import 'package:remotex/services/session/lan_session_transport.dart';
import 'package:remotex/services/session/signed_session_authenticator.dart';
import 'package:remotex/services/session/windows_screen_capture_service.dart';
import 'package:remotex/core/services/screen_capture_service.dart';
import 'package:remotex/core/services/remote_input_service.dart';
import 'package:remotex/services/session/remote_control_service.dart';
import 'package:remotex/services/session/windows_remote_input_service.dart';

class RemoteXServices {
  const RemoteXServices({
    required this.discoveryService,
    required this.pairingService,
    required this.hostPairingService,
    required this.identityService,
    required this.pairedDevicesService,
    required this.secureStorageService,
    required this.sessionService,
    required this.screenStreamService,
    required this.remoteControlService,
    this.webPairingService,
    this.relayHostClient,
  });

  factory RemoteXServices.create() {
    final SecureStorageService storage = PlatformSecureStorageService(
      storage: const FlutterSecureStorage(),
    );
    final DeviceIdentityService identity = CryptographicDeviceIdentityService(
      storage,
    );
    final PairedDevicesService pairedDevices = SecurePairedDevicesService(
      storage,
    );
    final pairing = LanPairingService(
      identityService: identity,
      pairedDevicesService: pairedDevices,
    );
    final sessionService = LanSessionService(
      identityService: identity,
      pairedDevicesService: pairedDevices,
      transport: LanSessionTransport(),
      authenticator: SignedSessionAuthenticator(
        identityService: identity,
        keyManager: CryptographicSessionKeyManager(),
      ),
    );
    final ScreenCaptureService screenCapture =
        defaultTargetPlatform == TargetPlatform.windows
            ? WindowsScreenCaptureService()
            : UnavailableScreenCaptureService();
    final screenStreamService = ScreenStreamService(
      sessionService: sessionService,
      pairedDevicesService: pairedDevices,
      captureService: screenCapture,
    );
    final RemoteInputService remoteInput =
        defaultTargetPlatform == TargetPlatform.windows
            ? WindowsRemoteInputService()
            : UnavailableRemoteInputService();
    final remoteControlService = RemoteControlService(
      sessionService: sessionService,
      pairedDevicesService: pairedDevices,
      inputService: remoteInput,
    );
    final webPairingService = WebPairingService(
      identityService: identity,
      pairedDevicesService: pairedDevices,
    );
    final relayHostClient = WebRelayHostClient(
      identityService: identity,
    );
    return RemoteXServices(
      discoveryService: BonjourDiscoveryService(),
      pairingService: pairing,
      hostPairingService: pairing,
      identityService: identity,
      pairedDevicesService: pairedDevices,
      secureStorageService: storage,
      sessionService: sessionService,
      screenStreamService: screenStreamService,
      remoteControlService: remoteControlService,
      webPairingService: webPairingService,
      relayHostClient: relayHostClient,
    );
  }

  final DiscoveryService discoveryService;
  final PairingService pairingService;
  final HostPairingService hostPairingService;
  final DeviceIdentityService identityService;
  final PairedDevicesService pairedDevicesService;
  final SecureStorageService secureStorageService;
  final SessionService sessionService;
  final ScreenStreamService screenStreamService;
  final RemoteControlService remoteControlService;
  final WebPairingService? webPairingService;
  final WebRelayHostClient? relayHostClient;
}
