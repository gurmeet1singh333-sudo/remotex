import 'package:remotex/core/models/remote_device.dart';

abstract interface class ConnectionService {
  Future<void> connect(RemoteDevice device);

  Future<void> disconnect();
}
