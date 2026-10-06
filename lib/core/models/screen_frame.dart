import 'dart:typed_data';

enum ScreenFrameFormat { jpeg }

class ScreenFrame {
  const ScreenFrame({
    required this.sequence,
    required this.timestamp,
    required this.width,
    required this.height,
    required this.format,
    required this.keyFrame,
    required this.encodedBytes,
  });

  final int sequence;
  final DateTime timestamp;
  final int width;
  final int height;
  final ScreenFrameFormat format;
  final bool keyFrame;
  final Uint8List encodedBytes;

  int get encodedSize => encodedBytes.length;
}

class ReceivedScreenFrame {
  const ReceivedScreenFrame({required this.sessionId, required this.frame});

  final String sessionId;
  final ScreenFrame frame;
}
