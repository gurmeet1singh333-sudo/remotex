import 'dart:convert';
import 'dart:typed_data';

import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/protocol/protocol_error.dart';
import 'package:remotex/core/protocol/session_authorization.dart';
import 'package:remotex/core/protocol/session_packet_multiplexer.dart';
import 'package:remotex/core/services/secure_frame_transport.dart';

class FrameTransportException implements Exception {
  const FrameTransportException(this.message);

  final String message;
}

class BinarySecureFrameTransport implements SecureFrameTransport {
  BinarySecureFrameTransport({
    required this._packets,
    required this._authorization,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const maximumEncodedFrameBytes = 1024 * 1024;
  static const maximumMetadataBytes = 2048;
  static const maximumWidth = 1280;
  static const maximumHeight = 720;
  static const _maximumClockSkew = Duration(minutes: 5);

  final SessionPacketMultiplexer _packets;
  final SessionAuthorization _authorization;
  final DateTime Function() _clock;
  int _sendSequence = 0;
  int _receiveSequence = 0;

  @override
  Future<void> sendFrame(ScreenFrame frame) async {
    _requireScope();
    final sequencedFrame = ScreenFrame(
      sequence: _sendSequence,
      timestamp: frame.timestamp,
      width: frame.width,
      height: frame.height,
      format: frame.format,
      keyFrame: frame.keyFrame,
      encodedBytes: frame.encodedBytes,
    );
    _validateFrame(sequencedFrame, _sendSequence);
    final metadata = utf8.encode(
      jsonEncode({
        'sequence': sequencedFrame.sequence,
        'timestamp': sequencedFrame.timestamp.toUtc().millisecondsSinceEpoch,
        'width': sequencedFrame.width,
        'height': sequencedFrame.height,
        'format': sequencedFrame.format.name,
        'encodedSize': sequencedFrame.encodedSize,
        'keyFrame': sequencedFrame.keyFrame,
      }),
    );
    if (metadata.isEmpty || metadata.length > maximumMetadataBytes) {
      throw const FrameTransportException('Invalid frame metadata.');
    }
    final packet = Uint8List(2 + metadata.length + sequencedFrame.encodedSize);
    ByteData.sublistView(packet).setUint16(0, metadata.length, Endian.big);
    packet.setRange(2, 2 + metadata.length, metadata);
    packet.setRange(
      2 + metadata.length,
      packet.length,
      sequencedFrame.encodedBytes,
    );
    if (await _packets.sendFrame(packet)) _sendSequence++;
  }

  @override
  Future<ScreenFrame> receiveFrame() async {
    final packet = await _packets.receiveFrame();
    _requireScope();
    if (packet.length < 2 ||
        packet.length > maximumEncodedFrameBytes + maximumMetadataBytes + 2) {
      throw const FrameTransportException('Malformed frame packet.');
    }
    final metadataLength = ByteData.sublistView(
      Uint8List.fromList(packet.sublist(0, 2)),
    ).getUint16(0, Endian.big);
    if (metadataLength == 0 ||
        metadataLength > maximumMetadataBytes ||
        packet.length < 2 + metadataLength) {
      throw const FrameTransportException('Malformed frame metadata size.');
    }
    final Map<String, Object?> metadata;
    try {
      final decoded = jsonDecode(
        utf8.decode(
          packet.sublist(2, 2 + metadataLength),
          allowMalformed: false,
        ),
      );
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        throw const FormatException();
      }
      metadata = Map<String, Object?>.from(decoded);
    } on FormatException {
      throw const FrameTransportException('Malformed frame metadata.');
    }
    if (!metadata.keys.toSet().containsAll({
          'sequence',
          'timestamp',
          'width',
          'height',
          'format',
          'encodedSize',
          'keyFrame',
        }) ||
        metadata.length != 7) {
      throw const FrameTransportException('Malformed frame metadata fields.');
    }
    final encodedBytes = packet.sublist(2 + metadataLength);
    final timestamp = metadata['timestamp'];
    final frame = ScreenFrame(
      sequence: _requiredInt(metadata, 'sequence'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        _requiredInt(metadata, 'timestamp'),
        isUtc: true,
      ),
      width: _requiredInt(metadata, 'width'),
      height: _requiredInt(metadata, 'height'),
      format: switch (metadata['format']) {
        'jpeg' => ScreenFrameFormat.jpeg,
        _ => throw const FrameTransportException('Unsupported frame format.'),
      },
      keyFrame: metadata['keyFrame'] == true,
      encodedBytes: Uint8List.fromList(encodedBytes),
    );
    if (timestamp is! int ||
        (timestamp - _clock().toUtc().millisecondsSinceEpoch).abs() >
            _maximumClockSkew.inMilliseconds ||
        metadata['encodedSize'] != encodedBytes.length) {
      throw const FrameTransportException('Invalid frame metadata.');
    }
    _validateFrame(frame, _receiveSequence);
    _receiveSequence++;
    return frame;
  }

  void _requireScope() {
    if (!_authorization.allows(AuthorizationScope.screenView)) {
      throw const ProtocolException(ProtocolError.unauthorized);
    }
  }

  void _validateFrame(ScreenFrame frame, int expectedSequence) {
    final delta =
        (frame.timestamp.toUtc().millisecondsSinceEpoch -
                _clock().toUtc().millisecondsSinceEpoch)
            .abs();
    if (frame.sequence != expectedSequence || frame.sequence < 0) {
      throw const FrameTransportException('Invalid frame sequence.');
    }
    if (frame.width <= 0 ||
        frame.height <= 0 ||
        frame.width > maximumWidth ||
        frame.height > maximumHeight) {
      throw const FrameTransportException('Invalid frame dimensions.');
    }
    if (frame.format != ScreenFrameFormat.jpeg ||
        !frame.keyFrame ||
        frame.encodedSize < 4 ||
        frame.encodedSize > maximumEncodedFrameBytes ||
        frame.encodedBytes[0] != 0xff ||
        frame.encodedBytes[1] != 0xd8 ||
        frame.encodedBytes[frame.encodedSize - 2] != 0xff ||
        frame.encodedBytes[frame.encodedSize - 1] != 0xd9) {
      throw const FrameTransportException('Invalid JPEG frame data.');
    }
    if (delta > _maximumClockSkew.inMilliseconds) {
      throw const FrameTransportException('Invalid frame timestamp.');
    }
  }

  static int _requiredInt(Map<String, Object?> metadata, String key) {
    final value = metadata[key];
    if (value is! int) {
      throw const FrameTransportException('Malformed frame metadata.');
    }
    return value;
  }
}
