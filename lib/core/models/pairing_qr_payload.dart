import 'dart:convert';
import 'dart:io';

class PairingQrPayload {
  const PairingQrPayload({
    required this.hostId,
    required this.hostName,
    required this.hostPublicKey,
    required this.pairingNonce,
    required this.addresses,
    required this.port,
    required this.expiresAt,
    this.protocolVersion = pairingProtocolVersion,
  });

  static const type = 'remotex_pair';
  static const version = 1;
  static const pairingProtocolVersion = 1;
  static const maximumEncodedLength = 2048;

  final String hostId;
  final String hostName;
  final String hostPublicKey;
  final String pairingNonce;
  final List<String> addresses;
  final int port;
  final DateTime expiresAt;
  final int protocolVersion;

  String encode() => jsonEncode({
    'type': type,
    'version': version,
    'protocolVersion': protocolVersion,
    'hostId': hostId,
    'hostName': hostName,
    'hostPublicKey': hostPublicKey,
    'pairingNonce': pairingNonce,
    'addresses': addresses,
    'port': port,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
  });

  static PairingQrPayload parse(
    String encoded, {
    DateTime Function()? clock,
  }) {
    if (encoded.length > maximumEncodedLength) {
      throw const FormatException('Pairing QR payload is too large.');
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException('Pairing QR payload must be an object.');
    }
    final fields = Map<String, Object?>.from(decoded);
    if (fields['type'] != type) {
      throw const FormatException('This is not a RemoteX pairing QR code.');
    }
    if (fields['version'] != version) {
      throw const FormatException('Unsupported pairing QR version.');
    }
    final protocolVersion = fields['protocolVersion'];
    if (protocolVersion is! int ||
        protocolVersion != pairingProtocolVersion) {
      throw const FormatException('Unsupported pairing protocol version.');
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
    final pairingNonce = _requiredString(fields, 'pairingNonce');
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(pairingNonce)) {
      throw const FormatException('Invalid pairing session nonce.');
    }
    final rawAddresses = fields['addresses'];
    if (rawAddresses is! List ||
        rawAddresses.isEmpty ||
        rawAddresses.length > 8 ||
        rawAddresses.any((address) => address is! String)) {
      throw const FormatException('Invalid host network addresses.');
    }
    final addresses = rawAddresses.cast<String>();
    for (final address in addresses) {
      final parsed = InternetAddress.tryParse(address);
      if (parsed == null ||
          address != parsed.address ||
          !isLanAddress(parsed)) {
        throw const FormatException('Invalid host network address.');
      }
    }
    final port = fields['port'];
    if (port is! int || port < 1 || port > 65535) {
      throw const FormatException('Invalid host port.');
    }
    final expiry = fields['expiresAt'];
    if (expiry is! int || expiry < 0 || expiry > 8640000000000000) {
      throw const FormatException('Invalid pairing QR expiry.');
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiry, isUtc: true);
    final now = (clock ?? DateTime.now)().toUtc();
    if (!now.isBefore(expiresAt)) {
      throw const FormatException('Pairing QR code has expired.');
    }
    if (expiresAt.difference(now) > const Duration(minutes: 5)) {
      throw const FormatException('Pairing QR expiry is outside the valid window.');
    }

    return PairingQrPayload(
      hostId: hostId,
      hostName: hostName,
      hostPublicKey: hostPublicKey,
      pairingNonce: pairingNonce,
      addresses: List.unmodifiable(addresses),
      port: port,
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

  static bool isLanAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 127 ||
          bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168);
    }
    if (bytes.every((byte) => byte == 0) && bytes.last == 1) return true;
    return (bytes.first & 0xfe) == 0xfc;
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
