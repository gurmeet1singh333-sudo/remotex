import 'dart:async';

import 'package:remotex/core/models/screen_frame.dart';
import 'package:remotex/core/models/remote_cursor_position.dart';

class ScreenDimensions {
  const ScreenDimensions({required this.width, required this.height});

  final int width;
  final int height;
}

abstract interface class ScreenCaptureService {
  Stream<ScreenFrame> get frames;

  Object? get lastError;

  Future<ScreenDimensions> startCapture();

  Future<RemoteCursorPosition?> getCursorPosition();

  Future<void> stopCapture();
}
