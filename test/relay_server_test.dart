import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/services/relay/relay_server.dart';

void main() {
  late RemoteXRelayServer relay;
  late KeyPair hostKeyPair;
  late SimplePublicKey hostPublicKey;

  setUp(() async {
    relay = RemoteXRelayServer(
      config: const RemoteXRelayConfig(
        host: '127.0.0.1',
        port: 0,
        rateLimitPerSecond: 100,
      ),
    );
    await relay.start();

    final algorithm = Ed25519();
    hostKeyPair = await algorithm.newKeyPair();
    hostPublicKey = await hostKeyPair.extractPublicKey() as SimplePublicKey;
  });

  tearDown(() async {
    await relay.stop();
  });

  test('registers host with valid signature and bridges client connection', () async {
    final digest = await Sha256().hash(hostPublicKey.bytes);
    final hostId = digest.bytes
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final transcript = utf8.encode(jsonEncode([
      'remotex-relay-host-v1',
      hostId,
      timestamp,
    ]));

    final algorithm = Ed25519();
    final signature = await algorithm.sign(
      transcript,
      keyPair: hostKeyPair,
    );

    final hostSocket = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    addTearDown(hostSocket.close);

    hostSocket.add(jsonEncode({
      'type': 'register_host',
      'hostId': hostId,
      'hostPublicKey': base64Encode(hostPublicKey.bytes),
      'timestamp': timestamp,
      'signature': base64Encode(signature.bytes),
    }));

    final hostRegisteredCompleter = Completer<void>();
    hostSocket.listen((data) {
      final json = jsonDecode(data);
      if (json['type'] == 'host_registered') {
        hostRegisteredCompleter.complete();
      }
    });

    await hostRegisteredCompleter.future.timeout(const Duration(seconds: 5));
    expect(relay.activeHosts, 1);

    final clientSocket = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    addTearDown(clientSocket.close);

    final sessionId = 'c' * 24;
    clientSocket.add(jsonEncode({
      'type': 'connect_host',
      'hostId': hostId,
      'sessionId': sessionId,
    }));

    final clientConnectedCompleter = Completer<void>();
    clientSocket.listen((data) {
      final json = jsonDecode(data);
      if (json['type'] == 'connected') {
        clientConnectedCompleter.complete();
      }
    });

    await clientConnectedCompleter.future.timeout(const Duration(seconds: 5));
    expect(relay.activeBridges, 1);
  });

  test('rejects connection to unavailable host', () async {
    final clientSocket = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    addTearDown(clientSocket.close);

    clientSocket.add(jsonEncode({
      'type': 'connect_host',
      'hostId': 'b' * 32,
      'sessionId': 'c' * 24,
    }));

    final errorCompleter = Completer<String>();
    clientSocket.listen((data) {
      final json = jsonDecode(data);
      if (json['type'] == 'error') {
        errorCompleter.complete(json['code'] as String);
      }
    });

    final code = await errorCompleter.future.timeout(const Duration(seconds: 5));
    expect(code, 'host_unavailable');
  });

  test('disconnects on malformed message payload', () async {
    final clientSocket = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    addTearDown(clientSocket.close);

    clientSocket.add('not_valid_json');

    final doneCompleter = Completer<void>();
    clientSocket.listen(
      (_) {},
      onDone: () => doneCompleter.complete(),
      onError: (_) => doneCompleter.complete(),
    );

    await doneCompleter.future.timeout(const Duration(seconds: 5));
  });

  test('closes bridge when revoke_session is received', () async {
    final digest = await Sha256().hash(hostPublicKey.bytes);
    final hostId = digest.bytes
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final transcript = utf8.encode(jsonEncode([
      'remotex-relay-host-v1',
      hostId,
      timestamp,
    ]));

    final algorithm = Ed25519();
    final signature = await algorithm.sign(
      transcript,
      keyPair: hostKeyPair,
    );

    final hostSocket = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    addTearDown(hostSocket.close);

    hostSocket.add(jsonEncode({
      'type': 'register_host',
      'hostId': hostId,
      'hostPublicKey': base64Encode(hostPublicKey.bytes),
      'timestamp': timestamp,
      'signature': base64Encode(signature.bytes),
    }));

    final hostRegisteredCompleter = Completer<void>();
    hostSocket.listen((data) {
      final json = jsonDecode(data);
      if (json['type'] == 'host_registered') {
        hostRegisteredCompleter.complete();
      }
    });
    await hostRegisteredCompleter.future.timeout(const Duration(seconds: 5));

    final clientSocket = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    addTearDown(clientSocket.close);

    final sessionId = 'd' * 24;
    clientSocket.add(jsonEncode({
      'type': 'connect_host',
      'hostId': hostId,
      'sessionId': sessionId,
    }));

    final clientConnectedCompleter = Completer<void>();
    clientSocket.listen((data) {
      final json = jsonDecode(data);
      if (json['type'] == 'connected') {
        clientConnectedCompleter.complete();
      }
    });
    await clientConnectedCompleter.future.timeout(const Duration(seconds: 5));
    expect(relay.activeBridges, 1);

    clientSocket.add(jsonEncode({
      'type': 'revoke_session',
      'sessionId': sessionId,
    }));

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(relay.activeBridges, 0);
  });

  test('rejects duplicate connect_host with active sessionId', () async {
    final digest = await Sha256().hash(hostPublicKey.bytes);
    final hostId = digest.bytes
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final transcript = utf8.encode(jsonEncode([
      'remotex-relay-host-v1',
      hostId,
      timestamp,
    ]));

    final algorithm = Ed25519();
    final signature = await algorithm.sign(
      transcript,
      keyPair: hostKeyPair,
    );

    final hostSocket = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    addTearDown(hostSocket.close);

    hostSocket.add(jsonEncode({
      'type': 'register_host',
      'hostId': hostId,
      'hostPublicKey': base64Encode(hostPublicKey.bytes),
      'timestamp': timestamp,
      'signature': base64Encode(signature.bytes),
    }));

    final hostRegisteredCompleter = Completer<void>();
    hostSocket.listen((data) {
      final json = jsonDecode(data);
      if (json['type'] == 'host_registered') {
        hostRegisteredCompleter.complete();
      }
    });
    await hostRegisteredCompleter.future.timeout(const Duration(seconds: 5));

    final client1 = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    addTearDown(client1.close);

    final sessionId = 'e' * 24;
    client1.add(jsonEncode({
      'type': 'connect_host',
      'hostId': hostId,
      'sessionId': sessionId,
    }));

    final client1Completer = Completer<void>();
    client1.listen((data) {
      final json = jsonDecode(data);
      if (json['type'] == 'connected') client1Completer.complete();
    });
    await client1Completer.future.timeout(const Duration(seconds: 5));

    final client2 = await WebSocket.connect('ws://127.0.0.1:${relay.port}');
    addTearDown(client2.close);

    client2.add(jsonEncode({
      'type': 'connect_host',
      'hostId': hostId,
      'sessionId': sessionId,
    }));

    final client2ErrorCompleter = Completer<String>();
    client2.listen((data) {
      final json = jsonDecode(data);
      if (json['type'] == 'error') client2ErrorCompleter.complete(json['code'] as String);
    });

    final errCode = await client2ErrorCompleter.future.timeout(const Duration(seconds: 5));
    expect(errCode, 'session_conflict');
  });

  test('health endpoint returns operational status', () async {
    final client = HttpClient();
    addTearDown(client.close);

    final request = await client.get('127.0.0.1', relay.port, '/health');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);

    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, Object?>;

    expect(json['status'], 'ok');
    expect(json['version'], '1.0.0');
    expect(json['activeHostsCount'], 0);
    expect(json['activeBridgesCount'], 0);
  });

  test('enforces production origin checks', () async {
    final prodRelay = RemoteXRelayServer(
      config: const RemoteXRelayConfig(
        host: '127.0.0.1',
        port: 0,
        isProduction: true,
        allowedOrigins: ['https://remotex.app'],
      ),
    );
    await prodRelay.start();
    addTearDown(prodRelay.stop);

    final client = HttpClient();
    addTearDown(client.close);

    final request = await client.get('127.0.0.1', prodRelay.port, '/');
    request.headers.set('origin', 'https://malicious.com');
    request.headers.set('Connection', 'Upgrade');
    request.headers.set('Upgrade', 'websocket');
    request.headers.set('Sec-WebSocket-Version', '13');
    request.headers.set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');

    final response = await request.close();
    expect(response.statusCode, HttpStatus.forbidden);
  });

  test('parses environment configuration defaults', () {
    final config = RemoteXRelayConfig.fromEnvironment();
    expect(config.host, isNotEmpty);
    expect(config.port, greaterThan(0));
    expect(config.maxSessions, 100);
    expect(config.sessionTimeout, const Duration(minutes: 30));
    expect(config.authTimeout, const Duration(seconds: 10));
  });

  test('logs operational events using logger callback', () async {
    final logs = <String>[];
    final testRelay = RemoteXRelayServer(
      config: const RemoteXRelayConfig(
        host: '127.0.0.1',
        port: 0,
      ),
      logger: logs.add,
    );
    await testRelay.start();
    addTearDown(testRelay.stop);

    expect(logs, isNotEmpty);
    expect(logs.any((line) => line.contains('listening on')), isTrue);
  });
}
