import 'package:remotex/core/models/device_identity.dart';

abstract interface class DeviceIdentityService {
  Future<DeviceIdentity> getOrCreateIdentity();

  Future<String> idForPublicKey(String publicKey);

  Future<List<int>> sign(List<int> message);

  Future<bool> verify({
    required String publicKey,
    required List<int> message,
    required List<int> signature,
  });

  Future<String> createProof(String secret, List<int> message);

  Future<bool> verifyProof({
    required String secret,
    required List<int> message,
    required String proof,
  });
}
