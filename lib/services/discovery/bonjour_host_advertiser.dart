import 'package:bonsoir/bonsoir.dart';
import 'package:remotex/services/discovery/bonjour_discovery_service.dart';

abstract interface class HostAdvertiser {
  Future<void> start({
    required String hostId,
    required String hostName,
    required int port,
  });

  Future<void> stop();
}

class BonjourHostAdvertiser implements HostAdvertiser {
  BonsoirBroadcast? _broadcast;

  @override
  Future<void> start({
    required String hostId,
    required String hostName,
    required int port,
  }) async {
    if (_broadcast != null) return;
    final broadcast = BonsoirBroadcast(
      printLogs: false,
      service: BonsoirService(
        name: hostName,
        type: BonjourDiscoveryService.serviceType,
        port: port,
        attributes: {
          'service': BonjourDiscoveryService.serviceIdentifier,
          'hostId': hostId,
          'version': '${BonjourDiscoveryService.protocolVersion}',
        },
      ),
    );
    await broadcast.initialize();
    _broadcast = broadcast;
    await broadcast.start();
  }

  @override
  Future<void> stop() async {
    final broadcast = _broadcast;
    if (broadcast == null) return;
    _broadcast = null;
    await broadcast.stop();
  }
}
