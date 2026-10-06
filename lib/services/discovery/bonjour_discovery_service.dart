import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:remotex/core/models/remote_host.dart';
import 'package:remotex/core/services/discovery_service.dart';

class BonjourDiscoveryService implements DiscoveryService {
  static const serviceType = '_remotex._tcp';
  static const serviceIdentifier = 'remotex';
  static const protocolVersion = 1;

  final _hosts = <String, RemoteHost>{};
  final _hostsController = StreamController<List<RemoteHost>>.broadcast();
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;

  @override
  Stream<List<RemoteHost>> get discoveredHosts => _hostsController.stream;

  @override
  Future<void> start() async {
    if (_discovery != null) return;
    _hosts.clear();
    final discovery = BonsoirDiscovery(type: serviceType, printLogs: false);
    await discovery.initialize();
    final events = discovery.eventStream;
    if (events == null) {
      throw StateError('LAN discovery did not provide an event stream.');
    }
    _subscription = events.listen(
      _handleEvent,
      onError: _hostsController.addError,
    );
    _discovery = discovery;
    await discovery.start();
  }

  void _handleEvent(BonsoirDiscoveryEvent event) {
    final service = event.service;
    if (service == null) return;
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      unawaited(service.resolve(_discovery!.serviceResolver));
      return;
    }
    if (event is BonsoirDiscoveryServiceLostEvent) {
      _hosts.remove(service.attributes['hostId']);
      _emit();
      return;
    }
    if (event is! BonsoirDiscoveryServiceResolvedEvent &&
        event is! BonsoirDiscoveryServiceUpdatedEvent) {
      return;
    }
    final attributes = service.attributes;
    if (attributes['service'] != serviceIdentifier ||
        attributes['version'] != '$protocolVersion' ||
        service.hostAddresses.isEmpty) {
      return;
    }
    final hostId = attributes['hostId'];
    if (hostId == null || hostId.isEmpty || service.port <= 0) return;
    _hosts[hostId] = RemoteHost(
      id: hostId,
      name: service.name,
      port: service.port,
      protocolVersion: protocolVersion,
      addresses: List.unmodifiable(service.hostAddresses),
    );
    _emit();
  }

  void _emit() {
    _hostsController.add(List.unmodifiable(_hosts.values));
  }

  @override
  Future<void> stop() async {
    final discovery = _discovery;
    if (discovery == null) return;
    _discovery = null;
    await discovery.stop();
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> dispose() async {
    await stop();
    await _hostsController.close();
  }
}
