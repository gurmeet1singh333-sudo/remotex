import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/session_error.dart';
import 'package:remotex/core/services/session_transport.dart';

class LanSessionTransport implements SessionTransport {
  static const _serviceType = '_remotex-session._tcp';
  static const _serviceId = 'remotex-session';
  static const _protocolVersion = 1;
  static const _maximumMessageLength = 16384;
  static const _maximumAuthenticatedMessageLength = 2 * 1024 * 1024;
  static const _maximumConnections = 8;
  static const _discoveryTimeout = Duration(seconds: 10);
  static const _socketTimeout = Duration(seconds: 8);

  final _incoming = StreamController<SessionWire>.broadcast();
  ServerSocket? _server;
  BonsoirBroadcast? _broadcast;
  int _activeConnections = 0;

  @override
  Stream<SessionWire> get incomingConnections => _incoming.stream;

  @override
  Future<void> startHost(String hostId) async {
    if (_server != null) return;
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final broadcast = BonsoirBroadcast(
      printLogs: false,
      service: BonsoirService(
        name: 'RemoteX Session',
        type: _serviceType,
        port: server.port,
        attributes: {
          'service': _serviceId,
          'hostId': hostId,
          'version': '$_protocolVersion',
        },
      ),
    );
    try {
      await broadcast.initialize();
      await broadcast.start();
    } catch (error) {
      await server.close();
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    _server = server;
    _broadcast = broadcast;
    server.listen((socket) {
      if (_activeConnections >= _maximumConnections) {
        socket.destroy();
        return;
      }
      _activeConnections++;
      socket.done.whenComplete(() => _activeConnections--);
      _incoming.add(JsonSocketSessionWire(socket));
    });
  }

  @override
  Future<SessionWire> connect(PairedDevice host) async {
    if (host.id != host.hostId) {
      throw const SessionException(SessionError.authenticationFailed);
    }
    final discovery = BonsoirDiscovery(type: _serviceType, printLogs: false);
    try {
      await discovery.initialize();
      final events = discovery.eventStream;
      if (events == null) {
        throw const SessionException(SessionError.hostUnavailable);
      }
      final resolved = Completer<BonsoirService>();
      final subscription = events.listen((event) {
        final service = event.service;
        if (service == null) return;
        if (event is BonsoirDiscoveryServiceFoundEvent) {
          unawaited(service.resolve(discovery.serviceResolver));
        } else if (event is BonsoirDiscoveryServiceResolvedEvent &&
            service.attributes['service'] == _serviceId &&
            service.attributes['hostId'] == host.id &&
            service.attributes['version'] == '$_protocolVersion' &&
            !resolved.isCompleted) {
          resolved.complete(service);
        }
      });
      try {
        await discovery.start();
        final service = await resolved.future.timeout(_discoveryTimeout);
        final addresses = service.hostAddresses
            .map(InternetAddress.tryParse)
            .whereType<InternetAddress>();
        for (final address in addresses) {
          try {
            final socket = await Socket.connect(
              address,
              service.port,
              timeout: _socketTimeout,
            );
            return JsonSocketSessionWire(socket);
          } on SocketException {
            continue;
          } on TimeoutException {
            continue;
          }
        }
        throw const SessionException(SessionError.hostUnavailable);
      } on TimeoutException {
        throw const SessionException(SessionError.hostUnavailable);
      } finally {
        await subscription.cancel();
      }
    } on SessionException {
      rethrow;
    } on TimeoutException {
      throw const SessionException(SessionError.hostUnavailable);
    } on SocketException {
      throw const SessionException(SessionError.hostUnavailable);
    } finally {
      await discovery.stop();
    }
  }

  @override
  Future<void> stopHost() async {
    final broadcast = _broadcast;
    _broadcast = null;
    await broadcast?.stop();
    final server = _server;
    _server = null;
    await server?.close();
  }
}

class JsonSocketSessionWire implements SessionWire {
  JsonSocketSessionWire(this._socket)
    : _chunks = StreamIterator<List<int>>(_socket);

  final Socket _socket;
  final StreamIterator<List<int>> _chunks;
  final List<int> _lineBytes = [];
  int _maximumMessageLength = LanSessionTransport._maximumMessageLength;
  List<int>? _currentChunk;
  int _chunkOffset = 0;

  void allowAuthenticatedFrames() {
    _maximumMessageLength =
        LanSessionTransport._maximumAuthenticatedMessageLength;
  }

  @override
  Future<Map<String, Object?>> readMessage() async {
    while (true) {
      final chunk = _currentChunk;
      if (chunk != null) {
        if (_chunkOffset >= chunk.length) {
          _currentChunk = null;
          continue;
        }
        var newline = _chunkOffset;
        while (newline < chunk.length && chunk[newline] != 0x0a) {
          newline++;
        }
        final segmentLength = newline - _chunkOffset;
        if (_lineBytes.length + segmentLength > _maximumMessageLength) {
          throw const SessionException(SessionError.malformedMessage);
        }
        _lineBytes.addAll(chunk.getRange(_chunkOffset, newline));
        if (newline < chunk.length) {
          _chunkOffset = newline + 1;
          final line = List<int>.of(_lineBytes);
          _lineBytes.clear();
          return _decodeLine(line);
        }
        _chunkOffset = newline;
      }

      final bool hasChunk;
      try {
        hasChunk = await _chunks.moveNext().timeout(
          LanSessionTransport._socketTimeout,
        );
      } on TimeoutException {
        throw const SessionException(SessionError.networkDisconnected);
      }
      if (!hasChunk) {
        throw const SessionException(SessionError.networkDisconnected);
      }
      _currentChunk = _chunks.current;
      _chunkOffset = 0;
    }
  }

  Map<String, Object?> _decodeLine(List<int> line) {
    try {
      final decoded = jsonDecode(utf8.decode(line, allowMalformed: false));
      if (decoded is! Map) {
        throw const FormatException();
      }
      return Map<String, Object?>.from(decoded);
    } on Object {
      throw const SessionException(SessionError.malformedMessage);
    }
  }

  @override
  Future<void> writeMessage(Map<String, Object?> message) async {
    final encoded = jsonEncode(message);
    if (utf8.encode(encoded).length > _maximumMessageLength) {
      throw const SessionException(SessionError.malformedMessage);
    }
    _socket.write('$encoded\n');
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    await _chunks.cancel();
    _socket.destroy();
  }
}
