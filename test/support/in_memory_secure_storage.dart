import 'package:remotex/core/services/secure_storage_service.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/services/paired_devices_service.dart';

class InMemorySecureStorage implements SecureStorageService {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class InMemoryPairedDevicesService implements PairedDevicesService {
  final devices = <String, PairedDevice>{};
  final revokedIds = <String>{};

  @override
  Future<void> addPairedDevice(PairedDevice device) async {
    devices[device.id] = device;
    revokedIds.remove(device.id);
  }

  @override
  Future<bool> contains(String deviceId) async => devices.containsKey(deviceId);

  @override
  Future<List<PairedDevice>> getPairedDevices() async =>
      List.unmodifiable(devices.values);

  @override
  Future<bool> isRevoked(String deviceId) async =>
      revokedIds.contains(deviceId);

  @override
  Future<void> removePairedDevice(String deviceId) async {
    devices.remove(deviceId);
  }

  @override
  Future<void> revokePairedDevice(String deviceId) async {
    if (devices.remove(deviceId) != null) revokedIds.add(deviceId);
  }

  @override
  Future<void> setScope(
    String deviceId,
    AuthorizationScope scope, {
    required bool enabled,
  }) async {
    final device = devices[deviceId];
    if (device == null) throw StateError('Paired device is not trusted.');
    final scopes = {...device.authorizationScopes};
    if (enabled) {
      scopes.add(scope);
    } else {
      scopes.remove(scope);
    }
    devices[deviceId] = PairedDevice(
      id: device.id,
      name: device.name,
      hostId: device.hostId,
      publicKey: device.publicKey,
      addedAt: device.addedAt,
      authorizationScopes: scopes,
    );
  }
}
