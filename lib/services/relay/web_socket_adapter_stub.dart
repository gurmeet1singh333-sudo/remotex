import 'dart:async';

abstract class WebSocketChannelAdapter {
  Stream<dynamic> get stream;

  void send(dynamic data);

  Future<void> close([int? code, String? reason]);
}

Future<WebSocketChannelAdapter> connectWebSocket(String url) {
  throw UnsupportedError('WebSocket connection is not supported on this platform.');
}
