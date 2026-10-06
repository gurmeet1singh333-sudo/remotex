// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:remotex/core/services/device_identity_service.dart';
import 'package:remotex/core/services/session_transport.dart';
import 'package:remotex/services/relay/relay_session_transport.dart';
import 'package:remotex/services/relay/web_socket_adapter.dart';

class WebRelayHostClient {
  WebRelayHostClient({
    required DeviceIdentityService identityService,
    DateTime Function()? clock,
  })  : _identityService = identityService,
        _clock = clock ?? DateTime.now;

  final DeviceIdentityService _identityService;
  final DateTime Function() _clock;
  final _incomingController = StreamController<SessionWire>.broadcast();
  final _statusController = StreamController<bool>.broadcast();

  WebSocketChannelAdapter? _socket;
  StreamSubscription<dynamic>? _subscription;
  String? _relayUrl;
  bool _isRunning = false;
  bool _userStopped = false;
  bool _isReconnecting = false;
  int _activeClients = 0;

  Stream<SessionWire> get incomingConnections => _incomingController.stream;
  Stream<bool> get statusChanges => _statusController.stream;
  bool get isRunning => _isRunning;
  String? get relayUrl => _relayUrl;
  int get activeClients => _activeClients;

  Future<void> start({required String relayUrl}) async {
    if (_isRunning) return;
    _userStopped = false;
    _relayUrl = relayUrl;
    await _connectAndRegister();
  }

  Future<void> _connectAndRegister() async {
    final identity = await _identityService.getOrCreateIdentity();
    final socket = await connectWebSocket(_relayUrl!);
    _socket = socket;

    final timestamp = _clock().toUtc().millisecondsSinceEpoch;
    final transcript = utf8.encode(jsonEncode([
      'remotex-relay-host-v1',
      identity.id,
      timestamp,
    ]));

    final signature = base64Encode(await _identityService.sign(transcript));

    final registeredCompleter = Completer<void>();
    late StreamSubscription<dynamic> sub;

    sub = socket.stream.listen(
      (data) {
        if (data is String) {
          try {
            final json = jsonDecode(data);
            if (json is Map) {
              final type = json['type'];
              if (type == 'host_registered') {
                if (!registeredCompleter.isCompleted) {
                  registeredCompleter.complete();
                }
              } else if (type == 'client_connected') {
                final sessionId = json['sessionId'] as String;
                _handleClientConnected(sessionId);
              } else if (type == 'client_disconnected') {
                if (_activeClients > 0) _activeClients--;
              }
            }
          } on Object {
            // Ignore format errors
          }
        }
      },
      onError: (Object error) {
        unawaited(_handleUnexpectedDisconnect());
      },
      onDone: () {
        unawaited(_handleUnexpectedDisconnect());
      },
    );

    _subscription = sub;

    socket.send(jsonEncode({
      'type': 'register_host',
      'hostId': identity.id,
      'hostPublicKey': identity.publicKey,
      'timestamp': timestamp,
      'signature': signature,
    }));

    await registeredCompleter.future.timeout(const Duration(seconds: 10));
    _isRunning = true;
    _statusController.add(true);
  }

  Future<void> _handleUnexpectedDisconnect() async {
    await _cleanupSocket();
    if (_userStopped || _isReconnecting || _relayUrl == null) return;
    _isReconnecting = true;
    _isRunning = false;
    _statusController.add(false);

    const delays = [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ];

    for (final delay in delays) {
      if (_userStopped) break;
      await Future<void>.delayed(delay);
      if (_userStopped) break;
      try {
        await _connectAndRegister();
        _isReconnecting = false;
        return;
      } on Object {
        // Retry failed
      }
    }

    _isReconnecting = false;
    await _stopInternal();
  }

  void _handleClientConnected(String sessionId) {
    final socket = _socket;
    if (socket == null || !_isRunning) return;

    _activeClients++;
    final wire = RelaySessionWire(
      sessionId: sessionId,
      socket: socket,
      onClose: () {
        if (_activeClients > 0) _activeClients--;
      },
    );

    if (!_incomingController.isClosed) {
      _incomingController.add(wire);
    }
  }

  Future<void> stop() async {
    _userStopped = true;
    await _stopInternal();
  }

  Future<void> _stopInternal() async {
    _isRunning = false;
    _statusController.add(false);
    await _cleanupSocket();
    _activeClients = 0;
  }

  Future<void> _cleanupSocket() async {
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close();
      } on Object {
        // Ignore
      }
    }
  }
}
