import 'dart:convert';

class WebPairingPayload {
  const WebPairingPayload({
    required this.hostId,
    required this.hostName,
    required this.hostPublicKey,
    required this.relayUrl,
    required this.pairingNonce,
    required this.sessionId,
    required this.expiresAt,
    this.protocolVersion = webPairingProtocolVersion,
  });

  static const type = 'remotex_web_pair';
  static const version = 1;
  static const webPairingProtocolVersion = 1;
  static const maximumEncodedLength = 2048;

  final String hostId;
  final String hostName;
  final String hostPublicKey;
  final String relayUrl;
  final String pairingNonce;
  final String sessionId;
  final DateTime expiresAt;
  final int protocolVersion;

  String encode() => jsonEncode({
    'type': type,
    'version': version,
    'protocolVersion': protocolVersion,
    'hostId': hostId,
    'hostName': hostName,
    'hostPublicKey': hostPublicKey,
    'relayUrl': relayUrl,
    'pairingNonce': pairingNonce,
    'sessionId': sessionId,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
  });

  static WebPairingPayload parse(
    String encoded, {
    DateTime Function()? clock,
    bool isProduction = false,
  }) {
    if (encoded.length > maximumEncodedLength) {
      throw const FormatException('Web pairing payload is too large.');
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException('Web pairing payload must be an object.');
    }
    final fields = Map<String, Object?>.from(decoded);
    if (fields['type'] != type) {
      throw const FormatException('This is not a RemoteX web pairing QR code.');
    }
    if (fields['version'] != version) {
      throw const FormatException('Unsupported web pairing QR version.');
    }
    final protocolVersion = fields['protocolVersion'];
    if (protocolVersion is! int ||
        protocolVersion != webPairingProtocolVersion) {
      throw const FormatException('Unsupported web pairing protocol version.');
    }

    final hostId = _requiredString(fields, 'hostId');
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(hostId)) {
      throw const FormatException('Invalid host identity.');
    }
    final hostName = _requiredString(fields, 'hostName');
    if (hostName.length > 80) {
      throw const FormatException('Invalid host name.');
    }
    final hostPublicKey = _requiredString(fields, 'hostPublicKey');
    final publicKeyBytes = _decodeCanonicalBase64(hostPublicKey);
    if (publicKeyBytes.length != 32) {
      throw const FormatException('Invalid host public key.');
    }
    final relayUrl = _requiredString(fields, 'relayUrl');
    final parsedUri = Uri.tryParse(relayUrl);
    if (parsedUri == null ||
        (!parsedUri.isScheme('ws') && !parsedUri.isScheme('wss')) ||
        parsedUri.host.isEmpty) {
      throw const FormatException('Invalid relay URL.');
    }
    if (isProduction &&
        parsedUri.isScheme('ws') &&
        parsedUri.host != '127.0.0.1' &&
        parsedUri.host != 'localhost') {
      throw const FormatException(
        'Insecure ws:// scheme is not permitted for remote relay in production; use wss://',
      );
    }
    final pairingNonce = _requiredString(fields, 'pairingNonce');
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(pairingNonce)) {
      throw const FormatException('Invalid web pairing session nonce.');
    }
    final sessionId = _requiredString(fields, 'sessionId');
    if (!RegExp(r'^[0-9a-f]{24,32}$').hasMatch(sessionId)) {
      throw const FormatException('Invalid web pairing session ID.');
    }

    final expiry = fields['expiresAt'];
    if (expiry is! int || expiry < 0 || expiry > 8640000000000000) {
      throw const FormatException('Invalid web pairing QR expiry.');
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiry, isUtc: true);
    final now = (clock ?? DateTime.now)().toUtc();
    if (!now.isBefore(expiresAt)) {
      throw const FormatException('Web pairing QR code has expired.');
    }
    if (expiresAt.difference(now) > const Duration(minutes: 5)) {
      throw const FormatException('Web pairing expiry is outside the valid window.');
    }

    return WebPairingPayload(
      hostId: hostId,
      hostName: hostName,
      hostPublicKey: hostPublicKey,
      relayUrl: relayUrl,
      pairingNonce: pairingNonce,
      sessionId: sessionId,
      expiresAt: expiresAt,
      protocolVersion: protocolVersion,
    );
  }

  static String _requiredString(Map<String, Object?> fields, String key) {
    final value = fields[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing or invalid $key.');
    }
    return value;
  }

  static List<int> _decodeCanonicalBase64(String value) {
    try {
      final bytes = base64Decode(value);
      if (base64Encode(bytes) != value) {
        throw const FormatException('Non-canonical base64 value.');
      }
      return bytes;
    } on FormatException {
      throw const FormatException('Invalid host public key.');
    }
  }
}
