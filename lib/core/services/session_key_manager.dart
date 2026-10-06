abstract interface class SessionKeyManager {
  Future<SessionEphemeralKey> createEphemeralKey();

  Future<SessionKeys> deriveKeys({
    required SessionEphemeralKey localKey,
    required String remotePublicKey,
    required List<int> salt,
    required List<int> context,
  });
}

class SessionEphemeralKey {
  const SessionEphemeralKey({
    required this.publicKey,
    required this.privateKeyHandle,
  });

  final String publicKey;
  final Object privateKeyHandle;
}

class SessionKeys {
  const SessionKeys({
    required this.controllerToHost,
    required this.hostToController,
    required this.confirmation,
  });

  final List<int> controllerToHost;
  final List<int> hostToController;
  final List<int> confirmation;
}
