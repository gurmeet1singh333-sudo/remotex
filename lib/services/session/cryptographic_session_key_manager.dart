import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:remotex/core/services/session_key_manager.dart';

class CryptographicSessionKeyManager implements SessionKeyManager {
  CryptographicSessionKeyManager({X25519? keyExchange, Hkdf? keyDerivation})
    : _keyExchange = keyExchange ?? X25519(),
      _keyDerivation =
          keyDerivation ?? Hkdf(hmac: Hmac.sha256(), outputLength: 96);

  final X25519 _keyExchange;
  final Hkdf _keyDerivation;

  @override
  Future<SessionEphemeralKey> createEphemeralKey() async {
    final keyPair = await _keyExchange.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return SessionEphemeralKey(
      publicKey: base64Encode(publicKey.bytes),
      privateKeyHandle: keyPair,
    );
  }

  @override
  Future<SessionKeys> deriveKeys({
    required SessionEphemeralKey localKey,
    required String remotePublicKey,
    required List<int> salt,
    required List<int> context,
  }) async {
    final localPair = localKey.privateKeyHandle;
    if (localPair is! SimpleKeyPair) {
      throw StateError('Invalid ephemeral key handle.');
    }
    final remoteBytes = base64Decode(remotePublicKey);
    if (remoteBytes.length != 32) {
      throw const FormatException('Invalid X25519 public key.');
    }
    final sharedSecret = await _keyExchange.sharedSecretKey(
      keyPair: localPair,
      remotePublicKey: SimplePublicKey(remoteBytes, type: KeyPairType.x25519),
    );
    final derived = await _keyDerivation.deriveKey(
      secretKey: sharedSecret,
      nonce: salt,
      info: context,
    );
    final bytes = await derived.extractBytes();
    if (localPair is SimpleKeyPairData) localPair.destroy();
    return SessionKeys(
      controllerToHost: List.unmodifiable(bytes.sublist(0, 32)),
      hostToController: List.unmodifiable(bytes.sublist(32, 64)),
      confirmation: List.unmodifiable(bytes.sublist(64, 96)),
    );
  }
}
