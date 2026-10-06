import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/pairing_qr_payload.dart';

void main() {
  final validPayload = PairingQrPayload(
    hostId: '0123456789abcdef0123456789abcdef',
    hostName: 'Test Laptop',
    hostPublicKey: base64Encode(List<int>.generate(32, (index) => index)),
    pairingNonce: base64UrlEncode(List<int>.generate(32, (index) => index))
        .replaceAll('=', ''),
    addresses: const ['192.168.1.20', '127.0.0.1'],
    port: 45678,
    expiresAt: DateTime.utc(2026, 1, 1, 0, 2),
  );

  test('encodes and parses a versioned RemoteX pairing QR payload', () {
    final parsed = PairingQrPayload.parse(
      validPayload.encode(),
      clock: () => DateTime.utc(2026, 1, 1),
    );

    expect(parsed.hostId, validPayload.hostId);
    expect(parsed.hostName, validPayload.hostName);
    expect(parsed.hostPublicKey, validPayload.hostPublicKey);
    expect(parsed.pairingNonce, validPayload.pairingNonce);
    expect(parsed.addresses, validPayload.addresses);
    expect(parsed.port, validPayload.port);
    expect(parsed.expiresAt, validPayload.expiresAt);
  });

  test('rejects malformed, oversized, and non-RemoteX payloads', () {
    expect(
      () => PairingQrPayload.parse('{not-json'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => PairingQrPayload.parse('x' * 2049),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => PairingQrPayload.parse('{"type":"not_remotex","version":1}'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => PairingQrPayload.parse('[]'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects unsupported versions and missing required fields', () {
    final fields = jsonDecode(validPayload.encode()) as Map<String, Object?>;
    expect(
      () => PairingQrPayload.parse(
        jsonEncode({...fields, 'version': 2}),
        clock: () => DateTime.utc(2026, 1, 1),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => PairingQrPayload.parse(
        jsonEncode({...fields, 'protocolVersion': 2}),
        clock: () => DateTime.utc(2026, 1, 1),
      ),
      throwsA(isA<FormatException>()),
    );
    fields.remove('hostName');
    expect(
      () => PairingQrPayload.parse(
        jsonEncode(fields),
        clock: () => DateTime.utc(2026, 1, 1),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects invalid identity, nonce, address, port, and expiry', () {
    final fields = jsonDecode(validPayload.encode()) as Map<String, Object?>;
    final now = DateTime.utc(2026, 1, 1);
    for (final invalid in [
      {...fields, 'hostPublicKey': 'not-a-key'},
      {...fields, 'pairingNonce': 'too-short'},
      {...fields, 'hostId': 'invalid'},
      {...fields, 'addresses': ['not-an-ip-address']},
      {...fields, 'addresses': ['8.8.8.8']},
      {...fields, 'port': 65536},
      {...fields, 'expiresAt': now.millisecondsSinceEpoch},
    ]) {
      expect(
        () => PairingQrPayload.parse(
          jsonEncode(invalid),
          clock: () => now,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
