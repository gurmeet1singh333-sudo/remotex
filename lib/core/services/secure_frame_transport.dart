import 'package:remotex/core/models/screen_frame.dart';

abstract interface class SecureFrameTransport {
  Future<void> sendFrame(ScreenFrame frame);

  Future<ScreenFrame> receiveFrame();
}
