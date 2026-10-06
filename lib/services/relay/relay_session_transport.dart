// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/session_error.dart';
import 'package:remotex/core/services/session_transport.dart';
import 'package:remotex/services/relay/web_socket_adapter.dart';

class RelaySessionWire implements SessionWire {
  RelaySessionWire({
    required this.sessionId,
    required WebSocketChannelAdapter socket,
    void Function()? onClose,
  })  : _socket = socket,
        _onClose = onClose {
    _subscription = _socket.stream.listen(
      _handleIncomingData,
      onError: (Object error) {
        _controller.addError(
          const SessionException(SessionError.networkDisconnected),
        );
      },
      onDone: () {
        if (!_controller.isClosed) _controller.close();
      },
    );
  }

  final String sessionId;
  final WebSocketChannelAdapter _socket;
  final void Function()? _onClose;
  final _controller = StreamController<Map<String, Object?>>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  bool _closed = false;

  void _handleIncomingData(dynamic data) {
    if (_closed) return;
    try {
      if (data is String) {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          final map = Map<String, Object?>.from(decoded);
          final sid = map['sessionId'];
          if (sid == null || sid == sessionId) {
            _controller.add(map);
          }
        }
      } else if (data is Uint8List) {
        _handleBinaryData(data);
      } else if (data is List<int>) {
        _handleBinaryData(Uint8List.fromList(data));
      } else if (data is ByteBuffer) {
        _handleBinaryData(Uint8List.view(data));
      }
    } on Object {
      _controller.addError(
        const SessionException(SessionError.malformedMessage),
      );
    }
  }

  void _handleBinaryData(Uint8List bytes) {
    if (bytes.length < 24) return;
    final sid = utf8.decode(bytes.sublist(0, 24), allowMalformed: true);
    if (sid == sessionId) {
      final payload = bytes.sublist(24);
      try {
        final json = jsonDecode(utf8.decode(payload));
        if (json is Map) {
          _controller.add(Map<String, Object?>.from(json));
        }
      } on Object {
        // Binary packet
      }
    }
  }

  @override
  Future<Map<String, Object?>> readMessage() async {
    if (_closed) {
      throw const SessionException(SessionError.networkDisconnected);
    }
    try {
      final stream = _controller.stream;
      return await stream.first.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const SessionException(SessionError.networkDisconnected);
    } on StateError {
      throw const SessionException(SessionError.networkDisconnected);
    }
  }

  @override
  Future<void> writeMessage(Map<String, Object?> message) async {
    if (_closed) {
      throw const SessionException(SessionError.networkDisconnected);
    }
    final fullMessage = Map<String, Object?>.from(message)..['sessionId'] = sessionId;
    _socket.send(jsonEncode(fullMessage));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    await _controller.close();
    _onClose?.call();
  }
}

class RelaySessionTransport implements SessionTransport {
  RelaySessionTransport({
    required this.relayUrl,
  });

  final String relayUrl;
  final _incoming = StreamController<SessionWire>.broadcast();

  @override
  Stream<SessionWire> get incomingConnections => _incoming.stream;

  @override
  Future<void> startHost(String hostId) async {}

  @override
  Future<SessionWire> connect(PairedDevice host) async {
    try {
      final socket = await connectWebSocket(relayUrl);
      final sessionId = _randomSessionId();

      final completer = Completer<RelaySessionWire>();
      late StreamSubscription<dynamic> sub;

      sub = socket.stream.listen((data) {
        if (data is String) {
          try {
            final json = jsonDecode(data);
            if (json is Map && json['type'] == 'connected') {
              sub.cancel();
              if (!completer.isCompleted) {
                completer.complete(
                  RelaySessionWire(
                    sessionId: sessionId,
                    socket: socket,
                    onClose: () => socket.close(),
                  ),
                );
              }
            } else if (json is Map && json['type'] == 'error') {
              sub.cancel();
              if (!completer.isCompleted) {
                completer.completeError(
                  const SessionException(SessionError.hostUnavailable),
                );
              }
            }
          } on Object {
            // Ignore
          }
        }
      }, onError: (Object error) {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.completeError(
            const SessionException(SessionError.hostUnavailable),
          );
        }
      });

      socket.send(jsonEncode({
        'type': 'connect_host',
        'hostId': host.id,
        'sessionId': sessionId,
      }));

      return await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const SessionException(SessionError.hostUnavailable);
    } on Object {
      throw const SessionException(SessionError.hostUnavailable);
    }
  }

  @override
  Future<void> stopHost() async {
    await _incoming.close();
  }

  static String _randomSessionId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return now.padLeft(24, '0').substring(0, 24);
  }
}
