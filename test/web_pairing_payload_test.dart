import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/web_pairing_payload.dart';

void main() {
  final now = DateTime.now().toUtc();
  final validPublicKey = base64Encode(List<int>.filled(32, 1));

  test('encodes and parses valid web pairing payload', () {
    final payload = WebPairingPayload(
      hostId: 'a' * 32,
      hostName: 'Test Desktop',
      hostPublicKey: validPublicKey,
      relayUrl: 'ws://127.0.0.1:8080',
      pairingNonce: 'B' * 43,
      sessionId: 'c' * 24,
      expiresAt: now.add(const Duration(minutes: 2)),
    );

    final encoded = payload.encode();
    final parsed = WebPairingPayload.parse(encoded, clock: () => now);

    expect(parsed.hostId, 'a' * 32);
    expect(parsed.hostName, 'Test Desktop');
    expect(parsed.hostPublicKey, validPublicKey);
    expect(parsed.relayUrl, 'ws://127.0.0.1:8080');
    expect(parsed.pairingNonce, 'B' * 43);
    expect(parsed.sessionId, 'c' * 24);
  });

  test('rejects expired web pairing payload', () {
    final expired = WebPairingPayload(
      hostId: 'a' * 32,
      hostName: 'Test Desktop',
      hostPublicKey: validPublicKey,
      relayUrl: 'ws://127.0.0.1:8080',
      pairingNonce: 'B' * 43,
      sessionId: 'c' * 24,
      expiresAt: now.subtract(const Duration(seconds: 1)),
    );

    expect(
      () => WebPairingPayload.parse(expired.encode(), clock: () => now),
      throwsFormatException,
    );
  });

  test('rejects invalid relay URL scheme', () {
    final invalid = jsonEncode({
      'type': 'remotex_web_pair',
      'version': 1,
      'protocolVersion': 1,
      'hostId': 'a' * 32,
      'hostName': 'Test Desktop',
      'hostPublicKey': validPublicKey,
      'relayUrl': 'http://127.0.0.1:8080',
      'pairingNonce': 'B' * 43,
      'sessionId': 'c' * 24,
      'expiresAt': now.add(const Duration(minutes: 2)).millisecondsSinceEpoch,
    });

    expect(
      () => WebPairingPayload.parse(invalid, clock: () => now),
      throwsFormatException,
    );
  });
}
