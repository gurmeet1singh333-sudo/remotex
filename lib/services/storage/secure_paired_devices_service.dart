import 'dart:convert';

import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/services/paired_devices_service.dart';
import 'package:remotex/core/services/secure_storage_service.dart';

class SecurePairedDevicesService implements PairedDevicesService {
  SecurePairedDevicesService(this._storage);

  static const _storageKey = 'remotex.paired_devices.v1';
  static const _revokedStorageKey = 'remotex.revoked_devices.v1';

  final SecureStorageService _storage;

  @override
  Future<List<PairedDevice>> getPairedDevices() async {
    final json = await _storage.read(_storageKey);
    if (json == null) return const [];
    final items = jsonDecode(json) as List<Object?>;
    return items
        .map(
          (item) =>
              PairedDevice.fromJson(Map<String, Object?>.from(item! as Map)),
        )
        .toList(growable: false);
  }

  @override
  Future<void> addPairedDevice(PairedDevice device) async {
    final devices = (await getPairedDevices()).toList();
    if (devices.any((saved) => saved.id == device.id)) {
      throw StateError('This device is already paired.');
    }
    await _storage.write(
      _storageKey,
      jsonEncode([...devices, device].map((item) => item.toJson()).toList()),
    );
    final revoked = await _getRevokedIds();
    if (revoked.remove(device.id)) {
      await _storage.write(_revokedStorageKey, jsonEncode(revoked.toList()));
    }
  }

  @override
  Future<void> removePairedDevice(String deviceId) async {
    final devices = (await getPairedDevices()).toList();
    final remaining = devices.where((device) => device.id != deviceId).toList();
    if (remaining.length == devices.length) return;
    await _storage.write(
      _storageKey,
      jsonEncode(remaining.map((item) => item.toJson()).toList()),
    );
  }

  @override
  Future<void> revokePairedDevice(String deviceId) async {
    final devices = await getPairedDevices();
    final target = devices.where((device) => device.id == deviceId).firstOrNull;
    if (target == null) return;
    await removePairedDevice(deviceId);
    final revoked = await _getRevokedIds();
    revoked.add(deviceId);
    await _storage.write(_revokedStorageKey, jsonEncode(revoked.toList()));
  }

  @override
  Future<bool> isRevoked(String deviceId) async =>
      (await _getRevokedIds()).contains(deviceId);

  Future<Set<String>> _getRevokedIds() async {
    final json = await _storage.read(_revokedStorageKey);
    if (json == null) return {};
    return (jsonDecode(json) as List<Object?>).cast<String>().toSet();
  }

  @override
  Future<bool> contains(String deviceId) async =>
      (await getPairedDevices()).any((device) => device.id == deviceId);

  @override
  Future<void> setScope(
    String deviceId,
    AuthorizationScope scope, {
    required bool enabled,
  }) async {
    if (scope == AuthorizationScope.session) {
      throw ArgumentError.value(scope, 'scope', 'Session scope is mandatory.');
    }
    final devices = (await getPairedDevices()).toList();
    final index = devices.indexWhere((device) => device.id == deviceId);
    if (index < 0) throw StateError('Paired device is not trusted.');
    final device = devices[index];
    final scopes = {...device.authorizationScopes};
    if (enabled) {
      scopes.add(scope);
    } else {
      scopes.remove(scope);
    }
    devices[index] = PairedDevice(
      id: device.id,
      name: device.name,
      hostId: device.hostId,
      publicKey: device.publicKey,
      addedAt: device.addedAt,
      authorizationScopes: scopes,
    );
    await _storage.write(
      _storageKey,
      jsonEncode(devices.map((item) => item.toJson()).toList()),
    );
  }
}
