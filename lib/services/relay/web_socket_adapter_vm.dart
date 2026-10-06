import 'dart:async';
import 'dart:io';

import 'web_socket_adapter_stub.dart';

export 'web_socket_adapter_stub.dart';

class VmWebSocketChannelAdapter implements WebSocketChannelAdapter {
  VmWebSocketChannelAdapter(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get stream => _socket;

  @override
  void send(dynamic data) {
    _socket.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    await _socket.close(code, reason);
  }
}

Future<WebSocketChannelAdapter> connectWebSocket(String url) async {
  final socket = await WebSocket.connect(url);
  return VmWebSocketChannelAdapter(socket);
}
