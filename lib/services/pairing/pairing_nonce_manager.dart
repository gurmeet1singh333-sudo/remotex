import 'dart:convert';
import 'dart:math';

enum PairingNonceValidation { valid, invalid, expired, locked, invalidated }

class PairingNonceManager {
  PairingNonceManager({
    DateTime Function()? clock,
    Random? random,
    this.validity = const Duration(minutes: 2),
    this.maximumAttempts = 5,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final DateTime Function() _clock;
  final Random _random;
  final Duration validity;
  final int maximumAttempts;

  String? _nonce;
  DateTime? _expiresAt;
  int _failedAttempts = 0;
  bool _locked = false;

  String? get currentNonce => _isExpired ? null : _nonce;

  DateTime? get expiresAt => _isExpired ? null : _expiresAt;

  int get failedAttempts => _failedAttempts;

  bool get isLocked => _locked;

  String generate() {
    _nonce = base64UrlEncode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    _expiresAt = _clock().add(validity);
    _failedAttempts = 0;
    _locked = false;
    return _nonce!;
  }

  PairingNonceValidation recordAttempt(bool matched) {
    if (_locked) return PairingNonceValidation.locked;
    if (_nonce == null) return PairingNonceValidation.invalidated;
    if (_isExpired) {
      invalidate();
      return PairingNonceValidation.expired;
    }
    if (matched) return PairingNonceValidation.valid;

    _failedAttempts++;
    if (_failedAttempts >= maximumAttempts) {
      _locked = true;
      _nonce = null;
      return PairingNonceValidation.locked;
    }
    return PairingNonceValidation.invalid;
  }

  void invalidate() {
    _nonce = null;
    _expiresAt = null;
    _locked = false;
  }

  bool get _isExpired => _expiresAt != null && !_clock().isBefore(_expiresAt!);
}
