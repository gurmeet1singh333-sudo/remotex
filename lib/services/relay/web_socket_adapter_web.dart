// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'web_socket_adapter_stub.dart';

export 'web_socket_adapter_stub.dart';

class WebWebSocketChannelAdapter implements WebSocketChannelAdapter {
  WebWebSocketChannelAdapter(this._socket) {
    _socket.binaryType = 'arraybuffer';
    _socket.onMessage.listen((event) {
      if (_controller.isClosed) return;
      _controller.add(event.data);
    });
    _socket.onClose.listen((_) {
      if (!_controller.isClosed) _controller.close();
    });
    _socket.onError.listen((error) {
      if (!_controller.isClosed) _controller.addError(error);
    });
  }

  final html.WebSocket _socket;
  final _controller = StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void send(dynamic data) {
    if (data is String) {
      _socket.send(data);
    } else if (data is List<int>) {
      _socket.sendTypedData(Uint8List.fromList(data));
    } else {
      _socket.send(data);
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _socket.close(code, reason);
    await _controller.close();
  }
}

Future<WebSocketChannelAdapter> connectWebSocket(String url) async {
  final socket = html.WebSocket(url);
  final completer = Completer<WebSocketChannelAdapter>();
  late StreamSubscription<html.Event> openSub;
  late StreamSubscription<html.Event> errorSub;

  openSub = socket.onOpen.listen((_) {
    openSub.cancel();
    errorSub.cancel();
    if (!completer.isCompleted) {
      completer.complete(WebWebSocketChannelAdapter(socket));
    }
  });

  errorSub = socket.onError.listen((error) {
    openSub.cancel();
    errorSub.cancel();
    if (!completer.isCompleted) {
      completer.completeError(StateError('WebSocket connection failed: $url'));
    }
  });

  return completer.future;
}
