import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/models/paired_device.dart';

abstract interface class PairedDevicesService {
  Future<List<PairedDevice>> getPairedDevices();

  Future<void> addPairedDevice(PairedDevice device);

  Future<void> removePairedDevice(String deviceId);

  Future<void> revokePairedDevice(String deviceId);

  Future<bool> isRevoked(String deviceId);

  Future<bool> contains(String deviceId);

  Future<void> setScope(
    String deviceId,
    AuthorizationScope scope, {
    required bool enabled,
  });
}
