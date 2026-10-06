import 'package:remotex/core/models/remote_host.dart';

abstract interface class DiscoveryService {
  Stream<List<RemoteHost>> get discoveredHosts;

  Future<void> start();

  Future<void> stop();
}
