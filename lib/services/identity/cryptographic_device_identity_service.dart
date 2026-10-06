import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:remotex/core/models/device_identity.dart';
import 'package:remotex/core/services/device_identity_service.dart';
import 'package:remotex/core/services/secure_storage_service.dart';

class CryptographicDeviceIdentityService implements DeviceIdentityService {
  CryptographicDeviceIdentityService(
    this._storage, {
    Ed25519? signatureAlgorithm,
    HashAlgorithm? hashAlgorithm,
  }) : _signatureAlgorithm = signatureAlgorithm ?? Ed25519(),
       _hashAlgorithm = hashAlgorithm ?? Sha256();

  static const _privateSeedKey = 'remotex.identity.ed25519.seed.v1';
  static const _publicKeyKey = 'remotex.identity.ed25519.public.v1';
  static const _identityKey = 'remotex.identity.id.v1';

  final SecureStorageService _storage;
  final Ed25519 _signatureAlgorithm;
  final HashAlgorithm _hashAlgorithm;

  @override
  Future<DeviceIdentity> getOrCreateIdentity() async {
    var seed = await _storage.read(_privateSeedKey);
    var public = await _storage.read(_publicKeyKey);
    var id = await _storage.read(_identityKey);
    if (seed != null && public != null && id != null) {
      return DeviceIdentity(id: id, publicKey: public);
    }

    final keyPair = await _signatureAlgorithm.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicBytes = await keyPair.extractPublicKey();
    final publicKey = base64Encode(publicBytes.bytes);
    final digest = await _hashAlgorithm.hash(publicBytes.bytes);
    final deviceId = digest.bytes
        .take(16)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    seed = base64Encode(privateBytes);
    public = publicKey;
    id = deviceId;
    await _storage.write(_privateSeedKey, seed);
    await _storage.write(_publicKeyKey, public);
    await _storage.write(_identityKey, id);
    if (keyPair is SimpleKeyPairData) keyPair.destroy();
    return DeviceIdentity(id: id, publicKey: public);
  }

  @override
  Future<String> idForPublicKey(String publicKey) async {
    final bytes = base64Decode(publicKey);
    if (bytes.length != 32) {
      throw const FormatException('Invalid Ed25519 public key length.');
    }
    final digest = await _hashAlgorithm.hash(bytes);
    return digest.bytes
        .take(16)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  Future<List<int>> sign(List<int> message) async {
    final seed = await _storage.read(_privateSeedKey);
    if (seed == null) {
      throw StateError('Device identity has not been created.');
    }
    final keyPair = await _signatureAlgorithm.newKeyPairFromSeed(
      base64Decode(seed),
    );
    final signature = await _signatureAlgorithm.sign(message, keyPair: keyPair);
    if (keyPair is SimpleKeyPairData) keyPair.destroy();
    return signature.bytes;
  }

  @override
  Future<bool> verify({
    required String publicKey,
    required List<int> message,
    required List<int> signature,
  }) async {
    final decoded = base64Decode(publicKey);
    if (decoded.length != 32 || signature.length != 64) return false;
    return _signatureAlgorithm.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(decoded, type: KeyPairType.ed25519),
      ),
    );
  }

  @override
  Future<String> createProof(String secret, List<int> message) async {
    final mac = await Hmac.sha256().calculateMac(
      message,
      secretKey: SecretKey(utf8.encode(secret)),
    );
    return base64Encode(mac.bytes);
  }

  @override
  Future<bool> verifyProof({
    required String secret,
    required List<int> message,
    required String proof,
  }) async {
    final expected = await createProof(secret, message);
    final List<int> expectedBytes;
    final List<int> actualBytes;
    try {
      expectedBytes = base64Decode(expected);
      actualBytes = base64Decode(proof);
    } on FormatException {
      return false;
    }
    if (expectedBytes.length != actualBytes.length) return false;
    var difference = 0;
    for (var index = 0; index < expectedBytes.length; index++) {
      difference |= expectedBytes[index] ^ actualBytes[index];
    }
    return difference == 0;
  }
}
