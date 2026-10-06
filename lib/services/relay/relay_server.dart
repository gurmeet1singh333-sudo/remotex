// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

class RemoteXRelayConfig {
  const RemoteXRelayConfig({
    this.host = '127.0.0.1',
    this.port = 8080,
    this.allowedOrigins = const ['*'],
    this.maxSessions = 100,
    this.maxMessageLength = 2 * 1024 * 1024,
    this.sessionTimeout = const Duration(minutes: 30),
    this.authTimeout = const Duration(seconds: 10),
    this.rateLimitPerSecond = 120,
    this.isProduction = false,
  });

  factory RemoteXRelayConfig.fromEnvironment() {
    final isProd = Platform.environment['REMOTEX_ENV'] == 'production';
    final host = Platform.environment['REMOTEX_RELAY_HOST'] ?? '127.0.0.1';

    final port = _parsePortEnv();

    final originsEnv = Platform.environment['REMOTEX_ALLOWED_ORIGINS'];
    final List<String> origins;
    if (originsEnv != null && originsEnv.trim().isNotEmpty) {
      origins = originsEnv
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } else if (isProd) {
      throw StateError(
        'In production mode (REMOTEX_ENV=production), REMOTEX_ALLOWED_ORIGINS environment variable is required.',
      );
    } else {
      origins = const ['*'];
    }

    if (isProd) {
      if (origins.isEmpty || origins.contains('*')) {
        throw StateError(
          'In production mode (REMOTEX_ENV=production), REMOTEX_ALLOWED_ORIGINS must contain explicit origins and cannot be empty or contain wildcards ("*").',
        );
      }
    }

    final maxSessions = _parseIntEnv(
      'REMOTEX_MAX_SESSIONS',
      100,
      min: 1,
      max: 10000,
    );

    final maxMsgLen = _parseIntEnv(
      'REMOTEX_MAX_MESSAGE_BYTES',
      2 * 1024 * 1024,
      min: 1024,
      max: 104857600,
    );

    final timeoutMins = _parseIntEnv(
      'REMOTEX_SESSION_TIMEOUT_MINUTES',
      30,
      min: 1,
      max: 1440,
    );

    final authTimeoutSecs = _parseIntEnv(
      'REMOTEX_AUTH_TIMEOUT_SECONDS',
      10,
      min: 1,
      max: 300,
    );

    final rateLimit = _parseIntEnv(
      'REMOTEX_RATE_LIMIT_PER_SEC',
      120,
      min: 1,
      max: 10000,
    );

    return RemoteXRelayConfig(
      host: host,
      port: port,
      allowedOrigins: List.unmodifiable(origins),
      maxSessions: maxSessions,
      maxMessageLength: maxMsgLen,
      sessionTimeout: Duration(minutes: timeoutMins),
      authTimeout: Duration(seconds: authTimeoutSecs),
      rateLimitPerSecond: rateLimit,
      isProduction: isProd,
    );
  }

  static int _parsePortEnv() {
    final renderPort = Platform.environment['PORT'];
    if (renderPort != null && renderPort.trim().isNotEmpty) {
      return _validateInt('PORT', renderPort, min: 1, max: 65535);
    }
    final relayPort = Platform.environment['REMOTEX_RELAY_PORT'];
    if (relayPort != null && relayPort.trim().isNotEmpty) {
      return _validateInt('REMOTEX_RELAY_PORT', relayPort, min: 1, max: 65535);
    }
    return 8080;
  }

  static int _parseIntEnv(
    String key,
    int defaultValue, {
    required int min,
    required int max,
  }) {
    final raw = Platform.environment[key];
    if (raw == null || raw.trim().isEmpty) return defaultValue;
    return _validateInt(key, raw, min: min, max: max);
  }

  static int _validateInt(
    String key,
    String raw, {
    required int min,
    required int max,
  }) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) {
      throw StateError(
        'Environment variable $key must be an integer, got "$raw".',
      );
    }
    if (parsed < min || parsed > max) {
      throw StateError(
        'Environment variable $key value $parsed is out of valid bounds ($min to $max).',
      );
    }
    return parsed;
  }

  final String host;
  final int port;
  final List<String> allowedOrigins;
  final int maxSessions;
  final int maxMessageLength;
  final Duration sessionTimeout;
  final Duration authTimeout;
  final int rateLimitPerSecond;
  final bool isProduction;
}

class _HostConnection {
  _HostConnection({
    required this.hostId,
    required this.socket,
    required this.connection,
  });

  final String hostId;
  final WebSocket socket;
  final _SocketConnection connection;
}

class _RelayBridge {
  _RelayBridge({
    required this.sessionId,
    required this.hostId,
    required this.clientSocket,
    required this.createdAt,
    required this.connection,
    required this.timeoutTimer,
  });

  final String sessionId;
  final String hostId;
  final WebSocket clientSocket;
  final DateTime createdAt;
  final _SocketConnection connection;
  Timer timeoutTimer;
}

enum _ConnectionRole { unassigned, host, bridge }

class _SocketConnection {
  _SocketConnection({
    required this.socket,
  });

  final WebSocket socket;
  _ConnectionRole role = _ConnectionRole.unassigned;

  // Unassigned fields
  Timer? authTimeoutTimer;

  // Host fields
  String? hostId;

  // Bridge fields
  String? sessionId;
  String? bridgeHostId;

  // Rate limiting
  int _messageCount = 0;
  DateTime? _windowStart;

  bool checkRateLimit(DateTime now, int limitPerSecond) {
    final start = _windowStart;
    if (start == null || now.difference(start) >= const Duration(seconds: 1)) {
      _windowStart = now;
      _messageCount = 1;
      return true;
    }
    _messageCount++;
    return _messageCount <= limitPerSecond;
  }
}

class RemoteXRelayServer {
  RemoteXRelayServer({
    RemoteXRelayConfig? config,
    DateTime Function()? clock,
    void Function(String message)? logger,
  })  : config = config ?? const RemoteXRelayConfig(),
        _clock = clock ?? DateTime.now,
        _logger = logger;

  final RemoteXRelayConfig config;
  final DateTime Function() _clock;
  final void Function(String message)? _logger;
  final Map<String, _HostConnection> _hosts = {};
  final Map<String, _RelayBridge> _bridges = {};
  HttpServer? _server;
  DateTime? _startTime;
  bool _stopped = false;

  int get activeHosts => _hosts.length;
  int get activeBridges => _bridges.length;
  int get port => _server?.port ?? config.port;

  void _log(String message) {
    _logger?.call(message);
  }

  Future<void> start() async {
    if (_server != null) return;
    _stopped = false;
    _startTime = _clock();
    final server = await HttpServer.bind(config.host, config.port);
    _server = server;
    _log('[INFO] RemoteX Relay Server listening on ${config.host}:${server.port} (mode: ${config.isProduction ? "production" : "development"})');
    server.listen(
      _handleHttpRequest,
      onError: (Object error) {
        _log('[ERROR] HttpServer error: $error');
        if (!_stopped) _stopServer();
      },
    );
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      if (request.method == 'GET' &&
          (request.uri.path == '/health' || request.uri.path == '/status')) {
        final now = _clock();
        final uptime = _startTime != null
            ? now.difference(_startTime!).inSeconds
            : 0;
        final healthJson = jsonEncode({
          'status': 'ok',
          'version': '1.0.0',
          'uptimeSeconds': uptime,
          'activeHostsCount': activeHosts,
          'activeBridgesCount': activeBridges,
        });
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..headers.set('Cache-Control', 'no-store')
          ..write(healthJson)
          ..close();
        return;
      }

      request.response
        ..statusCode = HttpStatus.ok
        ..write('RemoteX Relay Server active.')
        ..close();
      return;
    }

    final origin = request.headers.value('origin');
    if (!_isOriginAllowed(origin)) {
      _log('[WARN] Origin rejected: "$origin"');
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('Origin not allowed.')
        ..close();
      return;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    _initSocketConnection(socket);
  }

  bool _isOriginAllowed(String? origin) {
    if (config.isProduction) {
      if (origin == null || origin.isEmpty) return true;
      return config.allowedOrigins.contains(origin);
    }
    if (config.allowedOrigins.contains('*')) return true;
    if (origin == null) return true;
    return config.allowedOrigins.contains(origin);
  }

  void _initSocketConnection(WebSocket socket) {
    final conn = _SocketConnection(socket: socket);

    conn.authTimeoutTimer = Timer(config.authTimeout, () {
      if (conn.role == _ConnectionRole.unassigned) {
        _log('[WARN] Unassigned socket closed due to authentication timeout');
        socket.close(WebSocketStatus.policyViolation, 'Authentication timeout');
      }
    });

    socket.listen(
      (data) => unawaited(_onSocketData(conn, data)),
      onError: (_) => _onSocketClosed(conn),
      onDone: () => _onSocketClosed(conn),
    );
  }

  Future<void> _onSocketData(_SocketConnection conn, dynamic data) async {
    if (!conn.checkRateLimit(_clock(), config.rateLimitPerSecond)) {
      _log('[WARN] Connection rate limit exceeded (${config.rateLimitPerSecond}/s)');
      if (conn.role == _ConnectionRole.bridge && conn.sessionId != null) {
        _closeBridge(conn.sessionId!, reason: 'Rate limit exceeded');
      } else {
        conn.socket.close(WebSocketStatus.normalClosure, 'Rate limit exceeded');
      }
      return;
    }

    switch (conn.role) {
      case _ConnectionRole.unassigned:
        await _handleUnassignedData(conn, data);
        break;
      case _ConnectionRole.host:
        _handleHostData(conn, data);
        break;
      case _ConnectionRole.bridge:
        _handleBridgeData(conn, data);
        break;
    }
  }

  Future<void> _handleUnassignedData(_SocketConnection conn, dynamic data) async {
    if (data is! String) {
      _log('[WARN] Unassigned socket sent non-text frame');
      conn.socket.close(WebSocketStatus.protocolError, 'Expected text frame');
      return;
    }

    try {
      final json = jsonDecode(data);
      if (json is! Map) {
        _log('[WARN] Unassigned socket sent non-object JSON');
        conn.socket.close(WebSocketStatus.protocolError, 'Expected JSON object');
        return;
      }

      final type = json['type'];
      if (type == 'register_host') {
        await _registerHost(conn, Map<String, Object?>.from(json));
      } else if (type == 'connect_host') {
        await _connectClient(conn, Map<String, Object?>.from(json));
      } else {
        _log('[WARN] Unassigned socket sent invalid message type: $type');
        conn.socket.close(WebSocketStatus.protocolError, 'Invalid message type');
      }
    } on Object {
      _log('[WARN] Unassigned socket sent malformed JSON');
      conn.socket.close(WebSocketStatus.protocolError, 'Malformed payload');
    }
  }

  Future<void> _registerHost(_SocketConnection conn, Map<String, Object?> message) async {
    final hostId = message['hostId'];
    final hostPublicKey = message['hostPublicKey'];
    final timestamp = message['timestamp'];
    final signature = message['signature'];

    if (hostId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(hostId) ||
        hostPublicKey is! String ||
        timestamp is! int ||
        signature is! String) {
      _log('[WARN] Host registration rejected: invalid fields');
      conn.socket.close(WebSocketStatus.protocolError, 'Invalid registration fields');
      return;
    }

    final now = _clock().toUtc().millisecondsSinceEpoch;
    if ((now - timestamp).abs() > 60000) {
      _log('[WARN] Host registration rejected: timestamp expired');
      conn.socket.close(WebSocketStatus.policyViolation, 'Timestamp expired');
      return;
    }

    final transcript = utf8.encode(jsonEncode([
      'remotex-relay-host-v1',
      hostId,
      timestamp,
    ]));

    try {
      final pubKeyBytes = base64Decode(hostPublicKey);
      if (pubKeyBytes.length != 32) {
        _log('[WARN] Host registration rejected: invalid public key length');
        conn.socket.close(WebSocketStatus.policyViolation, 'Invalid public key length');
        return;
      }
      final sigBytes = base64Decode(signature);
      if (sigBytes.length != 64) {
        _log('[WARN] Host registration rejected: invalid signature length');
        conn.socket.close(WebSocketStatus.policyViolation, 'Invalid signature length');
        return;
      }

      final algorithm = Ed25519();
      final valid = await algorithm.verify(
        transcript,
        signature: Signature(
          sigBytes,
          publicKey: SimplePublicKey(pubKeyBytes, type: KeyPairType.ed25519),
        ),
      );

      if (!valid) {
        _log('[WARN] Host registration rejected: signature verification failed');
        conn.socket.close(WebSocketStatus.policyViolation, 'Invalid signature');
        return;
      }
    } on Object {
      _log('[WARN] Host registration rejected: signature decode exception');
      conn.socket.close(WebSocketStatus.policyViolation, 'Signature verification failed');
      return;
    }

    conn.authTimeoutTimer?.cancel();
    conn.authTimeoutTimer = null;
    conn.role = _ConnectionRole.host;
    conn.hostId = hostId;

    _hosts[hostId]?.socket.close(WebSocketStatus.normalClosure, 'Replaced');
    final hostConn = _HostConnection(
      hostId: hostId,
      socket: conn.socket,
      connection: conn,
    );
    _hosts[hostId] = hostConn;

    _log('[INFO] Host registered: ${hostId.substring(0, 8)}...');
    conn.socket.add(jsonEncode({
      'type': 'host_registered',
      'hostId': hostId,
    }));
  }

  Future<void> _connectClient(_SocketConnection conn, Map<String, Object?> message) async {
    final hostId = message['hostId'];
    final sessionId = message['sessionId'];

    if (hostId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(hostId) ||
        sessionId is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{24,64}$').hasMatch(sessionId)) {
      _log('[WARN] Client connection rejected: invalid fields');
      conn.socket.close(WebSocketStatus.protocolError, 'Invalid connection fields');
      return;
    }

    final hostConn = _hosts[hostId];
    if (hostConn == null) {
      _log('[INFO] Client connection failed: host unavailable');
      conn.socket.add(jsonEncode({
        'type': 'error',
        'code': 'host_unavailable',
      }));
      conn.socket.close(WebSocketStatus.normalClosure, 'Host unavailable');
      return;
    }

    if (_bridges.containsKey(sessionId)) {
      _log('[WARN] Client connection failed: session conflict for session=${sessionId.substring(0, 8)}...');
      conn.socket.add(jsonEncode({
        'type': 'error',
        'code': 'session_conflict',
      }));
      conn.socket.close(WebSocketStatus.normalClosure, 'Session conflict');
      return;
    }

    if (_bridges.length >= config.maxSessions) {
      _log('[WARN] Client connection failed: server busy (max sessions reached)');
      conn.socket.add(jsonEncode({
        'type': 'error',
        'code': 'server_busy',
      }));
      conn.socket.close(WebSocketStatus.normalClosure, 'Server busy');
      return;
    }

    conn.authTimeoutTimer?.cancel();
    conn.authTimeoutTimer = null;
    conn.role = _ConnectionRole.bridge;
    conn.sessionId = sessionId;
    conn.bridgeHostId = hostId;

    final timeoutTimer = Timer(config.sessionTimeout, () {
      _closeBridge(sessionId, reason: 'Session timeout');
    });

    final bridge = _RelayBridge(
      sessionId: sessionId,
      hostId: hostId,
      clientSocket: conn.socket,
      createdAt: _clock(),
      connection: conn,
      timeoutTimer: timeoutTimer,
    );

    _bridges[sessionId] = bridge;

    _log('[INFO] Bridge created: session=${sessionId.substring(0, 8)}... host=${hostId.substring(0, 8)}...');

    hostConn.socket.add(jsonEncode({
      'type': 'client_connected',
      'sessionId': sessionId,
      'hostId': hostId,
    }));

    conn.socket.add(jsonEncode({
      'type': 'connected',
      'sessionId': sessionId,
      'hostId': hostId,
    }));
  }

  void _touchBridge(_RelayBridge bridge) {
    bridge.timeoutTimer.cancel();
    bridge.timeoutTimer = Timer(config.sessionTimeout, () {
      _closeBridge(bridge.sessionId, reason: 'Session timeout');
    });
  }

  void _handleHostData(_SocketConnection conn, dynamic data) {
    final hostId = conn.hostId;
    if (hostId == null) return;

    if (data is String) {
      if (data.length > config.maxMessageLength) {
        _log('[WARN] Host sent oversized string message (${data.length} bytes)');
        return;
      }
      try {
        final json = jsonDecode(data);
        if (json is Map) {
          final sessionId = json['sessionId'];
          if (sessionId is String) {
            final bridge = _bridges[sessionId];
            if (bridge != null && bridge.hostId == hostId) {
              _touchBridge(bridge);
              bridge.clientSocket.add(data);
            }
          }
        }
      } on Object {
        // Ignore malformed text frames
      }
    } else if (data is List<int>) {
      if (data.length > config.maxMessageLength) {
        _log('[WARN] Host sent oversized binary message (${data.length} bytes)');
        return;
      }
      if (data.length >= 24) {
        final sessionId = utf8.decode(data.sublist(0, 24), allowMalformed: true);
        final bridge = _bridges[sessionId];
        if (bridge != null && bridge.hostId == hostId) {
          _touchBridge(bridge);
          bridge.clientSocket.add(data);
        }
      }
    }
  }

  void _handleBridgeData(_SocketConnection conn, dynamic data) {
    final sessionId = conn.sessionId;
    final hostId = conn.bridgeHostId;
    if (sessionId == null || hostId == null) return;

    final bridge = _bridges[sessionId];
    if (bridge != null) {
      _touchBridge(bridge);
    }

    final hostConn = _hosts[hostId];
    if (hostConn == null) {
      _closeBridge(sessionId, reason: 'Host disconnected');
      return;
    }

    if (data is String) {
      if (data.length > config.maxMessageLength) {
        _log('[WARN] Client sent oversized string message (${data.length} bytes)');
        return;
      }
      try {
        final json = jsonDecode(data);
        if (json is Map && json['type'] == 'revoke_session') {
          _closeBridge(sessionId, reason: 'Revoked');
          return;
        }
      } on Object {
        // Ignore
      }
      hostConn.socket.add(data);
    } else if (data is List<int>) {
      if (data.length > config.maxMessageLength) {
        _log('[WARN] Client sent oversized binary message (${data.length} bytes)');
        return;
      }
      hostConn.socket.add(data);
    }
  }

  void _onSocketClosed(_SocketConnection conn) {
    conn.authTimeoutTimer?.cancel();
    if (conn.role == _ConnectionRole.host && conn.hostId != null) {
      _cleanupHost(conn.hostId!);
    } else if (conn.role == _ConnectionRole.bridge && conn.sessionId != null) {
      _closeBridge(conn.sessionId!);
    }
  }

  void _closeBridge(String sessionId, {String? reason}) {
    final bridge = _bridges.remove(sessionId);
    if (bridge == null) return;

    bridge.timeoutTimer.cancel();
    _log('[INFO] Bridge closed: session=${sessionId.length >= 8 ? sessionId.substring(0, 8) : sessionId}... reason=${reason ?? 'Closed'}');
    try {
      bridge.clientSocket.close(WebSocketStatus.normalClosure, reason ?? 'Closed');
    } on Object {
      // Ignore
    }

    final hostConn = _hosts[bridge.hostId];
    if (hostConn != null) {
      try {
        hostConn.socket.add(jsonEncode({
          'type': 'client_disconnected',
          'sessionId': sessionId,
          'reason': reason ?? 'Disconnected',
        }));
      } on Object {
        // Ignore
      }
    }
  }

  void _cleanupHost(String hostId) {
    final hostConn = _hosts.remove(hostId);
    if (hostConn == null) return;

    _log('[INFO] Host cleaned up: host=${hostId.length >= 8 ? hostId.substring(0, 8) : hostId}...');
    final toRemove = _bridges.values
        .where((b) => b.hostId == hostId)
        .map((b) => b.sessionId)
        .toList();

    for (final sid in toRemove) {
      _closeBridge(sid, reason: 'Host disconnected');
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _log('[INFO] Stopping RemoteX Relay Server...');
    for (final bridge in List<_RelayBridge>.from(_bridges.values)) {
      _closeBridge(bridge.sessionId, reason: 'Relay stopping');
    }
    for (final hostConn in List<_HostConnection>.from(_hosts.values)) {
      try {
        await hostConn.socket.close(WebSocketStatus.goingAway, 'Relay stopping');
      } on Object {
        // Ignore
      }
    }
    _hosts.clear();
    _bridges.clear();
    await _stopServer();
  }

  Future<void> _stopServer() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}

