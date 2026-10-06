import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:remotex/core/models/session_error.dart';
import 'package:remotex/core/services/secure_session_channel.dart';
import 'package:remotex/core/services/session_transport.dart';

// ignore_for_file: prefer_initializing_formals

class AesGcmSessionChannel implements SecureSessionChannel {
  AesGcmSessionChannel({
    required SessionWire wire,
    required String sessionId,
    required List<int> sendKey,
    required List<int> receiveKey,
    required String sendDirection,
    required String receiveDirection,
    AesGcm? cipher,
  }) : _wire = wire,
       _sessionId = sessionId,
       _sendKey = SecretKey(sendKey),
       _receiveKey = SecretKey(receiveKey),
       _sendDirection = sendDirection,
       _receiveDirection = receiveDirection,
       _cipher = cipher ?? AesGcm.with256bits();

  final SessionWire _wire;
  final String _sessionId;
  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final String _sendDirection;
  final String _receiveDirection;
  final AesGcm _cipher;
  int _sendSequence = 0;
  int _receiveSequence = 0;
  bool _closed = false;

  @override
  Future<void> send(List<int> plaintext) async {
    if (_closed) throw const SessionException(SessionError.networkDisconnected);
    final sequence = _sendSequence++;
    final nonce = _nonce(sequence);
    final aad = _aad(_sendDirection, sequence);
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: _sendKey,
      nonce: nonce,
      aad: aad,
    );
    await _wire.writeMessage({
      'type': 'data',
      'sid': _sessionId,
      'seq': sequence,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    });
  }

  @override
  Future<List<int>> receive() async {
    if (_closed) throw const SessionException(SessionError.networkDisconnected);
    final frame = await _wire.readMessage();
    if (frame['type'] != 'data' || frame['sid'] != _sessionId) {
      throw const SessionException(SessionError.malformedMessage);
    }
    final sequence = frame['seq'];
    if (sequence is! int || sequence != _receiveSequence) {
      throw const SessionException(SessionError.replayedHandshake);
    }
    final nonce = _decode(frame, 'nonce');
    final ciphertext = _decode(frame, 'ciphertext');
    final tag = _decode(frame, 'tag');
    if (nonce.length != _cipher.nonceLength || tag.length != 16) {
      throw const SessionException(SessionError.malformedMessage);
    }
    if (!_sameBytes(nonce, _nonce(sequence))) {
      throw const SessionException(SessionError.replayedHandshake);
    }
    try {
      final plaintext = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
        secretKey: _receiveKey,
        aad: _aad(_receiveDirection, sequence),
      );
      _receiveSequence++;
      return plaintext;
    } on SecretBoxAuthenticationError {
      throw const SessionException(SessionError.authenticationFailed);
    }
  }

  static List<int> _decode(Map<String, Object?> frame, String key) {
    final value = frame[key];
    if (value is! String) {
      throw const SessionException(SessionError.malformedMessage);
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw const SessionException(SessionError.malformedMessage);
    }
  }

  List<int> _aad(String direction, int sequence) =>
      utf8.encode('remotex-session-v1|$_sessionId|$direction|$sequence');

  List<int> _nonce(int sequence) {
    final bytes = Uint8List(12);
    ByteData.sublistView(bytes).setUint64(4, sequence, Endian.big);
    return bytes;
  }

  static bool _sameBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first[index] ^ second[index];
    }
    return difference == 0;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _wire.close();
  }
}
