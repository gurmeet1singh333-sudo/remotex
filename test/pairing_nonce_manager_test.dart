import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/services/pairing/pairing_nonce_manager.dart';

void main() {
  test('generates a fresh URL-safe 256-bit pairing nonce', () {
    final manager = PairingNonceManager(random: Random.secure());
    final nonce = manager.generate();

    expect(nonce, hasLength(43));
    expect(nonce, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(manager.currentNonce, nonce);
  });

  test('expires a pairing nonce at its configured deadline', () {
    var now = DateTime.utc(2026);
    final manager = PairingNonceManager(
      random: Random(1),
      clock: () => now,
      validity: const Duration(seconds: 5),
    );
    manager.generate();
    now = now.add(const Duration(seconds: 5));

    expect(manager.currentNonce, isNull);
    expect(manager.recordAttempt(true), PairingNonceValidation.expired);
  });

  test('invalidates pairing nonces and limits failed attempts', () {
    final manager = PairingNonceManager(random: Random(2), maximumAttempts: 3);
    final nonce = manager.generate();

    expect(manager.recordAttempt(false), PairingNonceValidation.invalid);
    expect(manager.recordAttempt(false), PairingNonceValidation.invalid);
    expect(manager.recordAttempt(false), PairingNonceValidation.locked);
    expect(manager.isLocked, isTrue);
    expect(manager.currentNonce, isNull);

    manager.generate();
    expect(manager.recordAttempt(true), PairingNonceValidation.valid);
    manager.invalidate();
    expect(manager.recordAttempt(true), PairingNonceValidation.invalidated);
    expect(manager.currentNonce, isNull);
    expect(nonce, isNotEmpty);
  });

  test('regeneration prevents using the previous pairing nonce', () {
    final manager = PairingNonceManager(random: Random(4));
    final previous = manager.generate();
    final current = manager.generate();

    expect(current, isNot(previous));
    expect(manager.recordAttempt(false), PairingNonceValidation.invalid);
    expect(manager.recordAttempt(true), PairingNonceValidation.valid);
  });
}
